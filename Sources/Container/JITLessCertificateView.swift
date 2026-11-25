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
                             ? "容器应用会用此证书重签、跳过 JIT 检测直接启动。"
                             : "未配置证书，容器应用需要 JIT 才能启动。可点下方「重置为当前账号证书」一键恢复。")
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
                    resetToCurrentAccountCertificate()
                } label: {
                    Label("重置为当前账号证书", systemImage: "arrow.triangle.2.circlepath")
                }
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
                Text("证书只保存在本机 App Group 存储，用于 JIT-less 重签；含私钥，请勿公开分享。")
                    .font(.footnote)
            }

            Section {
                Text("1. 推荐点「重置为当前账号证书」：直接读取你在「我的」里登录的 Apple ID 签名证书（与侧载本 App 用的是同一张，team 天然匹配），导入后自动重签所有应用，一步到位。\n2. 若提示没有账号证书，请先登录 Apple ID 并用它侧载过 App，再回来重置。\n3. 也可手动导入 .p12（无密码留空）→ 点「重签所有应用」。")
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

    /// 一键「重置/复原」：清空旧证书，改用当前 openSSS 登录账号的签名证书。
    /// 这张 p12 就是侧载本 App 用的那张，team 与宿主天然一致，
    /// 避免手动导文件时 team 对不上导致的 code signature invalid。
    private func resetToCurrentAccountCertificate() {
        // CertificateManager 与主 App 同 target（TreeNB module），无需 import。
        guard let active = CertificateManager.shared.activeCertificate else {
            message = "当前没有账号证书。请先在「我的」页登录 Apple ID，并用它成功侧载过 App，再回来重置。"
            showMessage = true
            return
        }
        let p12 = active.p12Data
        let pass = active.password ?? ""
        guard !p12.isEmpty else {
            message = "账号证书数据为空，无法重置。请重新登录 Apple ID 后再试。"
            showMessage = true
            return
        }
        // 先清旧证书再导入新的，确保 JITLess 用的是当前账号这张。
        LCEngineEntry.removeJITLessCertificate()
        LCEngineEntry.importJITLessCertificate(p12, password: pass)
        hasCert = LCEngineEntry.hasJITLessCertificate()
        guard hasCert else {
            message = "证书重置失败，请重试或手动导入 p12。"
            showMessage = true
            return
        }
        // 重置后自动重签所有已装 guest，省去用户再点一次，
        // 并把「已重置」与重签结果合成一条弹窗，避免连弹两次。
        isResigning = true
        LCEngineEntry.resignAllGuests { success, detail in
            isResigning = false
            message = "已重置为当前账号证书。重签结果：\(detail)"
            showMessage = true
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
