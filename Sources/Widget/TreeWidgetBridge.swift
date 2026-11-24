//
//  TreeWidgetBridge.swift
//  TreeNB —— TreeWidget 数据桥接（并入 openSSS AltWidgetExtension）
//
//  从上游 TreeWidgetSnapshot.swift 适配而来，改动点：
//   1. Keychain service: com.kdt.livecontainer.treeWidget → com.openssai.app.treeWidget
//   2. App Group: 用 openSSS 的 group.$(APP_GROUP_IDENTIFIER)，兼容老 group
//   3. 深链: livecontainer:// → openssai://（保留 livecontainer:// 兼容）
//   4. 去掉独立 @main，作为 AltWidgetBundle 的一个 Widget 并入
//
//  宿主侧写入：openSSS 的 WidgetDataManager.publishCurrentInstalledAppsIfNeeded 里
//  追加调用 TreeWidgetSnapshotWriterV2.refresh()，即可复用现有数据管道。
//

import Foundation
import UIKit
import Security

// MARK: - 数据模型（与宿主写入端共用）

public struct TNBWidgetAppEntry: Codable, Identifiable {
    public let name: String
    public let bundleName: String
    public let container: String
    public let icon: String
    public var iconData: String? = nil

    public var id: String { bundleName + "|" + container }

    /// 深链：主用 openssai://，图标点击直达容器 Tab 启动。
    /// host 必须是 livecontainer-launch —— LiveContainer 的 TweakLoader hook
    /// (UIKit+GuestHooks.m LCHandleControlAppURL) 只认这个 host 做 App 切换；
    /// 用 container-launch 会被落到 default 分支静默吞掉（guest 前台时点组件没反应）。
    /// scheme 用 openssai（= guest 运行时 lcAppUrlScheme，由 TNBHostUrlScheme 注入）。
    public var launchURL: URL? {
        var c = URLComponents(string: "openssai://livecontainer-launch")
        var items = [URLQueryItem(name: "bundle-name", value: bundleName)]
        if !container.isEmpty {
            items.append(URLQueryItem(name: "container-folder-name", value: container))
        }
        c?.queryItems = items
        return c?.url
    }

    public var image: UIImage? {
        guard let s = iconData, let d = Data(base64Encoded: s) else { return nil }
        return UIImage(data: d)
    }
}

public struct TNBWidgetSnapshot: Codable {
    public let version: Int
    public let apps: [TNBWidgetAppEntry]
}

// MARK: - Keychain 通道（侧载 appex 的 App Group 常不可用，这是主通道）

public enum TNBWidgetStore {
    public static let keychainService = "com.openssai.app.treeWidget"
    public static let keychainAccount = "snapshot.v1"

    /// 宿主写入（App 进程）
    @discardableResult
    public static func write(_ snapshot: TNBWidgetSnapshot) -> OSStatus {
        guard let data = try? JSONEncoder().encode(snapshot) else { return -1 }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(base as CFDictionary,
                                 [kSecValueData as String: data] as CFDictionary)
        }
        return status
    }

    /// Widget 读取（appex 进程）
    public static func read() -> TNBWidgetSnapshot? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(TNBWidgetSnapshot.self, from: data)
    }

    // MARK: - Pending launch（widget 点击 → 主 App 冷启动直达指定 guest）
    // 存同一 Keychain group 的独立 account。冷启动 main.swift 在 UIApplicationMain
    // 之前读它，避免依赖 SceneDelegate 才拿得到的 URL 参数（那会导致残留 selected
    // 被误用 = 进错 App，且先闪一下 openSSS）。

    public static let pendingAccount = "pending-launch.v1"

    public struct PendingLaunch: Codable {
        public let bundleName: String
        public let container: String
        public let timestamp: TimeInterval
    }

    /// Widget 点击时写入目标 guest（App Intent 的 perform 里调用）
    public static func writePendingLaunch(bundle: String, container: String) {
        let pending = PendingLaunch(bundleName: bundle,
                                    container: container,
                                    timestamp: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(pending) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: pendingAccount
        ]
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(base as CFDictionary,
                          [kSecValueData as String: data] as CFDictionary)
        }
    }

    /// 主 App 冷启动时读取并清除。超过 10 秒视为陈旧丢弃（避免误启动）。
    public static func consumePendingLaunch() -> PendingLaunch? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: pendingAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let pending = try? JSONDecoder().decode(PendingLaunch.self, from: data) else {
            return nil
        }
        // 无论是否过期都删除，杜绝重复消费
        let del: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: pendingAccount
        ]
        SecItemDelete(del as CFDictionary)
        guard Date().timeIntervalSince1970 - pending.timestamp < 10 else { return nil }
        return pending
    }

    /// App Group 辅助通道（能用时双写，提高命中率）
    public static func writeToAppGroup(_ snapshot: TNBWidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let groups = ["group.openssai.app",
                      "group.com.SideStore.SideStore",
                      "group.com.kdt.livecontainer"]
        for gid in groups {
            guard let root = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: gid) else { continue }
            let dir = root.appendingPathComponent("TreeWidget", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent("apps.json"), options: .atomic)
        }
    }
}
