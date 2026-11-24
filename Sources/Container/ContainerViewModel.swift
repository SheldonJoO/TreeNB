//
//  ContainerViewModel.swift
//  TreeNB —— 容器 Tab 状态机
//

import Foundation
import SwiftUI
import LiveContainerShared

@MainActor
final class ContainerViewModel: ObservableObject {
    @Published var guestApps: [String] = []
    @Published var isBootstrapping = true
    @Published var installProgress: String? = nil
    @Published var lastError: String? = nil

    private let engine = LCEngineEntry.shared()

    /// 引擎初始化（幂等）
    func bootstrap() async {
        // ObjC 尾参 NSError** → Swift throws；不要再传 error: 实参。
        var err: NSError?
        var ok = false
        do {
            try engine.bootstrap()
            ok = true
        } catch {
            err = error as NSError
        }
        isBootstrapping = false
        if !ok { lastError = err?.localizedDescription ?? "引擎初始化失败" }
        await refresh()
    }

    /// 刷新已安装 guest 列表
    func refresh() async {
        guestApps = engine.installedGuestBundleNames().sorted()
        // 同步刷新小组件快照（容器应用变动后小组件列表跟着更新）
        _ = TNBWidgetSnapshotWriter.refresh()
    }

    /// 导入并安装 IPA
    func install(ipaURL: URL) async {
        lastError = nil
        installProgress = "准备安装…"
        // security-scoped resource（UIDocumentPicker asCopy 通常已拷贝，但保险起见）
        let accessed = ipaURL.startAccessingSecurityScopedResource()
        defer { if accessed { ipaURL.stopAccessingSecurityScopedResource() } }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            engine.installIPA(at: ipaURL, progress: { phase, pct in
                Task { @MainActor in
                    self.installProgress = "\(phase) \(Int(pct * 100))%"
                }
            }, completion: { [weak self] success, _, err in
                Task { @MainActor in
                    self?.installProgress = nil
                    if success {
                        await self?.refresh()
                    } else {
                        self?.lastError = err?.localizedDescription ?? "安装失败"
                    }
                    cont.resume()
                }
            })
        }
    }

    /// 启动 guest（进程主线权交给 guest；返回时宿主已恢复）
    func launch(bundle: String) async {
        var err: NSError?
        var ok = false
        do {
            try engine.launchGuestApp(bundle,
                                      containerFolder: nil,
                                      launchURL: nil,
                                      classicMode: 0)
            ok = true
        } catch {
            err = error as NSError
        }
        if !ok {
            lastError = err?.localizedDescription ?? "启动失败"
        } else {
            // guest 退出后 LC 侧会发 TNBGuestDidExitNotification，refresh 会触发
        }
    }
}
