//
//  TNAccountVaultView.swift
//  TreeNB —— Apple ID 保险库界面
//
//  用户侧目标：
//  · 一个页面看清所有已保存的 Apple ID、团队、证书状态和来源。
//  · 点「切换到此 ID」选团队即可激活，不再要求重新输入密码。
//  · 电脑侧载用过的 id 可以直接导入配置继续用；手机也能再登录新 id。
//  · 两条路并存，随时切回，互不吊销证书。
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - iOS 15 兼容导航容器（NavigationStack 是 iOS 16+）
private struct TNBNavigation<Content: View>: View {
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

struct TNAccountVaultView: View {
    @ObservedObject private var vault = TNBAccountVault.shared
    @State private var pendingAccount: TNBAccountRecord?
    @State private var showSignIn = false
    @State private var showBackupImport = false
    @State private var showP12Import = false
    @State private var pendingP12Account: TNBAccountRecord?
    @State private var importPassword = ""
    @State private var showPasswordPrompt = false
    @State private var message = ""
    @State private var showMessage = false
    @State private var isBusy = false

    var body: some View {
        List {
            Section {
                Text("每个 Apple ID 的账号、团队、证书和登录状态都独立保存在这台设备上。切换只做激活，不需要重新登录；电脑侧载用过的证书可以直接导入继续用，不会被吊销。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("已保存 \(vault.accounts.count) 个 Apple ID")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if vault.accounts.isEmpty {
                Section {
                    Text("还没有保存的 Apple ID。请在下方登录或导入电脑上的账号配置。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(vault.accounts) { account in
                    accountSection(account)
                }
            }

            Section {
                SwiftUI.Button {
                    signInNewAccount()
                } label: {
                    Label("登录新 Apple ID", systemImage: "person.badge.plus")
                }
                SwiftUI.Button {
                    showBackupImport = true
                } label: {
                    Label("导入电脑账号配置", systemImage: "square.and.arrow.down")
                }
                NavigationLink {
                    JITLessCertificateView()
                } label: {
                    Label("无 JIT 证书设置", systemImage: "key.fill")
                }
            } header: {
                Text("添加")
            } footer: {
                Text("账号配置含证书私钥，只保存在本机钥匙串。导出文件请自行保管，不要发给他人。")
                    .font(.footnote)
            }
        }
        .navigationTitle("Apple ID 证书")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pendingAccount) { account in
            TeamPickerView(account: account) { teamID in
                let target = account
                pendingAccount = nil
                Task { await switchAccount(target, teamID: teamID) }
            }
        }
        .sheet(isPresented: $showBackupImport) {
            TNBDataImporter { data in
                showBackupImport = false
                promptPassword(title: "账号配置密码", message: "输入电脑侧导出账号配置时设置的密码。") { pass in
                    Task { await importBackup(data, password: pass) }
                }
            }
        }
        .sheet(isPresented: $showP12Import) {
            TNBDataImporter { data in
                showP12Import = false
                promptPassword(title: "p12 证书密码", message: "从电脑/iLoader 导出的证书化名密码；没有密码请留空直接确认。") { pass in
                    if let account = pendingP12Account {
                        do {
                            try TNBAccountVault.shared.attachCertificate(accountID: account.id,
                                                                         p12: data,
                                                                         password: pass.isEmpty ? nil : pass)
                            message = "证书已绑定到 \(account.email)，切换该账号时会使用这张证书。"
                            showMessage = true
                        } catch {
                            message = "证书绑定失败：\(error.localizedDescription)"
                            showMessage = true
                        }
                    }
                }
            }
        }
        .alert("证书操作", isPresented: $showMessage) {
            SwiftUI.Button("好", role: .cancel) {}
        } message: {
            Text(message)
        }
        .alert(passwordPromptTitle, isPresented: $showPasswordPrompt) {
            SecureField("密码", text: $importPassword)
            SwiftUI.Button("取消", role: .cancel) {}
            SwiftUI.Button("确定") { passwordAction?(importPassword) }
        } message: {
            Text(passwordPromptMessage)
        }
        .overlay {
            if isBusy {
                ProgressView("正在处理…")
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tnbAccountVaultChanged)) { _ in
            vault.reload()
        }
    }

    // MARK: - 账号卡片

    @ViewBuilder
    private func accountSection(_ account: TNBAccountRecord) -> some View {
        let isActive = vault.activeAccount?.id == account.id
        Section {
            HStack(spacing: 10) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? .green : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.email)
                        .font(.subheadline.weight(.semibold))
                    Text(sourceLabel(account.source) + " · " +
                         (account.hasCertificate ? "证书已保存" : "未保存证书") + " · " +
                         (account.hasUsableCredentials ? "登录态已保存" : "需重新登录一次"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { pendingAccount = account }

            ForEach(account.teams) { team in
                HStack {
                    Label(team.name, systemImage: "person.3")
                    Spacer()
                    Text(team.identifier)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if account.activeTeamIdentifier == team.identifier && isActive {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
                .font(.footnote)
                .contentShape(Rectangle())
                .onTapGesture {
                    pendingAccount = account
                }
            }

            SwiftUI.Button {
                pendingAccount = account
            } label: {
                Label(isActive ? "切换团队 / 管理" : "切换到此 ID（选团队）",
                      systemImage: isActive ? "gearshape" : "arrow.right.circle")
            }

            SwiftUI.Button {
                exportAccount(account)
            } label: {
                Label("导出账号配置（带回电脑）", systemImage: "square.and.arrow.up")
            }

            SwiftUI.Button {
                pendingP12Account = account
                showP12Import = true
            } label: {
                Label("为此 ID 导入 p12 证书", systemImage: "key.viewfinder")
            }
        } header: {
            HStack {
                Text(account.email)
                if isActive { Text("· 使用中").foregroundStyle(.green) }
            }
        }
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "computer": return "来自电脑"
        case "p12": return "手动导入证书"
        default: return "手机登录"
        }
    }

    // MARK: - 操作

    private func switchAccount(_ account: TNBAccountRecord, teamID: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await TNBAccountVault.shared.activate(accountID: account.id, teamIdentifier: teamID)
            message = "已切换到 \(account.email)（团队 \(teamID)），无需重新登录。"
            showMessage = true
        } catch {
            message = "切换失败：\(error.localizedDescription)"
            showMessage = true
        }
    }

    private func signInNewAccount() {
        guard let presenter = TNBTopViewController.current() else {
            message = "找不到当前界面，无法弹出登录。"
            showMessage = true
            return
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await AuthManager.shared.signIn(presentingViewController: presenter)
                TNBAccountVault.shared.captureCurrentAsNewAccount()
                refreshTeamsFromDatabase()
                message = "新 Apple ID 已登录并保存到保险库。"
                showMessage = true
            } catch {
                message = "登录未完成：\(error.localizedDescription)"
                showMessage = true
            }
        }
    }

    private func refreshTeamsFromDatabase() {
        let email = Keychain.shared.appleIDEmailAddress ?? ""
        let teams = ((try? DatabaseManager.shared.viewContext.fetch(Team.fetchRequest())) ?? []).filter {
            $0.account?.appleID.caseInsensitiveCompare(email) == .orderedSame
        }
        let records = teams.map {
            TNBTeamRecord(identifier: $0.identifier, name: $0.name, type: $0.type.localizedDescription)
        }
        TNBAccountVault.shared.updateTeams(email: email, teams: records)
    }

    private func importBackup(_ data: Data, password: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let record = try await TNBAccountVault.shared.importAccountBackup(data, filePassword: password)
            message = "已导入 \(record.email)。点该账号即可切换使用，电脑那边的证书不受影响。"
            showMessage = true
        } catch {
            message = "导入失败：\(error.localizedDescription)"
            showMessage = true
        }
    }

