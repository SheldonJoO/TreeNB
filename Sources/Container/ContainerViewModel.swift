//
//  ContainerViewModel.swift
//  TreeNB —— 容器 Tab 状态机
//

import Foundation
import SwiftUI
import LiveContainerShared

enum ContainerLayoutMode: String {
    case list
    case grid
}

@MainActor
final class ContainerViewModel: ObservableObject {
    @Published var guestApps: [String] = []
    @Published var isBootstrapping = true
    @Published var installProgress: String? = nil
    @Published var lastError: String? = nil
    /// 容器应用展示方式（宫格/列表），持久化到 UserDefaults。
    @Published var layoutMode: ContainerLayoutMode = {
        let raw = UserDefaults.standard.string(forKey: "TNBContainerLayoutMode")
        return ContainerLayoutMode(rawValue: raw ?? "") ?? .list
    }()

    private let engine = LCEngineEntry.shared()

    func toggleLayout() {
        layoutMode = (layoutMode == .list) ? .grid : .list
        UserDefaults.standard.set(layoutMode.rawValue, forKey: "TNBContainerLayoutMode")
    }

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
        // 冷启动接管 guest 失败时，ObjC 侧把上游错误写进 TNBLastGuestLaunchError。
        // 在这里取出展示并清除，避免"闪一下回主界面却没有任何提示"。
        if let guestErr = UserDefaults.standard.string(forKey: "TNBLastGuestLaunchError"),
           !guestErr.isEmpty {
            lastError = "应用启动失败：\(guestErr)"
            UserDefaults.standard.removeObject(forKey: "TNBLastGuestLaunchError")
        }
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

    /// 卸载 guest：从磁盘真删（.app + 容器数据），再刷新列表与小组件快照。
    func uninstall(bundle: String) async {
        // ObjC 尾参 NSError** → Swift throws；不传 error: 实参。
        var err: NSError?
        var ok = false
        do {
            // NSError** → Swift throws 后 BOOL 返回值被丢弃（成功=不抛异常），
            // 不能写 ok = try ...（会报 cannot assign () to Bool）。
            try engine.uninstallGuest(bundle)
            ok = true
        } catch {
            err = error as NSError
        }
        if !ok {
            lastError = err?.localizedDescription ?? "删除失败"
        }
        await refresh()
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
