//! Local web UI served by the engine inside Open Minis.
//!
//! Mirrors the interaction shape of on-device installers (a loopback-only
//! HTTP server with a random token path), but is written from scratch here.
//! The terminal only prints the URL; every user interaction happens in the
//! page opened in Minis's built-in browser.

use serde::Serialize;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

const UI_HTML: &str = include_str!("ui.html");

#[derive(Clone, Serialize)]
pub struct Step {
    pub name: String,
    /// "done" | "active" | "pending" | "error"
    pub state: String,
    pub detail: String,
}

#[derive(Clone, Serialize)]
pub struct Status {
    pub title: String,
    pub device: String,
    pub steps: Vec<Step>,
    /// "" when no dialog, otherwise "account-picker" | "error"
    pub dialog: String,
    pub accounts: Vec<String>,
    pub elapsed: u32,
    pub log: Vec<String>,
}

impl Default for Status {
    fn default() -> Self {
        Self {
            title: "TreeNB 引导".into(),
            device: "已连接本机（引擎外壳验证版）".into(),
            steps: vec![
                Step { name: "连接本机".into(), state: "done".into(), detail: "已连接本机 Open Minis".into() },
                Step { name: "Apple ID".into(), state: "active".into(), detail: "选择 / 输入 Apple 账户".into() },
                Step { name: "签名".into(), state: "pending".into(), detail: "签名引擎接入中（本版未开放）".into() },
                Step { name: "安装".into(), state: "pending".into(), detail: "安装引擎接入中（本版未开放）".into() },
                Step { name: "交接".into(), state: "pending".into(), detail: "配对文件交接接入中".into() },
            ],
            dialog: "account-picker".into(),
            accounts: Vec::new(),
            elapsed: 0,
            log: vec![
                "[TreeNB] 引擎外壳验证版 v0.1.1（中文界面）".into(),
                "[TreeNB] 本地网页已成功启动 —— 这一步验证通过即说明 ELF 可在 Open Minis 运行。".into(),
                "[TreeNB] 配对 / 登录 / 签名 / 安装逻辑正在接入，本版选账号不会真正安装。".into(),
            ],
        }
    }
}

pub struct WebUI {
    pub url: String,
    state: Arc<Mutex<Status>>,
}

impl WebUI {
    /// Bind an ephemeral loopback port and generate a 128-bit token path.
    pub async fn start() -> std::io::Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let port = listener.local_addr()?.port();
        let token = random_token();
        let url = format!("http://127.0.0.1:{}/{}/", port, token);
        let state = Arc::new(Mutex::new(Status::default()));

        let srv_token = token.clone();
        let srv_state = state.clone();
        tokio::spawn(async move {
            loop {
                match listener.accept().await {
                    Ok((socket, _)) => {
                        let t = srv_token.clone();
                        let st = srv_state.clone();
                        tokio::spawn(async move {
                            let _ = serve(socket, t, st).await;
                        });
                    }
                    Err(_) => break,
                }
            }
        });

        Ok(Self { url, state })
    }

    pub fn status(&self) -> Status {
        self.state.lock().map(|s| s.clone()).unwrap_or_default()
    }

    pub fn patch(&self, mutate: impl FnOnce(&mut Status)) {
        if let Ok(mut s) = self.state.lock() {
            mutate(&mut s);
        }
    }
}

fn random_token() -> String {
    // /dev/urandom is available inside the Open Minis container.
    let mut buf = [0u8; 16];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        use std::io::Read;
        let _ = f.read_exact(&mut buf);
    }
    buf.iter().map(|b| format!("{:02x}", b)).collect()
}

async fn serve(
    mut socket: tokio::net::TcpStream,
    token: String,
    state: Arc<Mutex<Status>>,
) -> std::io::Result<()> {
    let mut raw = Vec::new();
    let mut tmp = [0u8; 4096];
    let header_end;
    loop {
        let n = socket.read(&mut tmp).await?;
        if n == 0 {
            return Ok(());
        }
        raw.extend_from_slice(&tmp[..n]);
        if let Some(p) = find(&raw, b"\r\n\r\n") {
            header_end = p + 4;
            break;
        }
        if raw.len() > 64 * 1024 {
            return Ok(());
        }
    }

    // into_owned: detach from `raw` so we can keep reading the header while
    // growing the buffer below (otherwise E0502 borrow conflict).
    let head = String::from_utf8_lossy(&raw[..header_end - 4]).into_owned();
    let first = head.lines().next().unwrap_or("");
    let parts: Vec<&str> = first.split_whitespace().collect();
    let method = parts.first().copied().unwrap_or("GET");
    let path = parts.get(1).copied().unwrap_or("/");

    let base = format!("/{}/", token);
    let route = path.strip_prefix(&base).unwrap_or("!!invalid!!");

    let content_length = head
        .lines()
        .find(|l| l.to_ascii_lowercase().starts_with("content-length:"))
        .and_then(|l| l.split(':').nth(1))
        .and_then(|v| v.trim().parse::<usize>().ok())
        .unwrap_or(0);

    while raw.len() < header_end + content_length {
        let n = socket.read(&mut tmp).await?;
        if n == 0 {
            break;
        }
        raw.extend_from_slice(&tmp[..n]);
    }
    let body = &raw[header_end..header_end + content_length.min(raw.len() - header_end)];

    let (status_line, content_type, payload) = if route == "!!invalid!!" {
        ("HTTP/1.1 404 Not Found", "text/plain; charset=utf-8", "not found".into())
    } else {
        match (method, route) {
            ("GET", "") | ("GET", "index.html") => (
                "HTTP/1.1 200 OK",
                "text/html; charset=utf-8",
                UI_HTML.to_string(),
            ),
            ("GET", "status") => {
                let json = serde_json::to_string(&state.lock().map(|s| s.clone()).unwrap_or_default())
                    .unwrap_or_else(|_| "{}".into());
                ("HTTP/1.1 200 OK", "application/json; charset=utf-8", json)
            }
            ("POST", "account") => {
                let email = String::from_utf8_lossy(body).trim().to_string();
                if !email.is_empty() {
                    if let Ok(mut s) = state.lock() {
                        s.accounts.retain(|a| a != &email);
                        s.accounts.insert(0, email.clone());
                        s.dialog.clear();
                        if let Some(step) = s.steps.iter_mut().find(|x| x.name == "Apple ID") {
                            step.state = "done".into();
                            step.detail = format!("已记录 {}（仅本机暂存）", email);
                        }
                        let chosen = s.accounts.first().cloned().unwrap_or_default();
                        s.log.push(format!("[账号] 已暂存：{}（外壳验证版，未发起真实登录）", chosen));
                        s.log.push("[提示] 真实 Apple ID 登录 / 签名 / 安装逻辑接入中，本版到此为止。".into());
                    }
                }
                ("HTTP/1.1 200 OK", "application/json", "{\"ok\":true}".into())
            }
            _ => (
                "HTTP/1.1 404 Not Found",
                "text/plain; charset=utf-8",
                "not found".into(),
            ),
        }
    };

    let resp = format!(
        "{}\r\nContent-Type: {}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{}",
        status_line,
        content_type,
        payload.as_bytes().len(),
        payload
    );
    socket.write_all(resp.as_bytes()).await?;
    socket.flush().await?;
    Ok(())
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack.windows(needle.len()).position(|w| w == needle)
}
