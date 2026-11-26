//
//  TNBFlickerGuard.swift
//  TreeNB —— 从后台切回前台时的闪屏抑制
//
//  现象：App 从后台切回（或冷启动首帧）会「闪一下」。
//  根因：ShellTabBarController.viewWillAppear 每次都调 ShellTheme.applyAppearance()，
//        对 window.overrideUserInterfaceStyle 赋值会强制整棵视图树重建 traitCollection
//        并重绘；系统快照 → 重绘后界面之间出现浅/深或材质跳变。
//        （治本已由 patch_upstream.sh B1g4 让 applyAppearance 幂等短路）
//
//  本文件做「治标」：在 willEnterForeground 的第一时间同步拍一张当前 window 快照，
//  用高于状态栏的 windowLevel 盖住，让重绘发生在遮罩之下，完成后 0.25s 淡出。
//  注意：必须用快照而不是纯色，否则浅色/深色主题下遮罩本身也会闪。
//
//  由 patch_upstream.sh 挂载进主 App target，并在 SceneDelegate.sceneWillEnterForeground
//  调用 TNBFlickerGuard.cover()，在 reconcile 完成后调用 reveal()。
//

import UIKit

enum TNBFlickerGuard {
    private static var coverWindow: UIWindow?
    private static var revealWork: DispatchWorkItem?

    /// 在切前台的最早时机同步调用：拍快照 → 盖遮罩。
    static func cover() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { cover() }
            return
        }
        guard coverWindow == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ??
                UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              // 取主 window（不含我们自己的遮罩层）
              let source = scene.windows.first(where: { $0 != coverWindow && !$0.isHidden }),
              let snapshot = source.snapshotView(afterScreenUpdates: false) else { return }

        let w = UIWindow(windowScene: scene)
        // 高于状态栏与 alert，确保第一帧就盖住底层重绘。
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 200)
        w.backgroundColor = .clear
        // 快照铺满，frame 与来源 window 一致。
        snapshot.frame = source.bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let holder = UIViewController()
        holder.view.backgroundColor = source.backgroundColor ?? .systemBackground
        holder.view.addSubview(snapshot)
        w.rootViewController = holder
        w.alpha = 1          // 不淡入：第一帧就完全盖住
        w.isHidden = false
        coverWindow = w

        // 兜底：任何情况下 1.2s 后一定撤掉遮罩，绝不把用户卡在快照上。
        revealWork?.cancel()
        let work = DispatchWorkItem { reveal() }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// 主题重绘 / reconcile 完成后调用：淡出遮罩。
    static func reveal() {
        DispatchQueue.main.async {
            revealWork?.cancel()
            revealWork = nil
            guard let w = coverWindow else { return }
            coverWindow = nil
            UIView.animate(withDuration: 0.25, delay: 0,
                           options: [.curveEaseOut, .beginFromCurrentState]) {
                w.alpha = 0
            } completion: { _ in
                w.isHidden = true
                w.rootViewController = nil
            }
        }
    }
}
