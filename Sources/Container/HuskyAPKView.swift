//
//  HuskyAPKView.swift
//  TreeNB —— Husk 翻译层 APK 列表 / 启动 UI
//
//  复用树 App 现有风格（系统列表 / 系统色），不引入自定义主题依赖。
//  点击游戏 → 全屏呈现 HuskyGameView（UIKit 包装），三指点击返回。
//
//  iOS 27 玻璃拟态：CI 锁 Xcode 16.4（无 iOS 26 SDK），无法用原生
//  .glassEffect()；用 iOS 15+ 的 ultraThinMaterial + 高光描边 + 柔和
//  阴影模拟 Liquid Glass。材质只作用于卡片/控件层，符合 HIG（不进内容层）。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct HuskyAPKView: View {
    @ObservedObject private var store = HuskyAPKStore.shared
    @State private var showPicker = false
    @State private var running: HuskyApp?
    @State private var message: String?

    var body: some View {
        List {
            if store.apps.isEmpty {
                EmptyAppsSection()
                    .glassCard()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                appsSection
            }
            infoSection
        }
        .listStyle(.plain)
        .scrollContentBackgroundCompat()
        .background(
            LinearGradient(
                colors: [
                    Color(uiColor: .systemGroupedBackground),
                    Color(uiColor: .secondarySystemGroupedBackground)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .navigationTitle("安卓应用")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                SwiftUI.Button { showPicker = true } label: {
                    Image(systemName: "plus")
                        .glassToolbarIcon()
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            APKDocumentPicker { handlePicked($0) }
        }
        .fullScreenCover(item: $running) { app in
            HuskyGameScreen(app: app) { running = nil }
        }
        .alert(item: alertBinding) { wrapper in
            Alert(title: Text("提示"), message: Text(wrapper.text), dismissButton: .default(Text("好")))
        }
        .onAppear { store.reload() }
    }

    // MARK: - 拆分子表达式（避免 body 类型检查超时）

    private var appsSection: some View {
        ForEach(store.apps) { app in
            AppRow(app: app) {
                if app.supported {
                    running = app
                } else {
                    message = "这个 APK 当前无法运行：\(app.detail)"
                }
            }
            .glassCard()
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                SwiftUI.Button(role: .destructive) {
                    store.remove(app)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    private var infoSection: some View {
        Text("翻译层在设备本地运行 APK，不需要安卓系统镜像。游戏画面由 ANGLE 渲染；三指点击返回列表。")
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(radius: 14)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    private var alertBinding: Binding<MessageWrapper?> {
        Binding(
            get: { message.map { MessageWrapper(text: $0) } },
            set: { _ in message = nil }
        )
    }

    private func handlePicked(_ urls: [URL]) {
        let apks = urls.filter { $0.pathExtension.lowercased() == "apk" }
        guard !apks.isEmpty else {
            message = "没有选择 APK 文件"
            return
        }
        // importAPKs 内部会把文件复制进 App 文档目录并 reload()。
        guard let id = store.importAPKs(from: urls),
              let app = store.apps.first(where: { $0.id == id }) else {
            message = "APK 导入失败，请检查文件是否可读取"
            return
        }
        message = app.supported
            ? "已导入「\(app.label)」，点击即可运行"
            : "已导入「\(app.label)」，但无法运行：\(app.detail)"
    }

    private struct MessageWrapper: Identifiable { let text: String; var id: String { text } }

    private struct EmptyAppsSection: View {
        var body: some View {
            VStack(spacing: 10) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.secondary)
                Text("还没有安卓应用")
                    .font(.headline)
                Text("点右上角 + 导入 APK。支持 Unity / Godot / cocos 等引擎游戏。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .padding(.horizontal, 12)
        }
    }

    private struct AppRow: View {
        let app: HuskyApp
        let tap: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: app.supported ? "gamecontroller.fill" : "questionmark.circle")
                    .font(.title3)
                    .foregroundColor(app.supported ? .accentColor : .secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.label).font(.body).lineLimit(1)
                    Text("\(app.engine) · \(app.detail)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if app.supported {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture(perform: tap)
        }
    }
}

// MARK: - iOS 27 玻璃拟态（材质模拟）

/// 用 iOS 15+ 材质模拟 Liquid Glass：超薄材质填充 + 对角高光描边 + 柔和阴影。
/// CI 无 iOS 26 SDK，故不直接用 .glassEffect()；iOS 27 上系统仍会给
/// 导航栏/alert 等原生控件套上真正的 Liquid Glass，这里补自定义卡片层。
private struct GlassCard: ViewModifier {
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.5), Color.white.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                }
                .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
            )
    }
}

private extension View {
    func glassCard(radius: CGFloat = 16) -> some View {
        modifier(GlassCard(radius: radius))
    }

    /// 工具栏加号图标的玻璃底：圆形超薄材质 + 高光边。
    func glassToolbarIcon() -> some View {
        self
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.accentColor)
            .frame(width: 32, height: 32)
            .background(Circle().fill(.ultraThinMaterial))
            .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 0.6))
    }

    /// .scrollContentBackground(.hidden) 是 iOS 16+，按系统版本安全应用。
    @ViewBuilder
    func scrollContentBackgroundCompat() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

