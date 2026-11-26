//! treenb-bootstrap — on-device signing & install engine.
//!
//! Runs inside Open Minis (aarch64 Linux container) on the iPhone itself.
//! The terminal only starts the engine and prints a loopback URL; all user
//! interaction happens in the local web page (Minis's built-in browser).
//!
//! Ground-up implementation using independent OSS libraries
//! (isideload MIT, idevice MIT). No siboot / SideInstaller code is used.

mod web;

use std::env;
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;

use isideload::auth::apple_account::{TwoFactorCallbackParams, TwoFactorCallbackResponse};
use isideload::auth::builder::AppleAccountBuilder;
use isideload::dev::developer_session::DeveloperSession;
use isideload::sideload::builder::{
    ExtensionsBehavior, ExtensionsBehaviorSelection, MaxCertsBehavior, TeamSelection,
};
use isideload::sideload::SideloaderBuilder;
use isideload::util::callbacks::{ExtensionsBehaviorCallbackBox, MaxCertsCallbackBox};
use isideload::util::fs_storage::FsStorage;

use idevice::pairing_file::PairingFile;
use idevice::provider::TcpProvider;

use web::WebUI;

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
            println!("treenb-bootstrap 0.2.0 (aarch64-linux-musl)");
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

    let mut account = match AppleAccountBuilder::new(&email)
        .login(&password, two_factor)
        .await
    {
        Ok(a) => a,
        Err(e) => {
            let msg = format!("{e:?}");
            ui.log(format!("[登录失败] {msg}"));
            fail(&ui, "Apple ID", "Apple ID 登录失败，请展开详情查看原因。");
            return keep_alive().await;
        }
    };
    drop(password);

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

    let mut sideloader =
        SideloaderBuilder::<MaxCertsCallbackBox, ExtensionsBehaviorCallbackBox>::new(
            dev_session,
            email.clone(),
        )
        .team_selection(TeamSelection::First)
        .max_certs_behavior(MaxCertsBehavior::Error)
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

    // --- Installation: needs a device pairing file + tunnel address ---
    let pairing_candidates = [
        workdir.join("pairing.plist"),
        workdir.join("pairing_file.plist"),
    ];
    let mut pairing = None;
    for p in &pairing_candidates {
        if p.exists() {
            match PairingFile::read_from_file(p) {
                Ok(pf) => {
                    ui.log(format!("[设备] 已加载配对文件：{}", p.display()));
                    pairing = Some(pf);
                    break;
                }
                Err(e) => ui.log(format!("[设备] 配对文件解析失败 {}: {e:?}", p.display())),
            }
        }
    }

    let pf = match pairing {
        Some(pf) => pf,
        None => {
            ui.set_step(
                "安装",
                "error",
                "缺少配对文件：请先在设置里完成本机配对，或导入已有配对文件。",
            );
            ui.log("[安装] 未找到 pairing.plist，签名已完成但尚未安装。");
            return keep_alive().await;
        }
    };

    let devices = match idevice::tunneld::get_tunneld_devices(SocketAddr::from(([127, 0, 0, 1], 49151)))
        .await
    {
        Ok(d) => d,
        Err(e) => {
            ui.log(format!("[安装] 读取本机隧道失败：{e:?}"));
            fail(&ui, "安装", "无法读取设备隧道地址，请展开详情查看原因。");
            return keep_alive().await;
        }
    };
    let dev = match devices.into_iter().next() {
        Some((_udid, d)) => d,
        None => {
            fail(&ui, "安装", "本机隧道里没有发现设备。");
            return keep_alive().await;
        }
    };
    let addr: IpAddr = match dev.tunnel_address.parse() {
        Ok(a) => a,
        Err(e) => {
            ui.log(format!("[安装] 隧道地址解析失败 {}: {e}", dev.tunnel_address));
            fail(&ui, "安装", "隧道地址无效，请展开详情查看原因。");
            return keep_alive().await;
        }
    };
    let provider = TcpProvider {
        addr,
        scope_id: None,
        pairing_file: pf,
        label: "treenb-bootstrap".into(),
    };

    let install_ui = ui.clone();
    let install_progress = move |p: f32| {
        let u = install_ui.clone();
        async move {
            u.set_step("安装", "active", &format!("正在安装… {}%", p as u32));
        }
    };
    match sideloader
        .install_app(&provider, signed, false, Some(install_progress), None)
        .await
    {
        Ok(_) => {
            ui.set_step("安装", "done", "已安装到设备");
            ui.set_step("交接", "done", "证书与配对文件已保留在本机");
            ui.log("[完成] TreeNB 已安装，请回桌面查看。");
        }
        Err(e) => {
            let msg = format!("{e:?}");
            ui.log(format!("[安装失败] {msg}"));
            fail(&ui, "安装", "安装失败，请展开详情查看原因。");
        }
    }

    keep_alive().await;
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
