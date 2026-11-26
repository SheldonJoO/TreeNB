//
//  TNBFlickerGuard.swift
//  TreeNB —— 统一的 TreeNB 启动画面遮罩
//
//  设计（2026-11-27 重写）：
//    闪屏的本质不是"重建"，而是"重建的中间态被眼睛看到"。真机观察到
//    "打开上一个用过的 App 不闪"，因为进程还活着、系统直接复用快照、零中间态；
//    冷启动/深链要重走 LaunchScreen → SplashView → 宿主 UI → guest 这一长串，
//    每一步之间都可能跳变，就是闪。
//
//    正解不是拍快照（快照内容不可控，深色模式下快照本身可能就是错的），
//    而是无论底层发生什么，都在最早时机盖一张【确定的、统一的 TreeNB 启动画面】，
//    让所有中间态在它之下完成，再淡出 —— 把闪"藏进"启动画面里，代价是略微
//    牺牲启动速度（minDisplay），这与"任何 App 打开都需要启动时间"的用户预期一致。
//
//  覆盖三层：
//    ① 后台切回的系统快照 → 真实界面跳变
//    ④ 小组件/深链唤醒宿主 → guest 的中间态（由 widget-kick 分支主动 cover）
//    （③ 冷启动第一帧由品牌化 LaunchScreen.storyboard 负责，不在此文件）
//  （② 主题重绘的治本在 patch_upstream.sh B1g4：applyAppearance 幂等短路）
//
//  由 patch_upstream.sh 挂载进主 App target，调用点：
//    · SceneDelegate.sceneWillEnterForeground  cover()（切前台 + 冷启动）
//    · LaunchViewController.transitionToMainInterface completion  reveal()
//    · TNBDeepLinkRouter 的 widget-kick 分支  cover()（小组件 App Intent 路径）
//

import UIKit

enum TNBFlickerGuard {
    private static var coverWindow: UIWindow?
    private static var pendingWork: DispatchWorkItem?
    private static var coverTime: Date?

    /// 最短展示时间：让底下的重建/跳变都发生在遮罩之下。牺牲一点点启动速度，换取零可见闪。
    private static let minDisplay: TimeInterval = 0.35
    /// 兜底超时：任何情况下都不把用户卡在启动画面上。
    private static let hardTimeout: TimeInterval = 1.5

    /// 在"打开/切换"的最早时机同步调用：第一帧就完全盖住底层。
    static func cover() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { cover() }
            return
        }
        guard coverWindow == nil,
              let scene = activeScene() else { return }

        let w = UIWindow(windowScene: scene)
        // 高于状态栏、悬浮按钮、alert、TreeLaunchOverlay，确保第一帧盖住一切。
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 300)
        w.rootViewController = TNBCoverController()
        w.alpha = 1          // 不淡入：第一帧就完全不透明
        w.isHidden = false
        coverWindow = w
        coverTime = Date()

        // 兜底：hardTimeout 后无论如何撤掉，绝不停在启动画面。
        scheduleReveal(after: hardTimeout)
    }

    /// 底层重建/数据刷新完成后调用：保证至少展示 minDisplay 再淡出。
    static func reveal() {
        DispatchQueue.main.async {
            guard coverWindow != nil else { return }
            let elapsed = coverTime.map { Date().timeIntervalSince($0) } ?? minDisplay
            scheduleReveal(after: max(0, minDisplay - elapsed))
        }
    }

    private static func scheduleReveal(after delay: TimeInterval) {
        pendingWork?.cancel()
        let work = DispatchWorkItem { performReveal() }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func performReveal() {
        DispatchQueue.main.async {
            pendingWork?.cancel()
            pendingWork = nil
            coverTime = nil
            guard let w = coverWindow else { return }
            coverWindow = nil
            UIView.animate(withDuration: 0.28, delay: 0,
                           options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
                w.alpha = 0
            } completion: { _ in
                w.isHidden = true
                w.rootViewController = nil
            }
        }
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

/// 统一的 TreeNB 启动画面：与 SplashView / TreeLaunchOverlay 同一套视觉。
private final class TNBCoverController: UIViewController {
    private var glow: CAGradientLayer?

    override func viewDidLoad() {
        super.viewDidLoad()

        let accent = UIColor(red: 0x19 / 255.0, green: 0xD3 / 255.0, blue: 0xB5 / 255.0, alpha: 1)
        // 跟随系统深浅：深色下不再闪白光。
        view.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .light
                ? UIColor(red: 0xF2 / 255.0, green: 0xF2 / 255.0, blue: 0xF7 / 255.0, alpha: 1)
                : UIColor(red: 0x0A / 255.0, green: 0x0A / 255.0, blue: 0x0F / 255.0, alpha: 1)
        }

        let gradient = CAGradientLayer()
        gradient.colors = [accent.withAlphaComponent(0.20).cgColor, UIColor.clear.cgColor]
        gradient.locations = [0, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        view.layer.insertSublayer(gradient, at: 0)
        glow = gradient

        let logo = UIImageView(image: UIImage(named: "AppLogo") ?? UIImage(systemName: "tree.fill"))
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 92),
            logo.heightAnchor.constraint(equalToConstant: 92)
        ])

        let holder = UIView()
        holder.backgroundColor = accent.withAlphaComponent(0.16)
        holder.layer.cornerRadius = 26
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(logo)
        NSLayoutConstraint.activate([
            holder.widthAnchor.constraint(equalToConstant: 116),
            holder.heightAnchor.constraint(equalToConstant: 116),
            logo.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: holder.centerYAnchor)
        ])

        let brand = UILabel()
        brand.text = "🌲树应用"
        brand.font = .systemFont(ofSize: 15, weight: .semibold)
        brand.textColor = .secondaryLabel
        brand.textAlignment = .center

        let title = UILabel()
        title.text = "正在切换"
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = .label
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = "请稍候…"
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .tertiaryLabel
        subtitle.textAlignment = .center

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = accent
        spinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [holder, brand, title, subtitle, spinner])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.setCustomSpacing(20, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -28),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        glow?.frame = CGRect(x: 0, y: 0,
                             width: view.bounds.width,
                             height: view.bounds.height * 0.75)
    }
}
