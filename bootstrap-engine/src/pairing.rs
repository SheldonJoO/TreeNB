//! iOS 27 设备端自配对 + RPPairing 隧道安装。
//!
//! 纯 Rust 实现，逻辑照搬 idevice 官方 FFI（MIT）的
//! `ffi/src/pairable_host.rs::pairable_host_accept_with_options` 与
//! `ffi/src/tunnel_provider.rs::tunnel_create_rppairing` / `finish_tunnel`。
//! 没有使用 SideInstaller 的任何代码。
//!
//! 配对：广播 `_remotepairing-pairable-host._tcp` → 设备连入 → PairableHost
//! 完成 SRP pair-setup → 生成 6 位 PIN（回调给网页显示）→ 产出 RpPairingFile。
//! 安装：用 RpPairingFile 连本机隧道 → pair-verify → TLS-PSK → RSD → installd。

use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;

use idevice::remote_pairing::{
    PAIRABLE_HOST_SERVICE_TYPE, PairableHost, PairableHostInfo, RemotePairingClient,
    RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native,
};
use idevice::rsd::RsdHandshake;
use mdns_sd::{ServiceDaemon, ServiceInfo};
use tokio::net::{TcpListener, TcpStream};

/// 配对结果：持久化的配对文件 + 主机 altIRK（重连识别用）。
pub struct PairResult {
    pub pairing_file: RpPairingFile,
    /// 主机的 16 字节 altIRK；重连时用于让设备识别本机，保留备用。
    #[allow(dead_code)]
    pub host_alt_irk: [u8; 16],
}

/// 在无 computer 的 iPhone 上，广播「可配对主机」并接受这台 iPhone 自身发起的配对。
///
/// `on_pin` 在设备连入、PIN 生成时被调用一次，用于把 6 位码显示到网页。
/// `on_event` 用于把进度写进日志（"广播中" / "设备已连接" / "配对成功"）。
pub async fn pair_on_device<F, G>(
    name: &str,
    model: &str,
    on_pin: F,
    on_event: G,
) -> Result<PairResult, String>
where
    F: FnOnce(String) + Send + 'static,
    G: Fn(String) + Send + Sync + 'static,
{
    // 1) 先绑定端口，mDNS 才能广播真实端口。
    let listener = TcpListener::bind((Ipv4Addr::UNSPECIFIED, 0u16))
        .await
        .map_err(|e| format!("监听端口失败: {e}"))?;
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
    on_event(format!("[配对] 广播服务 _remotepairing-pairable-host._tcp，端口 {port}"));

    // 3) 广播 mDNS 服务，让 iOS「设置 → 开发者模式 → 与主机配对」能发现本机。
    let mdns = ServiceDaemon::new().map_err(|e| format!("mDNS 引擎启动失败: {e}"))?;
    // Apple 的实例名超过 mdns-sd 默认上限。
    let _ = mdns.set_service_name_len_max(30);
    let hostname = format!("idevice-{}.local.", &service_identifier[..8]);
    let txt = host_info.mdns_txt_records(&service_identifier);
    let properties: Vec<(&str, &str)> = txt.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let service_info = ServiceInfo::new(
        PAIRABLE_HOST_SERVICE_TYPE,
        &service_identifier,
        &hostname,
        "",
        port,
        &properties[..],
    )
    .map_err(|e| format!("mDNS 服务信息构造失败: {e}"))?
    .enable_addr_auto();
    mdns.register(service_info)
        .map_err(|e| format!("mDNS 广播失败: {e}"))?;
    on_event("[配对] 已广播：请到 设置 → 隐私与安全性 → 开发者模式 → 与主机配对".into());

    // 4) 等设备连入并完成 SRP pair-setup。PIN 通过回调推给网页显示。
    let accept = async {
        let (stream, _peer) = listener
            .accept()
            .await
            .map_err(|e| format!("等待设备连接失败: {e}"))?;
        on_event("[配对] 设备已连接，正在生成配对码…".into());
        let socket = RpPairingSocket::new_device(stream);
        let mut host = PairableHost::new(socket, host_info);
        host.accept(&mut pairing_file, |pin| async move {
            on_pin(pin);
        })
        .await
        .map_err(|e| format!("配对握手失败: {e:?}"))?;
        Ok::<_, String>(())
    };

    let result = accept.await;

    // 5) 停止广播。
    if let Ok(rx) = mdns.shutdown() {
        let _ = tokio::task::spawn_blocking(move || rx.recv_timeout(std::time::Duration::from_secs(2))).await;
    }
    result?;

    on_event("[配对] 配对成功，配对文件已生成并保存到本机。".into());
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
