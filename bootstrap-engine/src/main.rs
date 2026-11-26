//! treenb-bootstrap — on-device signing & install engine.
//!
//! Runs inside Open Minis (aarch64 Linux container) on the iPhone itself.
//! The terminal only starts the engine and prints a loopback URL; all user
//! interaction happens in the local web page (Minis's built-in browser).
//!
//! Ground-up implementation using independent OSS libraries
//! (isideload MIT, idevice MIT). No siboot / SideInstaller code is used.

mod pairing;
mod web;

use std::env;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use isideload::anisette::remote_v3::RemoteV3AnisetteProvider;
use isideload::auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse};
use isideload::auth::builder::AppleAccountBuilder;
use isideload::dev::certificates::DevelopmentCertificate;
use isideload::dev::developer_session::DeveloperSession;
use isideload::sideload::builder::{
    ExtensionsBehavior, ExtensionsBehaviorSelection, MaxCertsBehavior, TeamSelection,
};
use isideload::sideload::SideloaderBuilder;
use isideload::util::callbacks::{ExtensionsBehaviorCallbackBox, MaxCertsCallbackBox};
use isideload::util::fs_storage::FsStorage;

use idevice::remote_pairing::RpPairingFile;

use pairing::{install_with_pairing, save_pairing_file};
use web::{CertOption, WebUI};

/// 把 isideload 的证书对象转成网页展示项。serial 为空的证书不能用于吊销，跳过。
fn cert_options(certs: &[DevelopmentCertificate]) -> Vec<CertOption> {
    certs
        .iter()
        .filter_map(|c| {
            let serial = c.serial_number.clone().unwrap_or_default();
            if serial.is_empty() {
                return None;
            }
            let name = c
                .name
                .clone()
                .or_else(|| c.machine_name.clone())
                .unwrap_or_else(|| "未命名证书".into());
            let machine = c.machine_name.clone().unwrap_or_default();
            let platform = c.certificate_platform.clone().unwrap_or_default();
            let label = if machine.is_empty() {
                format!("{} · {}", name, platform)
            } else {
                format!("{} · 设备 {} · {}", name, machine, platform)
            };
            Some(CertOption { serial, label })
        })
        .collect()
}

/// anisette 服务器候选列表（伪装成 Mac 的机器指纹服务）。
/// 默认 ani.iloader.app 在国内常被限流，导致 -22406/-20970 误报"密码错误"。
/// 国内可直连的排在前面；轮换时每个都用全新 storage 子目录以重置 anisette 状态
/// （否则旧 Trust Key 会报 -45003）。
/// 这些地址来自 SideStore 官方 anisette-servers 列表。
const ANISETTE_SERVERS: &[&str] = &[
    "https://ani.xu30.top",          // SteX，国内可直连（社区验证）
    "https://ani.sidestore.io",      // SideStore 官方主服务器
    "https://ani.idevicehacked.com",
    "https://ani.jkcoxson.com",      // idevice 作者自持
    "https://ani.iloader.app",       // isideload 默认（放最后兜底）
];

fn server_short(url: &str) -> String {
    url.trim_start_matches("https://")
        .trim_start_matches("http://")
        .to_string()
}

/// 把冗长的 isideload 错误链压成一行可读摘要，方便日志里快速定位。
fn short_auth_err(msg: &str) -> String {
    if let Some(code) = msg.split("Auth error ").nth(1) {
        let code = code.split(|c: char| c == ',' || c == ')' || c == '}').next().unwrap_or("");
        return format!("认证错误 {code}");
    }
    if let Some(code) = msg.split("AuthWithMessage(").nth(1) {
        let code = code.split(',').next().unwrap_or("");
        return format!("认证错误 {code}");
    }
    // 取最后一行有意义的文字。
    msg.lines()
        .rev()
        .find(|l| !l.trim().is_empty() && l.len() < 120)
        .unwrap_or(msg)
        .trim()
        .to_string()
}

/// 用指定 anisette 服务器尝试登录。anisette_dir 用全新子目录 = 重置 anisette 状态。
async fn try_login_with_server<C>(
    email: &str,
    password: &str,
    two_factor: C,
    server_url: &str,
    anisette_dir: &PathBuf,
) -> Result<AppleAccount, rootcause::Report>
where
    C: isideload::util::callbacks::TwoFactorCallback,
{
    let provider = RemoteV3AnisetteProvider::new(
        server_url,
        Box::new(FsStorage::new(anisette_dir.clone())),
        "0".to_string(),
    )?;
    AppleAccountBuilder::new(email)
        .anisette_provider(provider)
        .login(password, two_factor)
        .await
}

