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
    @State private var showError = false
    @State private var errorMessage = ""

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
            .navigationTitle("容器")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
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
                        showImporter = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("导入 IPA")
                }
            }
            .sheet(isPresented: $showImporter) {
                IPAImporter { url in
                    Task { await model.install(ipaURL: url) }
                }
            }
            .alert("容器错误", isPresented: $showError) {
                SwiftUI.Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage)
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

    private var guestList: some View {
        List {
            Section {
                ForEach(model.guestApps, id: \.self) { bundle in
                    GuestRow(bundle: bundle) {
                        Task { await model.launch(bundle: bundle) }
                    }
                }
                .onDelete { indexSet in
                    // Stage 2: 删除容器 + 目录清理
                }
            } header: {
                Text("已安装 \(model.guestApps.count) 个应用")
            } footer: {
                Text("点按应用会全屏运行；运行时用悬浮键返回此页面。")
            }
        }
        .refreshable { await model.refresh() }
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
        (bundle as NSString).deletingPathExtension
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

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // 用 importedAs 查我们在 Info.plist 的 UTImportedTypeDeclarations 中声明的
        // com.apple.itunes.ipa；exportedAs 只查 UTExportedTypeDeclarations，查不到。
        // 追加 archive / data 兜底，保证即使某个 UTI 未注册也能选到 .ipa 文件。
        var types: [UTType] = []
        if let ipa = UTType(importedAs: "com.apple.itunes.ipa") { types.append(ipa) }
        if let ipa2 = UTType(filenameExtension: "ipa") { types.append(ipa2) }
        types.append(.archive)
        types.append(.data)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    func updateUIViewController(_ ui: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

// MARK: - 图标加载

private enum IconLoader {
    static func icon(for bundle: String) async -> UIImage? {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        let candidates = [
            docs?.appendingPathComponent("Applications/\(bundle)"),
            fm.containerURL(forSecurityApplicationGroupIdentifier: "group.openssai.app")?
                .appendingPathComponent("LiveContainer/Applications/\(bundle)")
        ].compactMap { $0 }
        for appURL in candidates {
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
