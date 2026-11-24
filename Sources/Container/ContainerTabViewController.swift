//
//  ContainerTabViewController.swift
//  TreeNB —— openSSS Shell 的第四个 Tab「容器」
//
//  接入方式（见 docs/启动链改造设计.md §3.1）：
//    ShellTabBarController 里新增：
//      lazy var containerNav = UINavigationController(rootViewController: ContainerTabViewController())
//    并把 viewControllers = [appsNav, locationNav, containerNav, profileNav]
//
//  这个 VC 用 UIHostingController 内嵌 SwiftUI 的 ContainerRootView，
//  数据源走 LCEngineEntry（内嵌 framework），不依赖 LiveContainer 自己的 AppDelegate。
//

import UIKit
import SwiftUI

public final class ContainerTabViewController: UIViewController {

    public init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // 外层 containerNav 必须是空壳：标题、工具栏都由内层 SwiftUI NavigationStack 提供。
    // 若外层导航栏可见，状态栏下方会多出一根 44pt 空 bar，表现为标题"没回到顶部"、
    // 标题与状态栏之间一大块黑空白。每次 appear 都强制隐藏，防止 state restoration 复原。
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        // 标题统一由内嵌 SwiftUI 的 .navigationTitle("🌲TreeApps") 设置。
        // 这里不再设 title —— 之前 VC 与 SwiftUI 各设一次，导致顶部出现两个"容器"。
        view.backgroundColor = .systemBackground

        let root = ContainerRootView()
        let host = UIHostingController(rootView: root)
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)

        // guest 退出后回到这个 Tab 时刷新列表
        NotificationCenter.default.addObserver(
            self, selector: #selector(guestDidExit),
            name: Notification.Name("TNBGuestDidExitNotification"), object: nil)
    }

    @objc private func guestDidExit() {
        // SwiftUI 视图通过 environmentObject 自己响应；这里留钩子给需要原生刷新的场景
    }
}
