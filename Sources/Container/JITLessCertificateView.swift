//
//  JITLessCertificateView.swift
//  TreeNB —— JIT-less 签名证书管理
//
//  无 JIT 侧载环境（SideStore / iloder 等）下让容器 guest 能启动的关键：
//  导入你侧载用的开发者 p12 证书 + 密码，guest 会用该证书 ZSign 重签，
//  启动链路检测到证书密码即跳过 JIT 检测。证书写入 App Group 共享存储，
//  与上游 LCUtils/LCSharedUtils 的读取位置完全一致。
//

import SwiftUI
import UniformTypeIdentifiers
import LiveContainerShared

struct JITLessCertificateView: View {
    @State private var hasCert = LCEngineEntry.hasJITLessCertificate()
    @State private var showImporter = false
    @State private var password = ""
    @State private var showPasswordAlert = false
    @State private var pendingP12: Data?
    @State private var message = ""
    @State private var showMessage = false
    @State private var isResigning = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: hasCert ? "key.fill" : "key")
                        .font(.title2)
                        .foregroundStyle(hasCert ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hasCert ? "已配置 JIT-less 证书" : "未配置证书")
                            .font(.headline)
                        Text(hasCert
                             ? "容器应用启动时会跳过 JIT 检测，用此证书重签后运行。"
                             : "无 JIT 环境需要导入你侧载用的 p12 证书才能启动应用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("签名状态")
            }

            Section {
                SwiftUI.Button {
                    showImporter = true
                } label: {
                    Label("导入 p12 证书", systemImage: "square.and.arrow.down")
                }
                if hasCert {
                    SwiftUI.Button(role: .destructive) {
                        LCEngineEntry.removeJITLessCertificate()
                        hasCert = false
                        message = "已移除证书，恢复为需要 JIT 的模式。"
                        showMessage = true
                    } label: {
                        Label("移除证书", systemImage: "trash")
                    }
                    SwiftUI.Button {
                        resignAll()
                    } label: {
                        Label(isResigning ? "正在重签…" : "用当前证书重签所有应用",
                              systemImage: "signature")
                    }
                    .disabled(isResigning)
                }
            } header: {
                Text("证书操作")
            } footer: {
                Text("使用与侧载 TreeNB 相同的开发者证书（.p12 + 密码）。证书仅保存在本机 App 共享存储，不会上传。")
                    .font(.footnote)
            }

            Section {
                Text("1. 用你侧载时导出的 .p12 证书和密码导入。\n2. 导入后点「重签所有应用」让已安装的应用也能无 JIT 启动。\n3. 之后新导入的 IPA 会自动用该证书签名。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("说明")
            }
        }
        .navigationTitle("无 JIT 证书")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showImporter) {
            P12Importer { data in
                showImporter = false
                pendingP12 = data
                showPasswordAlert = true
            } onCancel: {
                showImporter = false
            }
        }
        .alert("输入 p12 密码", isPresented: $showPasswordAlert) {
            SwiftUI.SecureField("证书密码", text: $password)
            SwiftUI.Button("取消", role: .cancel) { password = "" }
            SwiftUI.Button("导入") { commitImport() }
        } message: {
            Text("输入该 .p12 证书导出时设置的密码。若证书没有密码（如从侧载工具直接导出的），直接留空点导入即可。")
        }
        .alert("证书操作", isPresented: $showMessage) {
            SwiftUI.Button("好", role: .cancel) {}
        } message: {
            Text(message)
        }
    }

    private func commitImport() {
        guard let data = pendingP12 else { return }
        LCEngineEntry.importJITLessCertificate(data, password: password)
        pendingP12 = nil
        password = ""
        hasCert = LCEngineEntry.hasJITLessCertificate()
        message = hasCert
            ? "证书已导入。请点「重签所有应用」，让已安装的应用也能无 JIT 启动。"
            : "证书导入失败，请确认数据与密码正确。"
        showMessage = true
    }

    private func resignAll() {
        isResigning = true
        LCEngineEntry.resignAllGuests { success, detail in
            isResigning = false
            message = detail
            showMessage = true
        }
    }
}

// MARK: - p12 文件选择器（UIDocumentPicker 承载 VC，避免 sheet root 不弹的坑）
private struct P12Importer: UIViewControllerRepresentable {
    let onPick: (Data) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> P12HostViewController {
        let host = P12HostViewController()
        host.coordinator = context.coordinator
        return host
    }
    func updateUIViewController(_ ui: P12HostViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class P12HostViewController: UIViewController {
        weak var coordinator: Coordinator?
        private var presented = false
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presented, let coordinator else { return }
            presented = true
            // p12 归到 public.data；用 .data/.item 兜底，能选到 .p12 文件。
            let types: [UTType] = [.data, .item, .archive]
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            picker.delegate = coordinator
            picker.allowsMultipleSelection = false
            present(picker, animated: false)
        }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (Data) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            let data = try? Data(contentsOf: url)
            if accessed { url.stopAccessingSecurityScopedResource() }
            controller.dismiss(animated: false) { [weak self] in
                if let data { self?.onPick(data) } else { self?.onCancel() }
            }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            controller.dismiss(animated: false) { [weak self] in self?.onCancel() }
        }
    }
}
