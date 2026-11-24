//
//  TNBLaunchGuestIntent.swift
//  TreeNB —— 小组件点击直达 guest 的 App Intent（iOS 17+）
//
//  为什么需要 App Intent（而不是普通 Link）：
//    Link 只能发 URL，bundle 参数要等主 App 的 SceneDelegate 收到 URL 才能解析，
//    而 main.swift 的 guest 冷启动接管在这之前就跑了 —— 它读到的是上次残留的
//    selected 键，于是"点组件进的是上次打开的 App"，且会先闪一下 openSSS。
//    App Intent 的 perform() 在点击的那一刻同步把目标 bundle 写进共享 Keychain，
//    再打开 App；main.swift 冷启动第一步消费它 → 一次冷启直达指定 guest，零闪屏。
//
//  编译：本文件编进 AltWidgetExtension target（iOS 16 部署目标），
//  OpensIntent/OpenURLIntent 是 iOS 17 API，用 @available 保护，
//  iOS 16 回退到 TreeLaunchWidget 里的 Link 分支（有闪屏但功能正确）。
//

import Foundation
import AppIntents

@available(iOS 17.0, *)
struct TNBLaunchGuestIntent: AppIntent {
    static var title: LocalizedStringResource = "启动容器应用"
    static var description = IntentDescription("打开树应用容器中的指定应用")

    @Parameter(title: "应用目录名")
    var bundleName: String

    // AppIntent 要求无参 init（Siri/快捷指令反解用）
    init() {}

    init(bundleName: String) {
        self.bundleName = bundleName
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        // 目标写入共享 Keychain（主 App 与 Widget 用同一个 keychain-access-group）。
        // 小组件快照的 container 恒为空，用默认容器即可。
        TNBWidgetStore.writePendingLaunch(bundle: bundleName, container: "")
        // 唤醒主 App；bundle 不再塞进 URL —— main.swift 从 Keychain 读。
        // widget-kick 这个 host 在 router 里作为热启动兜底消费点。
        return .result(opensIntent: OpenURLIntent(URL(string: "openssai://widget-kick")!))
    }
}
