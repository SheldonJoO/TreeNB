//! iOS 27 设备端自配对 + RPPairing 隧道安装。
//!
//! 纯 Rust 实现，逻辑照搬 idevice 官方 FFI（MIT）的
//! `ffi/src/pairable_host.rs` 与 `ffi/src/tunnel_provider.rs` / `finish_tunnel`。
//! 没有使用 SideInstaller 的任何代码。
//!
//! 关键（v0.3.2 修复）：iSH 容器里的 mdns-sd 组播被 iOS 静默拒绝（无 multicast
//! entitlement），iOS「开发者模式」能看到条目却连不回容器 → 配对码永不生成。
//! 改用 Open Minis 1.16+ 自带的 `minis-bonjour advertise`：由 App 原生广播 mDNS，
//! 并把系统设置的入站连接转发到本进程在 127.0.0.1 上的监听端口。

use std::net::{Ipv4Addr, SocketAddr};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::Duration as StdDuration;

use idevice::remote_pairing::{
    PairableHost, PairableHostInfo, RemotePairingClient, RpPairingFile, RpPairingSocket,
    connect_tls_psk_tunnel_native,
};
use idevice::rsd::RsdHandshake;
use serde_json::Value;
use tokio::net::{TcpListener, TcpStream};

use crate::keepalive::{self, KeepAlive};

/// Settings 浏览的服务类型（不带结尾点，minis-bonjour 要求这个写法）。
pub const PAIRABLE_HOST_TYPE: &str = "_remotepairing-pairable-host._tcp";

/// 配对结果：持久化的配对文件 + 主机 altIRK（重连识别用）。
pub struct PairResult {
    pub pairing_file: RpPairingFile,
    /// 主机的 16 字节 altIRK；重连时用于让设备识别本机，保留备用。
    #[allow(dead_code)]
    pub host_alt_irk: [u8; 16],
}

/// 一次 minis-bonjour 广播的句柄；Drop 或显式 stop 时撤回服务，避免残留条目
/// 出现在「开发者模式」里（残留会用旧 authTag，导致下次配对失败）。
struct Advert {
    id: Option<String>,
}

impl Advert {
    /// 调用 Open Minis 原生桥接：
    ///   minis-bonjour advertise <type> <name> <port> k=v... --compact
    /// App 广播 mDNS，并把 iOS 设置的入站连接转发到本机 127.0.0.1:<port>。
    async fn publish(service_id: &str, port: u16, txt: &[(String, String)]) -> Result<Self, String> {
        let service_id = service_id.to_string();
        let txt = txt.to_vec();
        tokio::task::spawn_blocking(move || Self::publish_blocking(&service_id, port, &txt))
            .await
            .map_err(|e| format!("广播任务失败: {e}"))?
    }

