//! treenb-bootstrap — on-device signing & install engine.
//!
//! Runs inside Open Minis (aarch64 Linux container) on the iPhone itself.
//! The terminal only starts the engine and prints a loopback URL; all user
//! interaction happens in the local web page (Minis's built-in browser):
//!   Connect -> Apple ID -> Sign -> Install -> Handover
//!
//! Ground-up implementation using independent OSS libraries
//! (isideload MIT, idevice MIT). No siboot / SideInstaller code is used.

mod web;

use std::env;

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
            // Accept `--ipa <path>` (ignored for now — the signing stage is not
            // wired up yet, but keep the CLI contract stable with install.txt).
            let ipa = args.windows(2).find(|w| w[0] == "--ipa").map(|w| w[1].clone());
            if let Some(p) = &ipa {
                println!("[treenb] 待签名 IPA：{}", p);
            }
            let rt = tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()
                .expect("failed to build tokio runtime");
            rt.block_on(run_install());
        }
        "version" | _ => {
            println!("treenb-bootstrap 0.1.0 (aarch64-linux-musl)");
            println!("usage: treenb-bootstrap <developer-mode|install>");
        }
    }
}

async fn run_install() {
    let ui = web::WebUI::start()
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

    // Best-effort: try to open the page in Minis's browser. If the helper is
    // unavailable, the printed URL above still works when tapped/pasted.
    let _ = std::process::Command::new("xdg-open").arg(&ui.url).spawn();

    // Engine loop: the rest of the pipeline (self-pair, Apple ID sign-in via
    // isideload, sign, install, handover) is driven from the web UI callbacks.
    // Keep the runtime alive while the page is open.
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(3600)).await;
    }
}
