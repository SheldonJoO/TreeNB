//
//  BootstrapCenterView.swift
//  TreeNB —— 傻瓜式一键自举中心
//
//  目标：用户装好 TreeNB 后，不用懂 JIT / 证书 / 配对文件这些概念，
//  一个按钮把"能不能正常运行侧载应用"的全部前置条件检测并配好。
//
//  全部复用现有能力，零外部 App 依赖：
//   - 证书：CertificateManager（当前账号 p12）→ LCEngineEntry 的 JIT-less 重签
//   - 配对文件：PairingFileManager
//   - 开发者模式：LocationSimulationService 的 prerequisites（idevice 后端）
//
//  这是 siboot 思路在"已装好 App"这一层的落地：把散落在多个设置页的
//  操作收敛成一个向导，逐步显示状态、一键修复，失败给出人话提示。
//

import SwiftUI
import UniformTypeIdentifiers
import LiveContainerShared

struct BootstrapCenterView: View {
    // 环境状态
    @State private var hasCert = LCEngineEntry.hasJITLessCertificate()
    @State private var hasPairing = PairingFileManager.shared.hasPairingFile()
    @State private var hasAccount = (CertificateManager.shared.activeCertificate
        ?? (try? CertificateManager.shared.loadActiveCertificate())) != nil

    // 流程状态
    @State private var isWorking = false
    @State private var stepText = ""
    @State private var showResult = false
    @State private var resultText = ""
    @State private var showPairingImporter = false
    @State private var showSystemIPAImporter = false
    // 系统安装引擎进度（区别于 guest 容器安装）
    @State private var installEvent = "准备安装…"
    @Environment(\.dismiss) private var dismiss

    private var readyCount: Int {
        [hasCert, hasPairing, hasAccount].filter { $0 }.count
    }
    private var allReady: Bool { readyCount == 3 }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: allReady ? "checkmark.circle.fill" : "gearshape.2.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(allReady ? .green : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(allReady ? "环境已就绪" : "还差 \(3 - readyCount) 步就绪")
                            .font(.headline)
                        Text(allReady
                             ? "应用可以直接启动，无需 JIT、无需电脑。"
                             : "点下面「一键配置」，我会自动把能修的都修好。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                ProgressView(value: Float(readyCount), total: 3)
                    .tint(allReady ? .green : .orange)
            }

            Section {
                StatusRow(ok: hasAccount, title: "Apple ID 账号证书",
                          hint: hasAccount ? "已登录，可作为签名证书" : "需在「我的」页登录 Apple ID")
                StatusRow(ok: hasCert, title: "JIT-less 签名证书",
                          hint: hasCert ? "应用可用证书重签启动" : "未配置，一键配置会自动导入")
                StatusRow(ok: hasPairing, title: "设备配对文件",
                          hint: hasPairing ? "已就绪" : "用于设备通信；可从 SideStore 导入")
            } header: {
                Text("环境检测")
            }