    private func exportAccount(_ account: TNBAccountRecord) {
        promptPassword(title: "导出密码", message: "设置一个密码保护导出的账号配置（不要与 Apple ID 密码相同）。") { pass in
            do {
                let data = try TNBAccountVault.shared.exportAccountBackup(accountID: account.id,
                                                                          filePassword: pass)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("TreeNB-\(account.email).tnbaccount")
                try data.write(to: url)
                TNBTopViewController.current()?.present(UIActivityViewController(
                    activityItems: [url], applicationActivities: nil), animated: true)
            } catch {
                message = "导出失败：\(error.localizedDescription)"
                showMessage = true
            }
        }
    }

    @State private var passwordPromptTitle = ""
    @State private var passwordPromptMessage = ""
    @State private var passwordAction: ((String) -> Void)?

    private func promptPassword(title: String, message: String, action: @escaping (String) -> Void) {
        passwordPromptTitle = title
        passwordPromptMessage = message
        passwordAction = action
        importPassword = ""
        showPasswordPrompt = true
    }
}

// MARK: - 团队选择

private struct TeamPickerView: View {
    let account: TNBAccountRecord
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String
    @State private var manualTeamID = ""

    private var resolvedTeamID: String {
        selected.isEmpty ? manualTeamID.trimmingCharacters(in: .whitespaces).uppercased() : selected
    }

