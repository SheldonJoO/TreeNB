//
//  ContainerRootView.swift
//  TreeNB —— 容器 Tab 主界面（SwiftUI）
//
//  功能闭环：导入 IPA → 容器内安装 → 列表 → 点按启动 guest → 悬浮键返回。
//  数据全部来自 LCEngineEntry（内嵌 LC 引擎 framework 的适配层）。
//
//  这是从上游 LCAppListView (~1500 行) 精简出的 TreeNB 专用子集，
//  只保留"多 App 侧载 + 启动"最小闭环；应用源/JIT/多任务/tweak 等高级功能
//  在 Stage 2 按需从 LiveContainerSwiftUI.framework 搬进来。
//

import SwiftUI
import UniformTypeIdentifiers
import LiveContainerShared

struct ContainerRootView: View {
    @StateObject private var model = ContainerViewModel()
    @State private var showImporter = false
    @State private var showWidgetSettings = false
    @State private var showCertificate = false
    @State private var showImportMenu = false
    @State private var showAPK = false
    @State private var showBootstrap = false

    var body: some View {
        AdaptiveNavigation {
            Group {
                if model.isBootstrapping {
                    ProgressView("正在初始化容器引擎…")
                } else if model.guestApps.isEmpty {
                    emptyState
                } else {
                    guestList
                }
            }
            .overlay {
                if let progress = model.installProgress {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(progress).font(.caption)
                    }
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("🌲TreeApps")
            // 用户要求标题回到导航栏顶部：large 会让大标题落到内容区半中，inline 才是顶部。
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 左侧：布局切换 + 小组件筛选。两者图标刻意选成不同形状
                // （网格 vs 星标），避免之前 square.grid / rectangle.grid 太像分不清。
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    SwiftUI.Button {
                        model.toggleLayout()
                    } label: {
                        Image(systemName: model.layoutMode == .list ? "square.grid.2x2" : "list.bullet")
                    }
                    .accessibilityLabel(model.layoutMode == .list ? "切换到宫格" : "切换到列表")
                    SwiftUI.Button {
                        showWidgetSettings = true
                    } label: {
                        Image(systemName: "star.fill")
                    }
                    .accessibilityLabel("小组件应用设置")
                }
                // 右侧：证书 + 导入（+ 仍留在最右，符合 iOS 习惯）。
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    #if DEBUG || TNB_SPIKE
                    NavigationLink {
                        SpikeResultView()
                    } label: {
                        Image(systemName: "flask.fill")
                    }
                    .accessibilityLabel("Spike 自检")
                    #endif
                    SwiftUI.Button {
                        showBootstrap = true
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
                    .accessibilityLabel("一键自举中心")
                    SwiftUI.Button {
                        showCertificate = true
                    } label: {
                        Image(systemName: "key.fill")
                    }
                    .accessibilityLabel("无 JIT 证书设置")
                    SwiftUI.Button {
                        showImportMenu = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("安装应用")
                }
            }
            .sheet(isPresented: $showImporter) {
                IPAImporter { url in
                    showImporter = false
                    Task { await model.install(ipaURL: url) }
                } onCancel: {
                    showImporter = false
                }
            }
            .sheet(isPresented: $showWidgetSettings) {
                AdaptiveNavigation {
                    WidgetAppSelectionView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                SwiftUI.Button("完成") { showWidgetSettings = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showCertificate) {
                AdaptiveNavigation {
                    JITLessCertificateView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                SwiftUI.Button("完成") { showCertificate = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showAPK) {
                AdaptiveNavigation {
                    HuskyAPKView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                SwiftUI.Button("完成") { showAPK = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showBootstrap) {
                AdaptiveNavigation {
                    BootstrapCenterView()
                }
            }
            .confirmationDialog("选择要安装的应用类型", isPresented: $showImportMenu, titleVisibility: .visible) {
                SwiftUI.Button("安装 IPA（iOS 应用）") { showImporter = true }
                SwiftUI.Button("安装安卓 APK") { showAPK = true }
                SwiftUI.Button("取消", role: .cancel) {}
            }
            .alert("容器错误", isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            )) {
                SwiftUI.Button("好", role: .cancel) {}
            } message: {
                Text(model.lastError ?? "")
            }
            .onReceive(NotificationCenter.default.publisher(
                for: Notification.Name("TNBGuestDidExitNotification"))) { _ in
                    Task { await model.refresh() }
                }
            .task {
                await model.bootstrap()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("还没有侧载的应用")
                .font(.headline)
            Text("点右上角 ＋ 导入 IPA，即可在本机容器内安装并运行")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            SwiftUI.Button("导入 IPA") { showImporter = true }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var guestList: some View {
        switch model.layoutMode {
        case .list:
            listView
        case .grid:
            gridView
        }
    }

    private var listView: some View {
        List {
            Section {
                ForEach(model.guestApps, id: \.self) { bundle in
                    GuestRow(bundle: bundle) {
                        Task { await model.launch(bundle: bundle) }
                    }
                }
                .onDelete { indexSet in
                    delete(at: indexSet)
                }
            } header: {
                Text("已安装 \(model.guestApps.count) 个应用")
            } footer: {
                Text("点按应用会全屏运行；运行时用悬浮键返回此页面。左滑可卸载。")
            }
        }
        .refreshable { await model.refresh() }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 16)], spacing: 20) {
                ForEach(model.guestApps, id: \.self) { bundle in
                    GuestTile(bundle: bundle) {
                        Task { await model.launch(bundle: bundle) }
                    }
                    .contextMenu {
                        SwiftUI.Button(role: .destructive) {
                            Task { await model.uninstall(bundle: bundle) }
                        } label: {
                            Label("卸载", systemImage: "trash")
                        }
                    }
                }
            }
            .padding()
        }
        .refreshable { await model.refresh() }
    }

    /// 先本地移除让 UI 立即响应，再让引擎从磁盘真删并刷新（防止"删了又出现"）。
    private func delete(at indexSet: IndexSet) {
        let bundles = indexSet.compactMap { model.guestApps.indices.contains($0) ? model.guestApps[$0] : nil }
        withAnimation {
            model.guestApps.remove(atOffsets: indexSet)
        }
        Task {
            for bundle in bundles {
                await model.uninstall(bundle: bundle)
            }
        }
    }
}

private struct GuestRow: View {
    let bundle: String
    let launch: () -> Void
    @State private var icon: UIImage?

    var body: some View {
        SwiftUI.Button(action: launch) {
            HStack(spacing: 12) {
                Group {
                    if let icon { Image(uiImage: icon).resizable() }
                    else { Image(systemName: "app.fill").foregroundStyle(.tint) }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName).font(.body)
                    Text(bundle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .task {
            icon = await IconLoader.icon(for: bundle)
        }
    }

    private var displayName: String {
        AppNameLoader.name(for: bundle)
    }
}

private struct GuestTile: View {
    let bundle: String
    let launch: () -> Void
    @State private var icon: UIImage?

    var body: some View {
        SwiftUI.Button(action: launch) {
            VStack(spacing: 6) {
                Group {
                    if let icon {
                        Image(uiImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "app.fill").resizable().scaledToFit()
                            .foregroundStyle(.tint)
                    }
                }
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 11))

                Text(displayName)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            // iOS27 玻璃拟态：宫格 tile 用超薄材质 + 高光描边（iOS15+ 兼容）。
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.6)
                    )
                    .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
            )
        }
        .buttonStyle(.plain)
        .task {
            icon = await IconLoader.icon(for: bundle)
        }
    }

    private var displayName: String {
        AppNameLoader.name(for: bundle)
    }
}

// MARK: - iOS 15 兼容导航容器
// NavigationStack 是 iOS 16+；TreeNB 主 App 仍以 iOS 15 为部署目标。
private struct AdaptiveNavigation<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                NavigationStack { content }
            } else {
                NavigationView { content }
            }
        }
    }
}

