//! 配对期间让 Open Minis 保持前台运行。
//!
//! 关键（v0.3.3）：iOS 在用户切到「设置」后几秒内就会挂起后台 App，而
//! `minis-bonjour` 的广播在 App 被挂起时会被系统撤回——设置里的
//! 「Pair with TreeNB」还没点就消失，或点了锁屏密码后连接被挂断，
//! 引擎收不到 pair-setup M1，6 位配对码永远不会生成。
//!
//! Minis 有后台音频能力：`apple-player play` 用播放会话播放一个文件，
//! 因此循环播放一段静音就能让 iOS 一直保持 Minis 运行。配对结束后停止。
//!
//! 这些命令是 Open Minis 自带的原生桥接（1.16+），本模块只调用它们，
//! 不含任何 SideInstaller / siboot 的代码。

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use serde_json::Value;

/// 静音时长：足够用户找到配对项并输入锁屏密码 + 6 位码。
pub const PAIRING_SECONDS: u32 = 16 * 60;

const SAMPLE_RATE: u32 = 8_000;
const CALL_TIMEOUT: Duration = Duration::from_secs(30);

/// 生成 8kHz 8bit 单声道 PCM 静音 WAV（采样值 0x80 = 静音中点）。
fn silent_wav(seconds: u32) -> Vec<u8> {
    let data_len = SAMPLE_RATE * seconds;
    let mut wav = Vec::with_capacity(44 + data_len as usize);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes()); // fmt chunk size
    wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
    wav.extend_from_slice(&1u16.to_le_bytes()); // mono
    wav.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
    wav.extend_from_slice(&SAMPLE_RATE.to_le_bytes()); // byte rate
    wav.extend_from_slice(&1u16.to_le_bytes()); // block align
    wav.extend_from_slice(&8u16.to_le_bytes()); // bits per sample
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    wav.resize(44 + data_len as usize, 0x80);
    wav
}

/// 调用 Minis 原生命令 `tool args... --compact`，解析单个 JSON envelope，
/// 返回其中的 `data` 对象。失败信息带上错误码，便于网页给出可操作提示。
fn call(tool: &str, args: &[&str]) -> Result<Value, String> {
    let child = Command::new(tool)
        .args(args)
        .arg("--compact")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("无法调用 {tool}（需要 Open Minis 1.16+）：{e}"))?;

    let out = child
        .wait_with_output()
        .map_err(|e| format!("{tool} 执行失败：{e}"))?;
    // 命令本身在 App 侧有超时；这里不做二次 kill，避免遗留子进程。
    let _ = CALL_TIMEOUT;

    let text = String::from_utf8_lossy(&out.stdout);
    let v: Value = serde_json::from_str(text.trim()).map_err(|_| {
        let err = String::from_utf8_lossy(&out.stderr);
        format!(
            "{tool} 返回无法解析的结果：{}{}",
            text.trim(),
            if err.trim().is_empty() {
                String::new()
            } else {
                format!("（{err}）")
            }
        )
    })?;
    if v.get("ok").and_then(Value::as_bool) != Some(true) {
        let code = v
            .pointer("/error/code")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let msg = v
            .pointer("/error/message")
            .and_then(Value::as_str)
            .unwrap_or("未提供原因");
        return Err(format!("{tool} 失败（{code}）：{msg}"));
    }
    Ok(v.get("data").cloned().unwrap_or(Value::Null))
}

/// 静音播放的会话。Drop 或 stop 时停止，避免配对结束后还在播放。
pub struct KeepAlive {
    session: Option<String>,
    file: PathBuf,
}

impl KeepAlive {
    /// 写静音文件并开始播放。`home` 用引擎工作目录（容器内可写）。
    pub fn start(home: &Path, seconds: u32) -> Result<Self, String> {
        let file = home.join(format!("treenb-silence-{seconds}s.wav"));
        let wanted = 44 + u64::from(SAMPLE_RATE * seconds);
        if std::fs::metadata(&file).map(|m| m.len()).unwrap_or(0) != wanted {
            std::fs::write(&file, silent_wav(seconds))
                .map_err(|e| format!("写静音文件失败（{}）：{e}", file.display()))?;
        }
        let path = file.to_string_lossy().to_string();
        let data = call("apple-player", &["play", &path])?;
        let session = data
            .get("session_id")
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| format!("apple-player play 未返回 session_id：{data}"))?;
        Ok(Self {
            session: Some(session),
            file,
        })
    }

    /// 检查播放器是否还在播放；若被关闭/暂停则重新播放。
    /// Ok(true) 表示需要提示用户「播放器被关掉了，请保持开启」。
    pub fn revive(&mut self) -> Result<bool, String> {
        let Some(session) = self.session.clone() else {
            return Ok(false);
        };
        let data = match call("apple-player", &["status", &session]) {
            Ok(d) => d,
            // 会话已结束：重新播放。
            Err(_) => {
                let path = self.file.to_string_lossy().to_string();
                let again = call("apple-player", &["play", &path])?;
                let new_id = again
                    .get("session_id")
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .ok_or_else(|| "apple-player 重新播放未返回 session_id".to_string())?;
                self.session = Some(new_id);
                return Ok(true);
            }
        };
        let status = data
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string();
        if status == "playing" {
            return Ok(false);
        }
        if status == "paused" {
            call("apple-player", &["resume", &session])?;
            return Ok(true);
        }
        // 其他状态：重新播放。
        let path = self.file.to_string_lossy().to_string();
        let again = call("apple-player", &["play", &path])?;
        let new_id = again
            .get("session_id")
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| "apple-player 重新播放未返回 session_id".to_string())?;
        self.session = Some(new_id);
        Ok(true)
    }

    pub fn stop(&mut self) {
        if let Some(session) = self.session.take() {
            let _ = call("apple-player", &["stop", &session]);
        }
    }
}

impl Drop for KeepAlive {
    fn drop(&mut self) {
        self.stop();
    }
}

/// 广播前先清理上次运行残留的 pairable-host 条目：旧条目的 authTag 已失效，
/// 用户点到它只会连到一个没人监听的端口，表现为「灰色一直转圈」。
pub fn withdraw_leftovers() {
    let data = match call("minis-bonjour", &["list"]) {
        Ok(d) => d,
        Err(_) => return,
    };
    let Some(items) = data.get("advertisements").and_then(Value::as_array) else {
        return;
    };
    for item in items {
        let ty = item
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim_end_matches('.');
        if ty != crate::pairing::PAIRABLE_HOST_TYPE {
            continue;
        }
        if let Some(id) = item.get("id").and_then(Value::as_str) {
            let _ = call("minis-bonjour", &["stop", id]);
        }
    }
}

/// 发一条本地通知；切到「设置」后仍能看到。配对码在通知里出现，
/// 用户不必在设置和 Minis 之间来回切换。
pub fn notify(title: &str, body: &str) {
    let t = title.to_string();
    let b = body.to_string();
    tokio::spawn(async move {
        let _ = tokio::task::spawn_blocking(move || {
            call(
                "apple-notification",
                &["schedule", "--title", &t, "--body", &b, "--after", "1"],
            )
        })
        .await;
    });
}