    private var canSwitch: Bool {
        TNBAccountVault.isValidTeamIdentifier(resolvedTeamID)
    }

    init(account: TNBAccountRecord, onPick: @escaping (String) -> Void) {
        self.account = account
        self.onPick = onPick
        _selected = State(initialValue: account.activeTeam?.identifier ?? account.teams.first?.identifier ?? "")
    }

    var body: some View {
        TNBNavigation {
            List {
                Section {
                    Text("为 \(account.email) 选择要启用的团队。切换后签名和续签都会使用这个团队，已保存的其它 Apple ID 不受影响。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    if account.teams.isEmpty {
                        Text("这个 ID 还没有发现团队。可以从证书自动识别，也可以直接填写团队 ID（10 位，例如 68LPZ6ZK87）。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        TextField("10 位团队 ID", text: $manualTeamID)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        if !manualTeamID.isEmpty && !canSwitch {
                            Text("请输入 10 位大写字母或数字。")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    ForEach(account.teams) { team in
                        HStack {
                            Image(systemName: selected == team.identifier ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected == team.identifier ? .green : .secondary)
                            VStack(alignment: .leading) {
                                Text(team.name)
                                Text("\(team.identifier) · \(team.type)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selected = team.identifier }
                    }
                }
            }
            .navigationTitle("选择团队")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SwiftUI.Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SwiftUI.Button("切换") {
                        dismiss()
                        onPick(resolvedTeamID)
                    }
                    .disabled(!canSwitch)
                }
            }
        }
    }
}

// MARK: - 文件选择

private struct TNBDataImporter: UIViewControllerRepresentable {
    let onPick: (Data) -> Void

    func makeUIViewController(context: Context) -> TNBImportHost {
        let host = TNBImportHost()
        host.coordinator = context.coordinator
        return host
    }
    func updateUIViewController(_ ui: TNBImportHost, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class TNBImportHost: UIViewController {
        weak var coordinator: Coordinator?
        private var presented = false
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presented, let coordinator else { return }
            presented = true
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .item, .archive],
                                                        asCopy: true)
            picker.delegate = coordinator
            picker.allowsMultipleSelection = false
            present(picker, animated: false)
        }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (Data) -> Void
        init(onPick: @escaping (Data) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            let data = try? Data(contentsOf: url)
            if accessed { url.stopAccessingSecurityScopedResource() }
            controller.dismiss(animated: false) { [weak self] in
                if let data { self?.onPick(data) }
            }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            controller.dismiss(animated: false)
        }
    }
}

// MARK: - 取当前界面控制器（登录/分享需要）

private enum TNBTopViewController {
    static func current() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let scene = scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
            ?? scenes.first as? UIWindowScene
        guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
        var vc = root
        while let presented = vc.presentedViewController { vc = presented }
        return vc
    }
}
