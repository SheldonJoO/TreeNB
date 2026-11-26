//! Local web UI served by the engine inside Open Minis.
//!
//! Loopback-only HTTP server with a random token path. The terminal only
//! prints the URL; every user interaction happens in the page opened in
//! Minis's built-in browser. The page also acts as the prompt channel for
//! Apple ID password / 2FA codes during the real signing flow.

use serde::Serialize;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::oneshot;

const UI_HTML: &str = include_str!("ui.html");

/// 证书选择器里的一项：serial 用于吊销，label 用于展示。
#[derive(Clone, Serialize)]
pub struct CertOption {
    pub serial: String,
    pub label: String,
}

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
    /// "" when no dialog, otherwise "account-picker" | "password" | "code" | "cert-picker" | "error"
    pub dialog: String,
    /// Prompt shown above the dialog input.
    pub prompt: String,
    pub accounts: Vec<String>,
    /// 证书满时供用户选择吊销的证书列表。
    pub certificates: Vec<CertOption>,
    /// 设备端自配对进行中：网页显示配对引导浮层。
    pub pairing_active: bool,
    /// 配对码（6 位），由引擎在设备连入后生成；空串表示还在等待设备连接。
    pub pairing_pin: String,
    pub elapsed: u32,
    pub log: Vec<String>,
}

impl Default for Status {
    fn default() -> Self {
        Self {
            title: "TreeNB 引导".into(),
            device: "已连接本机 Open Minis".into(),
            steps: vec![
                Step { name: "连接本机".into(), state: "done".into(), detail: "已连接本机 Open Minis".into() },
                Step { name: "Apple ID".into(), state: "active".into(), detail: "选择 / 输入 Apple 账户".into() },
                Step { name: "签名".into(), state: "pending".into(), detail: "等待 Apple ID 登录".into() },
                Step { name: "安装".into(), state: "pending".into(), detail: "等待签名完成".into() },
                Step { name: "交接".into(), state: "pending".into(), detail: "配对文件交接接入中".into() },
            ],
            dialog: "account-picker".into(),
            prompt: String::new(),
            accounts: Vec::new(),
            certificates: Vec::new(),
            pairing_active: false,
            pairing_pin: String::new(),
            elapsed: 0,
            log: vec![
                "[TreeNB] 引擎 v0.3.1：Apple ID 登录、签名、设备自配对与隧道安装已接入。".into(),
                "[TreeNB] 本地网页已启动，等待选择 Apple 账户。".into(),
            ],
        }
    }
}

pub struct WebUI {
    pub url: String,
    state: Arc<Mutex<Status>>,
    pending: Arc<Mutex<Option<oneshot::Sender<String>>>>,
}

impl WebUI {
    /// Bind an ephemeral loopback port and generate a 128-bit token path.
    pub async fn start() -> std::io::Result<Arc<Self>> {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let port = listener.local_addr()?.port();
        let token = random_token();
        let url = format!("http://127.0.0.1:{}/{}/", port, token);
        let ui = Arc::new(Self {
            url,
            state: Arc::new(Mutex::new(Status::default())),
            pending: Arc::new(Mutex::new(None)),
        });

        let srv_token = token.clone();
        let srv_ui = ui.clone();
        tokio::spawn(async move {
            loop {
                match listener.accept().await {
                    Ok((socket, _)) => {
                        let t = srv_token.clone();
                        let u = srv_ui.clone();
                        tokio::spawn(async move {
                            let _ = serve(socket, t, u).await;
                        });
                    }
                    Err(_) => break,
                }
            }
        });

        Ok(ui)
    }

    pub fn status(&self) -> Status {
        self.state.lock().map(|s| s.clone()).unwrap_or_default()
    }

    pub fn patch(&self, mutate: impl FnOnce(&mut Status)) {
        if let Ok(mut s) = self.state.lock() {
            mutate(&mut s);
        }
    }

    /// Update one of the five pipeline steps.
    pub fn set_step(&self, name: &str, state: &str, detail: &str) {
        self.patch(|s| {
            if let Some(step) = s.steps.iter_mut().find(|x| x.name == name) {
                step.state = state.into();
                step.detail = detail.into();
            }
        });
    }

    /// Append a line to the "Show details" log.
    pub fn log(&self, line: impl Into<String>) {
        let line = line.into();
        self.patch(|s| s.log.push(line));
    }

    /// Show a dialog and wait for the user's answer from the page.
    pub async fn ask(&self, dialog: &str, prompt: &str) -> String {
        let (tx, rx) = oneshot::channel();
        self.patch(|s| {
            s.dialog = dialog.into();
            s.prompt = prompt.into();
        });
        if let Ok(mut p) = self.pending.lock() {
            *p = Some(tx);
        }
        rx.await.unwrap_or_default()
    }

    /// 证书数量达到 Apple 上限时，展示证书列表等待用户勾选要吊销的项。
    /// 返回值是 serial_number 列表；空列表表示用户取消。
    pub async fn ask_certs(&self, certs: Vec<CertOption>, prompt: &str) -> Vec<String> {
        let (tx, rx) = oneshot::channel();
        self.patch(|s| {
            s.dialog = "cert-picker".into();
            s.prompt = prompt.into();
            s.certificates = certs;
        });
        if let Ok(mut p) = self.pending.lock() {
            *p = Some(tx);
        }
        let answer = rx.await.unwrap_or_default();
        answer
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect()
    }

    /// 显示设备端配对码（6 位），供用户在系统设置里输入。
    pub fn show_pin(&self, pin: &str) {
        self.patch(|s| {
            s.pairing_active = true;
            s.pairing_pin = pin.into();
        });
    }

    /// 配对结束，收起配对浮层。
    pub fn hide_pin(&self) {
        self.patch(|s| {
            s.pairing_active = false;
            s.pairing_pin.clear();
        });
    }

    /// Resolve the currently pending dialog.
    fn submit(&self, value: String) {
        let tx = self.pending.lock().ok().and_then(|mut p| p.take());
        self.patch(|s| {
            s.dialog.clear();
            s.prompt.clear();
        });
        if let Some(tx) = tx {
            let _ = tx.send(value);
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
    ui: Arc<WebUI>,
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
                let json = serde_json::to_string(&ui.status())
                    .unwrap_or_else(|_| "{}".into());
                ("HTTP/1.1 200 OK", "application/json; charset=utf-8", json)
            }
            ("POST", "reply") | ("POST", "account") => {
                let value = String::from_utf8_lossy(body).trim().to_string();
                ui.submit(value);
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