/// 全屏游戏容器：UIKit 包装 HuskyGameView，三指点击关闭。
private struct HuskyGameScreen: UIViewControllerRepresentable {
    let app: HuskyApp
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> HuskyGameHostVC {
        let vc = HuskyGameHostVC()
        vc.app = app
        vc.onClose = onClose
        return vc
    }

    func updateUIViewController(_ uiViewController: HuskyGameHostVC, context: Context) {}
}

private final class HuskyGameHostVC: UIViewController {
    var app: HuskyApp?
    var onClose: (() -> Void)?
    private var gameView: HuskyGameView?
    private let statusLabel: UILabel = {
        let l = UILabel()
        l.textColor = .white
        l.font = .systemFont(ofSize: 14, weight: .medium)
        l.numberOfLines = 0
        l.textAlignment = .center
        l.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        l.layer.cornerRadius = 10
        l.layer.masksToBounds = true
        l.isHidden = true
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let app else { return }

        let store = HuskyAPKStore.shared
        let gv = HuskyGameView(apk: app.mainAPK, engine: app.engine,
                               dataDir: store.dataDir(for: app),
                               extraApks: Array(app.apks.dropFirst()))
        gv.translatesAutoresizingMaskIntoConstraints = false
        gv.onExitRequested = { [weak self] in self?.onClose?() }
        gv.onStatus = { [weak self] text in self?.showStatus(text) }
        gv.onReady = { [weak self] in self?.hideStatusSoon() }
        view.addSubview(gv)
        NSLayoutConstraint.activate([
            gv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gv.topAnchor.constraint(equalTo: view.topAnchor),
            gv.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        gameView = gv

        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32)
        ])
    }

    private func showStatus(_ text: String) {
        statusLabel.text = "  \(text)  "
        statusLabel.isHidden = false
        UIView.animate(withDuration: 0.15) { self.statusLabel.layoutIfNeeded() }
    }

    private func hideStatusSoon() {
        // 成功启动后短暂显示，再淡出；失败提示（无 onReady）则一直留着。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            UIView.animate(withDuration: 0.3, animations: { self?.statusLabel.alpha = 0 }) { _ in
                self?.statusLabel.isHidden = true
                self?.statusLabel.alpha = 1
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        gameView?.resume()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        gameView?.pause()
    }
}

/// APK 文件选择器（UIDocumentPicker），选择后回调 URL。
private struct APKDocumentPicker: UIViewControllerRepresentable {
    let completion: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [UTType(exportedAs: "org.android.package-archive")]
            .compactMap { $0 }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: ([URL]) -> Void
        init(completion: @escaping ([URL]) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(urls)
        }
    }
}