fn main() {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("failed to install rustls crypto provider");

    let args: Vec<String> = env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("help");

    match mode {
        "developer-mode" => {
            println!("[treenb] 开发者模式助手：接入中。");
            println!("[treenb] 当前请手动：设置 → 隐私与安全性 → 开发者模式（若未出现，先连 LocalDevVPN）。");
        }
        "install" => {
            let ipa = args
                .windows(2)
                .find(|w| w[0] == "--ipa")
                .map(|w| w[1].clone())
                .unwrap_or_default();
            if ipa.is_empty() {
                eprintln!("[treenb] 缺少 --ipa 参数");
                std::process::exit(2);
            }
            let rt = tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()
                .expect("failed to build tokio runtime");
            rt.block_on(run_install(PathBuf::from(ipa)));
        }
        "version" | _ => {
            println!("treenb-bootstrap 0.3.1 (aarch64-linux-musl)");
            println!("usage: treenb-bootstrap <developer-mode|install>");
        }
    }
}

async fn run_install(ipa: PathBuf) {
    let ui = WebUI::start()
        .await
        .expect("failed to start local web UI");

    println!();
    println!("  TreeNB 免电脑安装引擎已启动");
    println!("  ─────────────────────────────────────────────");
    println!("  在 Minis 浏览器打开下面的地址完成安装：");
    println!();
    println!("  {}", ui.url);
    println!();
    println!("  保持 Open Minis 在前台，直到页面显示全部完成。");
    println!("  ─────────────────────────────────────────────");
    println!();

    let _ = std::process::Command::new("xdg-open").arg(&ui.url).spawn();

    ui.log(format!("[TreeNB] 待签名 IPA：{}", ipa.display()));
    if !ipa.exists() {
        fail(&ui, "签名", "IPA 文件不存在，请重新运行安装命令。");
        return keep_alive().await;
    }

    // --- Apple ID: account -> password -> (optional) 2FA -> login ---
    let email = ui.ask("account-picker", "请选择或输入 Apple 账户").await;
    if email.is_empty() {
        fail(&ui, "Apple ID", "未选择账户，流程已取消。");
        return keep_alive().await;
    }
    ui.patch(|s| {
        s.accounts.retain(|a| a != &email);
        s.accounts.insert(0, email.clone());
    });
    ui.set_step("Apple ID", "active", "正在登录…");
    ui.log(format!("[账号] {}（密码只在本机使用，不会写入日志）", email));

    let password = ui
        .ask("password", "请输入 Apple ID 密码（仅本机使用，不会保存）")
        .await;
    if password.is_empty() {
        fail(&ui, "Apple ID", "未输入密码，流程已取消。");
        return keep_alive().await;
    }

    let ui_2fa = ui.clone();
    let two_factor = move |params: TwoFactorCallbackParams| {
        let u = ui_2fa.clone();
        async move {
            let detail = if params.unknown || params.numbers.is_empty() {
                "请输入 Apple ID 发送的 6 位验证码".to_string()
            } else {
                let numbers: Vec<String> = params
                    .numbers
                    .iter()
                    .map(|n| format!("{}（尾号 {}）", n.number_with_dial_code, n.last_two_digits))
                    .collect();
                format!("请输入验证码；已注册设备：{}", numbers.join("、"))
            };
            let code = u.ask("code", &detail).await;
            if code.is_empty() {
                Ok(TwoFactorCallbackResponse::Abort)
            } else {
                Ok(TwoFactorCallbackResponse::SubmitCode(code))
            }
        }
    };

    // 轮换 anisette 服务器：默认 ani.iloader.app 在国内常被限流，报 -22406/-20970
    // 这类"密码错误"的假象。每个服务器用全新 storage 子目录重置 anisette 状态，
    // 避免旧 Trust Key 导致 -45003。任何一台登录成功即停。
    let mut account: Option<AppleAccount> = None;
    let mut last_err = String::new();
    let total = ANISETTE_SERVERS.len();
    for (i, server) in ANISETTE_SERVERS.iter().enumerate() {
        ui.set_step(
            "Apple ID",
            "active",
            &format!("正在登录（服务器 {}/{}：{}）…", i + 1, total, server_short(server)),
        );
        ui.log(format!("[登录] 尝试 anisette 服务器 {}：{}", i + 1, server));
        // 全新子目录 = 重置 anisette 状态；带上轮次保证每次都不同。
        // IPA 就放在 $WORKDIR 下，取其父目录作为存储根。
        let base_dir = ipa.parent().unwrap_or(std::path::Path::new("."));
        let ani_dir = base_dir.join(format!("anisette-try{}", i));
        let _ = tokio::fs::remove_dir_all(&ani_dir).await;
        match try_login_with_server(&email, &password, two_factor.clone(), server, &ani_dir).await {
            Ok(a) => {
                ui.log(format!("[登录] 服务器 {} 登录成功。", server_short(server)));
                account = Some(a);
                break;
            }
            Err(e) => {
                let msg = format!("{e:?}");
                last_err = msg.clone();
                ui.log(format!("[登录] 服务器 {} 失败：{}", server_short(server), short_auth_err(&msg)));
            }
        }
    }
    drop(password);

    let mut account = match account {
        Some(a) => a,
        None => {
            ui.log(format!("[登录失败] 所有 anisette 服务器均失败。最后错误：{last_err}"));
            let hint = if last_err.contains("-20209") || last_err.contains("locked") {
                "账号被临时锁定，请去 iforgot.apple.com 验证身份解锁后再试。"
            } else if last_err.contains("-22406") || last_err.contains("-20970") || last_err.contains("Anisette") {
                "所有内置服务器都不可用，通常是当前网络限制。建议换网络（WiFi↔蜂窝）后重试，或稍后再试。"
            } else {
                "请核对 Apple ID 邮箱和密码是否正确，并确认账号已开启双重认证。"
            };
            fail(&ui, "Apple ID", &format!("登录失败：{hint}"));
            return keep_alive().await;
        }
    };

    ui.set_step("Apple ID", "done", "登录成功，已获取开发者会话");
    ui.log("[Apple ID] 登录成功，正在获取开发者证书…");

    let dev_session = match DeveloperSession::from_account(&mut account).await {
        Ok(s) => s,
        Err(e) => {
            ui.log(format!("[开发者会话失败] {e:?}"));
            fail(&ui, "签名", "无法获取开发者会话，请展开详情查看原因。");
            return keep_alive().await;
        }
    };
    drop(account);

    // --- Signing: real isideload certificate + provisioning profile ---
    let home = env::var("HOME").unwrap_or_else(|_| ".".into());
    let workdir = PathBuf::from(&home).join(".treenb-bootstrap");
    let _ = std::fs::create_dir_all(&workdir);

    // 证书达到 Apple 上限时，弹出证书列表让用户勾选要吊销的旧证书，然后自动重试。
    let cert_ui = ui.clone();
    let max_certs_cb: MaxCertsCallbackBox = Box::new(move |certs: Vec<DevelopmentCertificate>| {
        let u = cert_ui.clone();
        Box::pin(async move {
            let options = cert_options(&certs);
            if options.is_empty() {
                return Err(rootcause::report!("没有可吊销的证书"));
            }
            u.log(format!("[证书] 已达 Apple 上限，列出 {} 个证书供选择", options.len()));
            let prompt = format!(
                "Apple 账号的证书已达上限（最多 10 个）。请勾选要吊销的旧证书腾出位置，吊销后会自动重试签名。被吊销证书签过的 App 可能需要重新签名。"
            );
            let picked = u.ask_certs(options, &prompt).await;
            if picked.is_empty() {
                return Err(rootcause::report!("用户取消吊销证书"));
            }
            u.log(format!("[证书] 用户选择吊销 {} 个证书，正在重试…", picked.len()));
            Ok(Some(picked))
        })
    });

    let mut sideloader =
        SideloaderBuilder::<MaxCertsCallbackBox, ExtensionsBehaviorCallbackBox>::new(
            dev_session,
            email.clone(),
        )
        .team_selection(TeamSelection::First)
        .max_certs_behavior(MaxCertsBehavior::Prompt(max_certs_cb))
        .extensions_behavior(ExtensionsBehaviorSelection::Fixed(
            ExtensionsBehavior::RegisterAll,
        ))
        .storage(Box::new(FsStorage::new(workdir.clone())))
        .machine_name("TreeNB".into())
        .delete_app_after_install(false)
        .build();

    let sign_ui = ui.clone();
    let progress = move |p: f32| {
        let u = sign_ui.clone();
        async move {
            let pct = (p * 100.0) as u32;
            u.set_step("签名", "active", &format!("正在签名… {}%", pct));
        }
    };

    ui.set_step("签名", "active", "正在注册 App ID / 证书 / 描述文件…");
    let signed = match sideloader
        .sign_app(ipa, None, false, Some(progress), None, None)
        .await
    {
        Ok((path, _special)) => path,
        Err(e) => {
            let msg = format!("{e:?}");
            ui.log(format!("[签名失败] {msg}"));
            fail(&ui, "签名", "签名失败，请展开详情查看原因。");
            return keep_alive().await;
        }
    };
    ui.set_step("签名", "done", "签名完成，等待安装到设备");
    ui.log(format!("[签名] 完成：{}", signed.display()));

    // --- Pairing: iOS 27 设备端自配对，产出 RpPairingFile ---
    let rp_path = workdir.join("rp_pairing_file.plist");
    let pf: RpPairingFile = if rp_path.exists() {
        match RpPairingFile::read_from_file(&rp_path).await {
            Ok(pf) => {
                ui.log(format!("[设备] 已加载本机配对文件：{}", rp_path.display()));
                pf
            }
            Err(e) => {
                ui.log(format!("[设备] 配对文件解析失败，将重新配对：{e:?}"));
                match do_self_pair(ui.clone(), &rp_path).await {
                    Ok(pf) => pf,
                    Err(_) => return keep_alive().await,
                }
            }
        }
    } else {
        match do_self_pair(ui.clone(), &rp_path).await {
            Ok(pf) => pf,
            Err(_) => return keep_alive().await,
        }
    };
    let mut pf = pf;

    // --- Install: 经本机隧道 + RPPairing 隧道安装到系统 ---
    // 本机 RPPairing 控制服务地址：LocalDevVPN 默认 10.7.0.1:49152。
    let tunnel_host = env::var("TNB_TUNNEL_HOST").unwrap_or_else(|_| "10.7.0.1".into());
    let tunnel_port: u16 = env::var("TNB_TUNNEL_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(49152);
    let addr = match format!("{tunnel_host}:{tunnel_port}").parse::<SocketAddr>() {
        Ok(a) => a,
        Err(e) => {
            fail(&ui, "安装", &format!("隧道地址无效（{tunnel_host}:{tunnel_port}）：{e}"));
            return keep_alive().await;
        }
    };

    ui.set_step("安装", "active", "正在连接本机隧道并安装…");
    ui.log(format!("[安装] 通过 RPPairing 隧道连接 {addr}，上传并安装 IPA…"));
    let install_ui = ui.clone();
    let progress = move |pct: u32| {
        install_ui.set_step("安装", "active", &format!("正在安装… {pct}%"));
    };
    match install_with_pairing(&mut pf, addr, &signed, "TreeNB", progress).await {
        Ok(_) => {
            ui.set_step("安装", "done", "已安装到设备");
            ui.set_step("交接", "done", "配对文件与证书已保留在本机");
            ui.log("[完成] TreeNB 已安装，请回桌面查看。");
        }
        Err(e) => {
            ui.log(format!("[安装失败] {e}"));
            fail(&ui, "安装", "安装失败，请展开详情查看原因。");
        }
    }

    keep_alive().await;
}

/// 执行一次设备端自配对：广播 → 网页显示 PIN → 用户在设置里配对 → 保存配对文件。
async fn do_self_pair(ui: Arc<WebUI>, rp_path: &PathBuf) -> Result<RpPairingFile, ()> {
    ui.set_step("安装", "active", "准备设备配对…");
    ui.patch(|s| s.pairing_active = true);
    let pin_ui = ui.clone();
    let evt_ui = ui.clone();
    let result = pairing::pair_on_device(
        "TreeNB",
        "Mac17,7",
        move |pin| {
            // 把 6 位配对码显示到网页，供用户在「设置」里输入。
            pin_ui.show_pin(&pin);
        },
        move |line| evt_ui.log(line),
    )
    .await;
    ui.patch(|s| s.pairing_active = false);
    match result {
        Ok(r) => {
            ui.hide_pin();
            ui.log("[配对] 配对成功，正在保存配对文件…");
            if let Err(e) = save_pairing_file(&r.pairing_file, rp_path).await {
                ui.log(format!("[配对] {e}"));
                fail(&ui, "安装", "配对成功但保存失败，请展开详情查看原因。");
                return Err(());
            }
            ui.log(format!("[配对] 配对文件已保存：{}", rp_path.display()));
            Ok(r.pairing_file)
        }
        Err(e) => {
            ui.log(format!("[配对失败] {e}"));
            fail(&ui, "安装", "设备配对失败，请展开详情查看原因。");
            Err(())
        }
    }
}

fn fail(ui: &WebUI, step: &str, detail: &str) {
    ui.set_step(step, "error", detail);
    ui.patch(|s| {
        s.dialog = "error".into();
        s.prompt = detail.into();
    });
}

async fn keep_alive() {
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(3600)).await;
    }
}