            Section {
                SwiftUI.Button {
                    runAll()
                } label: {
                    HStack {
                        Image(systemName: "wand.and.stars")
                        Text(isWorking ? stepText : "一键配置（推荐）")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)

                SwiftUI.Button {
                    showPairingImporter = true
                } label: {
                    Label("导入配对文件", systemImage: "square.and.arrow.down")
                }

                if hasCert {
                    SwiftUI.Button {
                        isWorking = true
                        stepText = "正在重签所有应用…"
                        LCEngineEntry.resignAllGuests { _, detail in
                            isWorking = false
                            resultText = detail
                            showResult = true
                        }
                    } label: {
                        Label("重新签名所有应用", systemImage: "signature")
                    }
                    .disabled(isWorking)
                }
            } header: {
                Text("操作")
            } footer: {
                Text("「一键配置」会读取你当前 Apple ID 的签名证书（与侧载本 App 用的是同一张），导入后自动重签所有已装应用。全程在本机完成，不需要电脑或 JIT。")
                    .font(.footnote)
            }

            Section {
                SwiftUI.Button {
                    showSystemIPAImporter = true
                } label: {
                    Label("签名安装 IPA 到系统", systemImage: "app.badge.checkmark")
                }
                .disabled(isWorking)
                if isWorking && installEvent.contains("安装") {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(installEvent).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("设备端签名安装")
            } footer: {
                Text("选一个 IPA，用你的 Apple ID 在设备上签名后直接装进系统（不是容器 guest）。需要上面三项环境就绪。签名 + 安装可能需要 1-2 分钟，期间请勿锁屏。")
                    .font(.footnote)
            }
        }
        .navigationTitle("一键自举中心")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                SwiftUI.Button("完成") { dismiss() }
            }
        }
        .sheet(isPresented: $showPairingImporter) {
            PairingImporter { data in
                showPairingImporter = false
                importPairing(data)
            } onCancel: {
                showPairingImporter = false
            }
        }
        .sheet(isPresented: $showSystemIPAImporter) {
            SystemIPAImporter { url in
                showSystemIPAImporter = false
                Task { await installSystemIPA(url) }
            } onCancel: {
                showSystemIPAImporter = false
            }
        }
        .alert("配置结果", isPresented: $showResult) {
            SwiftUI.Button("好", role: .cancel) {}
        } message: {
            Text(resultText)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: TNBDeepLinkRouter.bootstrapDidImport)) { payload in
            // 从 SideStore/网页深链递来的配对文件：刷新状态并提示结果。
            if payload.object is String { return } // "open" 只是打开信号
            hasPairing = PairingFileManager.shared.hasPairingFile()
            resultText = UserDefaults.standard.string(forKey: "TNBootstrapLastResult")
                ?? "配对文件状态已更新。"
            showResult = true
        }
    }

    /// 把所有能自动化的步骤串成一条龙。
    private func runAll() {
        isWorking = true

        // 1) 证书：当前账号 p12 → JIT-less 证书
        stepText = "正在读取账号证书…"
        let cm = CertificateManager.shared
        let active = cm.activeCertificate ?? (try? cm.loadActiveCertificate())
        guard let active, !active.p12Data.isEmpty else {
            isWorking = false
            resultText = "没有找到账号证书。请先到「我的」页登录 Apple ID，并用它侧载过 App，再回来点一键配置。"
            showResult = true
            return
        }

        stepText = "正在导入签名证书…"
        LCEngineEntry.removeJITLessCertificate()
        LCEngineEntry.importJITLessCertificate(active.p12Data, password: active.password ?? "")
        hasCert = LCEngineEntry.hasJITLessCertificate()
        hasAccount = true

        guard hasCert else {
            isWorking = false
            resultText = "证书导入失败，请重试或到「证书设置」手动导入 p12。"
            showResult = true
            return
        }

        // 2) 重签所有已装应用（让已有的 guest 也能免 JIT 启动）
        stepText = "正在重签所有应用…"
        LCEngineEntry.resignAllGuests { _, detail in
            isWorking = false
            hasPairing = PairingFileManager.shared.hasPairingFile()
            if hasPairing {
                resultText = "配置完成 ✅\n\(detail)\n设备配对文件也已就绪，环境全部就绪。"
            } else {
                resultText = "配置完成 ✅\n\(detail)\n\n还差一步：点「导入配对文件」，从 SideStore 导出后导入即可（一次性操作）。"
            }
            showResult = true
        }
    }

    /// 设备端签名安装：把选中的 IPA 交给 TNBInstallEngine，走 openSSS 的
    /// 签名+上传+安装 pipeline。进度通过 onEvent 回传，全程在主线程更新 UI。
    private func installSystemIPA(_ url: URL) async {
        isWorking = true
        installEvent = "准备安装…"
        let result = await TNBInstallEngine.shared.install(ipaURL: url) { event in
            Task { @MainActor in
                self.installEvent = event.message
            }
        }
        isWorking = false
        switch result {
        case .success(let name):
            resultText = "系统安装成功 ✅\n\(name)\n已装到系统桌面（不是容器 guest）。"
        case .failure(let err):
            resultText = err.localizedDescription
        }
        showResult = true
    }

    private func importPairing(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            resultText = "配对文件读取失败，请确认选的是 .mobiledevicepairing 文件。"
            showResult = true
            return
        }
        do {
            // 与上游 importPairingFile(from:) 行为一致：保存后设当前激活协议，
            // 否则文件存了但 minimuxer 不会用它。
            let parsed = try PairingFileManager.shared.savePairingFile(contents: text)
            PairingFileManager.shared.persistedActiveProtocol = parsed.mode
            hasPairing = PairingFileManager.shared.hasPairingFile()
            resultText = hasPairing ? "配对文件已导入 ✅" : "配对文件导入后未生效，请重试。"
            showResult = true
        } catch {
            resultText = "配对文件导入失败：\(error.localizedDescription)"
            showResult = true
        }
    }
}

// MARK: - 状态行
private struct StatusRow: View {
    let ok: Bool
    let title: String
    let hint: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 系统安装 IPA 选择器（返回 URL，供引擎读取文件路径）
private struct SystemIPAImporter: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> IPAHostVC {
        let vc = IPAHostVC()
        vc.coordinator = context.coordinator
        return vc
    }
    func updateUIViewController(_ ui: IPAHostVC, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class IPAHostVC: UIViewController {
        weak var coordinator: Coordinator?
        private var presented = false
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presented, let coordinator else { return }
            presented = true
            let picker = UIDocumentPickerViewController(
                forOpeningContentTypes: [UTType(filenameExtension: "ipa") ?? .data],
                asCopy: true
            )
            picker.delegate = coordinator
            picker.allowsMultipleSelection = false
            present(picker, animated: false)
        }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("tnb-system-install-\(UUID().uuidString).ipa")
            // FileManager.copyItem 的签名是 (at:to:)，不是 (to:from:)。
            // 上一版参数写反导致 CI 首次编译时报 "extra argument 'from'" / "missing 'at'"。
            let copied = try? FileManager.default.copyItem(at: url, to: dest)
            if accessed { url.stopAccessingSecurityScopedResource() }
            controller.dismiss(animated: false) { [weak self] in
                if let copied { self?.onPick(copied) } else { self?.onCancel() }
            }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            controller.dismiss(animated: false) { [weak self] in self?.onCancel() }
        }
    }
}

// MARK: - 配对文件选择器
private struct PairingImporter: UIViewControllerRepresentable {
    let onPick: (Data) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PairingHostVC {
        let vc = PairingHostVC()
        vc.coordinator = context.coordinator
        return vc
    }
    func updateUIViewController(_ ui: PairingHostVC, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class PairingHostVC: UIViewController {
        weak var coordinator: Coordinator?
        private var presented = false
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presented, let coordinator else { return }
            presented = true
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .item, .xml], asCopy: true)
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