// MARK: - IPA 导入（UIDocumentPicker）

private struct IPAImporter: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PickerHostViewController {
        let host = PickerHostViewController()
        host.coordinator = context.coordinator
        return host
    }

    func updateUIViewController(_ ui: PickerHostViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    /// 不能把 UIDocumentPickerViewController 直接当 sheet 的 root：
    /// 部分 iOS 版本上它不会正确进入文件选择流程，表现为"点+没反应"。
    /// 用一个空 VC 承载，在 viewDidAppear 里正常 present 文件选择器。
    final class PickerHostViewController: UIViewController {
        weak var coordinator: Coordinator?
        private var presented = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presented, let coordinator else { return }
            presented = true
            // IPA 本质是 zip。用 .archive/.data/.item 静态 UTI 兜底，
            // 既能选到 .ipa，也不依赖 UTType(importedAs:) 的 Optional 行为。
            let types: [UTType] = [.archive, .data, .item]
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            picker.delegate = coordinator
            picker.allowsMultipleSelection = false
            present(picker, animated: false)
        }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            controller.dismiss(animated: false) { [weak self] in self?.onPick(url) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            controller.dismiss(animated: false) { [weak self] in self?.onCancel() }
        }
    }
}

// MARK: - 应用目录 / 显示名解析

private enum GuestAppPath {
    /// guest .app 目录的所有候选位置（Documents 主目录 + App Group 兼容目录）
    static func candidates(for bundle: String) -> [URL] {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        return [
            docs?.appendingPathComponent("Applications/\(bundle)"),
            fm.containerURL(forSecurityApplicationGroupIdentifier: "group.openssai.app")?
                .appendingPathComponent("LiveContainer/Applications/\(bundle)")
        ].compactMap { $0 }
    }

    static func info(for bundle: String) -> [String: Any]? {
        for appURL in candidates(for: bundle) {
            if let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist"))
                as? [String: Any] { return info }
        }
        return nil
    }
}

/// 显示名：优先读 Info.plist 的 CFBundleDisplayName / CFBundleName（中文应用名），
/// 找不到才退回 .app 目录名（bundle id）—— 与小组件快照的取名规则一致。
private enum AppNameLoader {
    static func name(for bundle: String) -> String {
        let info = GuestAppPath.info(for: bundle)
        let localized = info?["CFBundleDisplayName"] as? String
        let bundleName = info?["CFBundleName"] as? String
        let fallback = (bundle as NSString).deletingPathExtension
        for candidate in [localized, bundleName] {
            if let name = candidate, !name.isEmpty { return name }
        }
        return fallback
    }
}

// MARK: - 图标加载

private enum IconLoader {
    static func icon(for bundle: String) async -> UIImage? {
        for appURL in GuestAppPath.candidates(for: bundle) {
            let plist = appURL.appendingPathComponent("Info.plist")
            guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else { continue }
            let iconName: String
            if let direct = info["CFBundleIconFile"] as? String {
                iconName = direct
            } else if let icons = info["CFBundleIcons"] as? [String: Any],
                      let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
                if let files = primary["CFBundleIconFiles"] as? [String], let first = files.first {
                    iconName = first
                } else if let file = primary["CFBundleIconFiles"] as? String {
                    iconName = file
                } else {
                    iconName = "AppIcon"
                }
            } else {
                iconName = "AppIcon"
            }
            let iconPath = appURL.appendingPathComponent(iconName).path
            if let img = UIImage(contentsOfFile: iconPath) { return img }
        }
        return nil
    }
}
