//
//  TNBDeepLinkRouter.swift
//  TreeNB —— 统一深链路由
//
//  接入点：openSSS 的 SceneDelegate.onOpenURL / AppDelegate 的 openURL 里调用
//      TNBDeepLinkRouter.shared.handle(url: url)
//
//  支持的 scheme（都在 Info.plist 注册）：
//    openssai://container-launch?bundle-name=X&container-folder-name=Y   ← 小组件主用
//    livecontainer://livecontainer-launch?...                           ← 兼容老组件
//    openssai://import-app          ← 导入 IPA（openSSS 原有 sidestore:// 也透传）
//
//  设计：深链不直接启动 guest（那需要 UI 上下文），而是发通知让 Shell 切到容器 Tab，
//  再由容器 Tab 调 LCEngineEntry.launchGuestApp。这样和 openSSS 现有深链观察者模式一致。
//

import Foundation
import UIKit

public final class TNBDeepLinkRouter {

    public static let shared = TNBDeepLinkRouter()
    private init() {}

    /// 深链通知名（ShellTabBarController 监听后切到容器 Tab）
    public static let switchToContainerTab = Notification.Name("TNBSwitchToContainerTab")
    public static let launchGuest = Notification.Name("TNBDeepLinkLaunchGuest")
    public static let importApp = Notification.Name("TNBDeepLinkImportApp")

    /// 返回是否由 TreeNB 处理了这个 URL
    @discardableResult
    public func handle(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["openssai", "livecontainer", "sidestore"].contains(scheme) else {
            return false
        }

        let host = url.host?.lowercased() ?? ""
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })

        switch host {
        case "container-launch", "livecontainer-launch":
            guard let bundle = query["bundle-name"], !bundle.isEmpty else { return false }
            var info: [String: Any] = ["bundle-name": bundle]
            if let container = query["container-folder-name"] {
                info["container-folder-name"] = container
            }
            if let launchURL = query["url"] {
                info["launch-url"] = launchURL
            }
            NotificationCenter.default.post(name: Self.switchToContainerTab, object: nil)
            NotificationCenter.default.post(name: Self.launchGuest, object: nil, userInfo: info)
            return true

        case "import-app", "import":
            NotificationCenter.default.post(name: Self.switchToContainerTab, object: nil)
            NotificationCenter.default.post(name: Self.importApp, object: nil)
            return true

        default:
            // 交给 openSSS 原有路由（sidestore:// 的配对、应用源等）
            return false
        }
    }
}

// MARK: - Shell 接入辅助（给 ShellTabBarController 用）

public extension TNBDeepLinkRouter {
    /// 在 ShellTabBarController.viewDidLoad 里调用，自动切 Tab + 触发 guest 启动
    static func installShellObserver(_ shell: UITabBarController, containerTabIndex: Int) {
        let center = NotificationCenter.default
        // 弱引用 shell，避免循环
        center.addObserver(forName: switchToContainerTab, object: nil, queue: .main) { [weak shell] _ in
            shell?.selectedIndex = containerTabIndex
        }
    }
}
