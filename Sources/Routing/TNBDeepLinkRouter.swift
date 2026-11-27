//
//  TNBDeepLinkRouter.swift
//  TreeNB —— 统一深链路由
//
//  接入点：openSSS 的 SceneDelegate 两处 URL 入口里调用
//      TNBDeepLinkRouter.shared.handle(url: url)
//    · scene(_:willConnectTo:options:)   —— 冷启动（App 未运行时点小组件）
//    · scene(_:openURLContexts:)         —— 热启动（App 在后台时点小组件）
//  这两处由 patch_upstream.sh 自动注入。
//
//  支持的 scheme（都在 Info.plist 注册）：
//    openssai://container-launch?bundle-name=X&container-folder-name=Y   ← 小组件主用
//    livecontainer://livecontainer-launch?...                           ← 兼容老组件
//    openssai://import-app          ← 导入 IPA（openSSS 原有 sidestore:// 也透传）
//
//  设计要点（2026-11-24 修复）：
//  以前这里只发通知让容器 Tab 启动 guest，但冷启动时 URL 回调早于 Tab 的
//  观察者注册，通知直接丢失 → 点小组件只进 openSSS 界面。现在直接在路由里
//  调 LCEngineEntry.launchGuestApp（它写 selected 键 + 重启进程，不需要 UI 上下文），
//  冷/热启动都可靠。切 Tab 通知仅保留作 UI 反馈，不再是启动的必要条件。
//

import Foundation
import UIKit
import LiveContainerShared

public final class TNBDeepLinkRouter {

    public static let shared = TNBDeepLinkRouter()
    private init() {}

    /// 深链通知名（ShellTabBarController 监听后切到容器 Tab，仅 UI 反馈用）
    public static let switchToContainerTab = Notification.Name("TNBSwitchToContainerTab")
    public static let launchGuest = Notification.Name("TNBDeepLinkLaunchGuest")
    public static let importApp = Notification.Name("TNBDeepLinkImportApp")
    /// 一键自举中心收到配对文件/证书后的 UI 刷新通知
    public static let bootstrapDidImport = Notification.Name("TNBootstrapDidImport")

    /// 返回是否由 TreeNB 处理了这个 URL
    @discardableResult
    public func handle(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["openssai", "livecontainer", "sidestore"].contains(scheme) else {
            return false
        }

        let host = url.host?.lowercased() ?? ""
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // URLQueryItem.value 是 String?；过滤掉没有值的项，得到 [String: String]。
        let query: [String: String] = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })

        switch host {
        case "widget-kick":
            // App Intent（iOS17+）打开主 App 的唤醒 URL。目标 bundle 已由 Intent
            // 在点击瞬间写进共享 Keychain；冷启动时 main.swift 已消费并接管（不会走到
            // 这里），能进到这里说明是热启动（App 在后台）——此时在这里消费 pending。
            if let pending = TNBWidgetStore.consumePendingLaunch(), !pending.bundleName.isEmpty {
                NSLog("[TreeNB] 热启动消费小组件 pending launch: %@", pending.bundleName)
                let engine = LCEngineEntry.shared()
                do {
                    try engine.launchGuestApp(pending.bundleName,
                                              containerFolder: pending.container.isEmpty ? nil : pending.container,
                                              launchURL: nil,
                                              classicMode: 0)
                    return true
                } catch {
                    UserDefaults.standard.set(error.localizedDescription,
                                              forKey: "TNBLastGuestLaunchError")
                }
            }
            // 没有 pending（例如用户在锁屏点了但已被消费）：非 TreeNB 处理，交还 openSSS。
            return false

        case "container-launch", "livecontainer-launch":
            guard let bundle = query["bundle-name"], !bundle.isEmpty else { return false }
            let container = query["container-folder-name"]
            let launchURL = query["url"]
            NSLog("[TreeNB] 小组件深链启动 guest: %@ container=%@ url=%@",
                  bundle, container ?? "(默认)", launchURL ?? "(无)")
            // 直接调引擎启动（写 selected + 重启进程），不依赖 UI 观察者。
            // 成功时本进程随即被 SIGKILL，由 main.swift 冷启动接管进 guest。
            let engine = LCEngineEntry.shared()
            var err: NSError?
            var ok = false
            do {
                try engine.launchGuestApp(bundle,
                                          containerFolder: container,
                                          launchURL: launchURL,
                                          classicMode: 0)
                ok = true
            } catch {
                err = error as NSError
            }
            if !ok {
                // 启动失败原因透传到容器页展示，别静默停在这里。
                UserDefaults.standard.set(
                    err?.localizedDescription ?? "小组件启动应用失败，请打开树应用容器页重试",
                    forKey: "TNBLastGuestLaunchError")
                NSLog("[TreeNB] 小组件启动 guest 失败: %@", err?.localizedDescription ?? "未知")
            }
            // UI 反馈：切到容器 Tab（若 UI 已就绪）；冷启动时该通知可能无人接，无妨。
            NotificationCenter.default.post(name: Self.switchToContainerTab, object: nil)
            return ok

        case "import-app", "import":
            NotificationCenter.default.post(name: Self.switchToContainerTab, object: nil)
            NotificationCenter.default.post(name: Self.importApp, object: nil)
            return true

        case "pairing-file":
            // TreeNB 新发明：从 SideStore / 网页一键把配对文件递过来，
            // 免去用户手动找文件、导入的麻烦（对应 siboot 的 pairingFile 深链）。
            // 格式：openssai://pairing-file?data=<base64 pairing file>
            guard let b64 = query["data"],
                  let raw = Data(base64Encoded: b64),
                  let text = String(data: raw, encoding: .utf8),
                  !text.isEmpty else {
                NSLog("[TreeNB] pairing-file 深链数据无效")
                return false
            }
            do {
                let parsed = try PairingFileManager.shared.savePairingFile(contents: text)
                PairingFileManager.shared.persistedActiveProtocol = parsed.mode
                UserDefaults.standard.set("配对文件已从深链导入 ✅", forKey: "TNBootstrapLastResult")
                NotificationCenter.default.post(name: Self.bootstrapDidImport, object: nil)
                NSLog("[TreeNB] 配对文件深链导入成功 mode=%@", parsed.mode.rawValue)
                return true
            } catch {
                UserDefaults.standard.set("配对文件导入失败：\(error.localizedDescription)",
                                          forKey: "TNBootstrapLastResult")
                NotificationCenter.default.post(name: Self.bootstrapDidImport, object: nil)
                return false
            }

        case "bootstrap":
            // openssai://bootstrap —— 直接打开一键自举中心
            NotificationCenter.default.post(name: Self.switchToContainerTab, object: nil)
            NotificationCenter.default.post(name: Self.bootstrapDidImport, object: "open")
            return true

        default:
            // 交给 openSSS 原有路由（sidestore:// 的配对、应用源等）
            return false
        }
    }
}

// MARK: - Shell 接入辅助（给 ShellTabBarController 用）

public extension TNBDeepLinkRouter {
    /// 在 ShellTabBarController.viewDidLoad 里调用，自动切 Tab（仅 UI 反馈）。
    static func installShellObserver(_ shell: UITabBarController, containerTabIndex: Int) {
        let center = NotificationCenter.default
        // 弱引用 shell，避免循环
        center.addObserver(forName: switchToContainerTab, object: nil, queue: .main) { [weak shell] _ in
            shell?.selectedIndex = containerTabIndex
        }
    }
}
