//
//  HuskyAPKView.swift
//  TreeNB —— Husk 翻译层 APK 列表 / 启动 UI
//
//  复用树 App 现有风格（系统列表 / 系统色），不引入自定义主题依赖。
//  点击游戏 → 全屏呈现 HuskyGameView（UIKit 包装），三指点击返回。
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
                Section {
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
                }
            } else {
                Section {
                    ForEach(store.apps) { app in
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
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if app.supported { running = app }
                            else { message = "这个 APK 当前无法运行：\(app.detail)" }
                        }
                    }
                    .onDelete { indexSet in
                        for i in indexSet { store.remove(store.apps[i]) }
                    }
                }
            }

            Section {
                Text("翻译层在设备本地运行 APK，不需要安卓系统镜像。游戏画面由 ANGLE 渲染；三指点击返回列表。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("安卓应用")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showPicker = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            APKDocumentPicker { urls in
                let count = urls.filter { $0.pathExtension.lowercased() == "apk" }.count
                if count > 0 {
                    store.reload()
                    message = "已导入 \(count) 个 APK"
                } else {
                    message = "没有选择 APK 文件"
                }
            }
        }
        .fullScreenCover(item: $running) { app in
            HuskyGameScreen(app: app) { running = nil }
        }
        .alert(item: Binding(
            get: { message.map { MessageWrapper(text: $0) } },
            set: { _ in message = nil }
        )) { wrapper in
            Alert(title: Text("提示"), message: Text(wrapper.text), dismissButton: .default(Text("好")))
        }
        .onAppear { store.reload() }
    }

    private struct MessageWrapper: Identifiable { let text: String; var id: String { text } }
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
        view.addSubview(gv)
        NSLayoutConstraint.activate([
            gv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gv.topAnchor.constraint(equalTo: view.topAnchor),
            gv.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        gameView = gv
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