    fn publish_blocking(service_id: &str, port: u16, txt: &[(String, String)]) -> Result<Self, String> {
        let mut args: Vec<String> = vec![
            "advertise".into(),
            PAIRABLE_HOST_TYPE.into(),
            service_id.into(),
            port.to_string(),
        ];
        for (k, v) in txt {
            args.push(format!("{k}={v}"));
        }
        args.push("--compact".into());

        let out = Command::new("minis-bonjour")
            .args(&args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .map_err(|e| {
                format!(
                    "无法调用 Open Minis 的原生 Bonjour 桥接（minis-bonjour: {e}）。请把 Open Minis 升级到 1.16 或更新版本后重试。"
                )
            })?;
        let text = String::from_utf8_lossy(&out.stdout);
        let v: Value = serde_json::from_str(text.trim()).map_err(|_| {
            let err = String::from_utf8_lossy(&out.stderr);
            format!(
                "minis-bonjour 返回无法解析的结果：{}{}",
                text.trim(),
                if err.trim().is_empty() { String::new() } else { format!("（{err}）") }
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
            return Err(format!("minis-bonjour 广播失败（{code}）：{msg}"));
        }
        let empty = Value::Null;
        let data = v.get("data").unwrap_or(&empty);
        let id = data.get("id").and_then(Value::as_str).map(str::to_string);
        let state = data.get("state").and_then(Value::as_str).unwrap_or("");
        let name = data.get("name").and_then(Value::as_str).unwrap_or("");
        if state == "failed" {
            let why = data
                .get("failed_reason")
                .and_then(Value::as_str)
                .unwrap_or("未提供原因");
            return Err(format!("minis-bonjour 广播失败：{why}"));
        }
        if !name.is_empty() && name != service_id {
            return Err(format!(
                "mDNS 实例名被系统改名（期望 {service_id}，实际 {name}），配对可能失败。请关闭其他配对广播后重试。"
            ));
        }
        Ok(Self { id })
    }

    fn stop(&mut self) {
        if let Some(id) = self.id.take() {
            let _ = std::thread::spawn(move || {
                let _ = Command::new("minis-bonjour")
                    .args(["stop", &id, "--compact"])
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status();
            })
            .join();
        }
    }
}

impl Drop for Advert {
    fn drop(&mut self) {
        self.stop();
    }
}

/// 在无固定网络的 iPhone 上，通过 Open Minis 原生 Bonjour 广播「可配对主机」，
/// 接受这台 iPhone 自身发起的配对。
///
/// `on_pin` 在设备连入、PIN 生成时被调用一次，用于把 6 位码显示到网页。
/// `on_event` 用于把进度写进日志（"广播中" / "设备已连接" / "配对成功"）。
/// `workdir` 用于写静音文件与配对文件（容器内可写目录）。
pub async fn pair_on_device<F, G>(
    name: &str,
    model: &str,
    workdir: &Path,
    on_pin: F,
    on_event: G,
) -> Result<PairResult, String>
where
    F: FnOnce(String) + Send + 'static,
    G: Fn(String) + Send + Sync + 'static,
{
    // 1) 监听 127.0.0.1：minis-bonjour 会把系统设置的连接转发到这里。
    //    容器里直接组播广播的地址 iOS 连不回来，必须走 App 原生桥接。
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0u16))
        .await
        .map_err(|e| format!("监听本地端口失败: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("读取端口失败: {e}"))?
        .port();

    // 2) 生成本机的长期密钥与配对文件。identifier 是 mDNS 实例名，必须一致。
    let mut pairing_file = RpPairingFile::generate(name);
    let mut host_info = PairableHostInfo::generate(name, model);
    host_info.allows_pinless_pairing = false;
    let host_alt_irk = host_info.alt_irk;
    let service_identifier = pairing_file.identifier.clone();
    on_event(format!("[配对] 本机监听 127.0.0.1:{port}，正在通过 Open Minis 广播可配对服务…"));

    // 3) 关键：切到「设置」后 iOS 会挂起 Open Minis，广播随即被系统撤回，
    //    设置里那一行还没点就消失，点了锁屏密码后连接也建立不起来 → 永不弹码。
    //    先启动静音播放保活（此时用户还在 Minis 里，播放器能正常打开），并通知用户。
    let mut keepalive = match KeepAlive::start(workdir, keepalive::PAIRING_SECONDS) {
        Ok(k) => {
            on_event("[配对] 已开启静音保活：请保持弹出的播放器开启，切到设置时不要关闭它。".into());
            Some(k)
        }
        Err(e) => {
            on_event(format!(
                "[配对] 无法开启静音保活：{e}。切到设置后 App 可能被挂起导致配对项消失，建议保持 Minis 前台或开启「增强后台」。"
            ));
            None
        }
    };
    keepalive::notify(
        "TreeNB 配对已就绪",
        "到 设置 → 隐私与安全性 → 开发者模式，点 Pair with TreeNB。保持播放器开启。",
    );

    // 4) 清理上次运行残留的 pairable-host 广播（旧 authTag 已失效，点了只会一直转圈）。
    keepalive::withdraw_leftovers();

    // 5) TXT 记录与 idevice FFI 完全一致，交给 App 侧发布。
    let txt = host_info.mdns_txt_records(&service_identifier);
    let mut advert = Advert::publish(&service_identifier, port, &txt).await?;
    on_event("[配对] 广播已就绪：请到 设置 → 隐私与安全性 → 开发者模式 → Pair with TreeNB".into());
    on_event("[配对] 先输锁屏密码；随后网页会显示 6 位配对码（也会弹通知），把它输入到设置里。".into());

    // 6) 等设备连入并完成 SRP pair-setup。等待期间定期唤醒保活播放器，
    //    避免用户不小心关掉后 App 被挂起。PIN 生成时同时发通知，
    //    这样用户在「设置」里就能看到码，不必切回网页。
    let accept = async {
        let check_every = StdDuration::from_secs(20);
        loop {
            tokio::select! {
                res = listener.accept() => {
                    break res.map_err(|e| format!("等待设备连接失败: {e}"));
                }
                _ = tokio::time::sleep(check_every) => {
                    if let Some(k) = keepalive.as_mut() {
                        match k.revive() {
                            Ok(true) => on_event("[配对] 播放器被关闭过，已自动重新打开；配对期间请保持它开启。".into()),
                            Ok(false) => {}
                            Err(e) => on_event(format!("[配对] 保活状态检查失败：{e}")),
                        }
                    }
                }
            }
        }
    };
    let (stream, _peer) = accept.await?;
    on_event("[配对] 设备已连接，正在生成配对码…".into());
    let socket = RpPairingSocket::new_device(stream);
    let mut host = PairableHost::new(socket, host_info);
    host.accept(&mut pairing_file, |pin| async move {
        // 通知里把 6 位码用空格隔开，方便在看设置时直接读。
        let spaced: String = pin
            .chars()
            .take(6)
            .map(|c| c.to_string())
            .collect::<Vec<_>>()
            .join(" ");
        keepalive::notify("TreeNB 配对码", &format!("{spaced} — 输入到设置里的配对框"));
        on_pin(pin);
    })
    .await
    .map_err(|e| format!("配对握手失败: {e:?}"))?;

    // 7) 撤回广播、停止静音（无论成功失败），避免残留条目与后台播放。
    advert.stop();
    if let Some(k) = keepalive.as_mut() {
        k.stop();
    }

    on_event("[配对] 配对成功，配对文件已生成并保存到本机。".into());
    keepalive::notify("TreeNB 配对成功", "请回到 Open Minis，安装会自动继续。");
    Ok(PairResult {
        pairing_file,
        host_alt_irk,
    })
}

/// 把配对文件写到本地（`rp_pairing_file.plist`，权限 0600）。
pub async fn save_pairing_file(pf: &RpPairingFile, path: &std::path::Path) -> Result<(), String> {
    pf.write_to_file(path)
        .await
        .map_err(|e| format!("配对文件写入失败: {e:?}"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = tokio::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).await;
    }
    Ok(())
}

/// 从本机隧道地址建立 RSD 连接（照搬 idevice FFI `finish_tunnel`）。
///
/// `addr` 是 RPPairing 控制服务地址（本机场景为 10.7.0.1:49152）。
async fn finish_tunnel(
    rpc: &mut RemotePairingClient<impl idevice::remote_pairing::RpPairingSocketProvider>,
    connect_addr: SocketAddr,
) -> Result<(idevice::tcp::handle::AdapterHandle, RsdHandshake), String> {
    let tunnel_port = rpc
        .create_tcp_listener()
        .await
        .map_err(|e| format!("创建隧道监听失败: {e:?}"))?;
    let mut tunnel_addr = connect_addr;
    tunnel_addr.set_port(tunnel_port);
    let tunnel_stream = TcpStream::connect(tunnel_addr)
        .await
        .map_err(|e| format!("连接 TLS 隧道失败: {e}"))?;
    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key())
        .await
        .map_err(|e| format!("TLS-PSK 握手失败: {e:?}"))?;

    let client_ip: std::net::IpAddr = tunnel
        .info
        .client_address
        .parse()
        .map_err(|e| format!("隧道本地地址无效: {e}"))?;
    let server_ip: std::net::IpAddr = tunnel
        .info
        .server_address
        .parse()
        .map_err(|e| format!("隧道服务端地址无效: {e}"))?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;

    let raw = tunnel.into_inner();
    let mut adapter = idevice::tcp::adapter::Adapter::new(Box::new(raw), client_ip, server_ip);
    adapter.set_mss(mtu.min(8192).saturating_sub(60));
    let mut adapter = adapter.to_async_handle();
    let rsd_stream = adapter
        .connect(rsd_port)
        .await
        .map_err(|e| format!("连接 RSD 服务失败: {e:?}"))?;
    let handshake = RsdHandshake::new(rsd_stream)
        .await
        .map_err(|e| format!("RSD 握手失败: {e:?}"))?;
    Ok((adapter, handshake))
}

/// 用 RPPairing 配对文件把已签名 IPA 安装到本机。
///
/// `addr` 为 RPPairing 控制服务地址（默认 10.7.0.1:49152）。
pub async fn install_with_pairing(
    pf: &mut RpPairingFile,
    addr: SocketAddr,
    signed_ipa: &std::path::Path,
    hostname: &str,
    progress: impl Fn(u32) + Send + Sync + 'static,
) -> Result<(), String> {
    let stream = TcpStream::connect(addr)
        .await
        .map_err(|e| format!("连接设备配对服务 {addr} 失败: {e}"))?;
    let conn = RpPairingSocket::new(stream);
    let mut rpc = RemotePairingClient::new(conn, hostname);
    // 已配对文件走 pair-verify；PIN 回调仅在意外需要重新 pair-setup 时才会用到。
    rpc.connect(pf, || async { String::new() })
        .await
        .map_err(|e| format!("设备配对验证失败: {e:?}"))?;

    let (mut adapter, mut handshake) = finish_tunnel(&mut rpc, addr).await?;
    let cb = Arc::new(progress);
    isideload::sideload::install::install_app_rsd(
        &mut adapter,
        &mut handshake,
        signed_ipa,
        move |pct: u64| {
            cb((pct.min(100)) as u32);
        },
    )
    .await
    .map_err(|e| format!("安装失败: {e:?}"))?;
    Ok(())
}
