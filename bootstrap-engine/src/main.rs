//! treenb-bootstrap — on-device signing & install engine.
//!
//! Runs inside Open Minis (aarch64 Linux container) on the iPhone itself.
//! Flow: developer-mode helper -> local web page for Apple ID -> self-pair ->
//!       sign TreeNB IPA with the user's own Apple ID -> install to system.
//!
//! This is a ground-up implementation using independent OSS libraries
//! (isideload MIT, idevice MIT). No siboot / SideInstaller code is used.

use std::env;

fn main() {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("failed to install rustls crypto provider");
    // isideload::init() wires up detailed error reporting for network calls.
    // Called here (not deferred) so any early failure is diagnosable.

    let args: Vec<String> = env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("help");

    match mode {
        "developer-mode" => {
            println!("[treenb] developer-mode helper: not implemented yet");
        }
        "install" => {
            println!("[treenb] sign & install: not implemented yet");
        }
        "version" | _ => {
            println!("treenb-bootstrap 0.1.0 (aarch64-linux-musl)");
            println!("usage: treenb-bootstrap <developer-mode|install>");
        }
    }
}
