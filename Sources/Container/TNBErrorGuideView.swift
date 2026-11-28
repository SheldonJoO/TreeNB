import SwiftUI
import LiveContainerShared
import MessageUI
import UIKit

private struct TNBErrorGuideEntry: Identifiable {
    let id: String
    let title: String
    let signature: String
    let keywords: String
    let causes: [String]
    let steps: [String]
    let note: String
}

private enum TNBErrorGuideContent {
    static let entries: [TNBErrorGuideEntry] = [
        TNBErrorGuideEntry(
            id: "operation-8-active-certificate",
            title: "侧载失败：激活证书缺失",
            signature: "TreeNB.OperationError · code 8\nInvalid parameters: Active certificate is missing.",
            keywords: "operationerror 8 active certificate missing 参数无效 激活证书缺失 侧载",
            causes: [
                "当前 Apple ID / 团队没有对应的证书私钥，只有开发者门户里的证书信息不能用于本机签名。",
                "切换账号时目标团队没有已归档证书。新版会在改动当前证书前阻止这种切换，不会再把原证书清空。"
            ],
            steps: [
                "打开 树应用 → ⋯ → Apple ID 证书。",
                "选择出错的 Apple ID，点“为此 ID 导入 p12 证书”。",
                "导入包含目标团队私钥的 p12；有密码就输入原密码，无密码则留空。",
                "确认团队旁显示“证书已归档”，再切换该团队并重新侧载。"
            ],
            note: "导入已有证书不会吊销电脑侧使用的证书。切换账号本身不需要重新输入 Apple ID 密码。"
        ),
        TNBErrorGuideEntry(
            id: "appid-limit-9120",
            title: "Apple 免费账号 App ID 限额",
            signature: "Your maximum App ID limit has been reached.\nYou may create up to 10 App IDs every 7 days. (code: 9120)",
            keywords: "9120 app id limit maximum 免费账号 限额 appid",
            causes: ["Apple 对免费开发者账号限制每 7 天最多创建 10 个 App ID。这是门户限制，不是证书丢失。"],
            steps: [
                "等待限额重置后再试。",
                "如果该 App ID 确定不再使用，可在 Apple 开发者门户中删除后再创建。",
                "也可以导入另一个 Apple ID 的团队证书；不要尝试用重复 bundle id 绕过限额。"
            ],
            note: "9120 与 OperationError 8 是两个独立问题；解决限额后仍需确认设备上有对应团队私钥。"
        ),
        TNBErrorGuideEntry(
            id: "guest-code-signature",
            title: "树 APP 启动失败：代码签名无效",
            signature: "dlopen(...): code signature invalid\nsliceOffset / codeBlobOffset / codeBlobSize",
            keywords: "dlopen code signature invalid dyld 代码签名 无效 树app guest 闪退",
            causes: [
                "guest 的修补或签名没有完成，或签名使用的证书与当前运行环境不匹配。",
                "导入 guest 后更换了 JIT-less 证书，旧 guest 尚未重新签名。"
            ],
            steps: [
                "打开 树应用 → ⋯ → 无 JIT 证书设置，确认 p12 和密码有效。",
                "执行“重签所有应用”，等待全部完成。",
                "回到应用列表重新打开树 APP。",
                "仍失败时删除后重新导入未修改的 IPA，并在“错误对照与日志”导出诊断日志。"
            ],
            note: "不要通过关闭系统代码签名校验来“修复”。重签失败时先保留原 IPA 和证书，不要吊销电脑侧证书。"
        ),
        TNBErrorGuideEntry(
            id: "tweakloader-missing",
            title: "树 APP 启动失败：缺少 TweakLoader",
            signature: "TweakLoader.dylib: no such file or directory\n包内缺少 TweakLoader.dylib",
            keywords: "tweakloader missing no such file dylib 缺少",
            causes: ["TreeNB 主包不完整，或 Documents/Tweaks 软链接没有建立成功。"],
            steps: [
                "在“错误对照与日志”的 guest 日志中查找 preflight.tweakloader.missing 或 symlink。",
                "重新安装完整的 TreeNB 主包，不要只重装树 APP。",
                "若软链接建立失败，确认设备存储空间充足后再次打开树应用。"
            ],
            note: "这条错误指向 TreeNB 主包的前置组件，不是被侧载应用自身的 dylib。"
        ),
        TNBErrorGuideEntry(
            id: "engine-missing",
            title: "容器引擎组件缺失",
            signature: "LCEngineErrorDomain · code 9 或 13\nLCAppInfo 不可用 / 引擎组件缺失",
            keywords: "lcengineerror 9 13 lcappinfo 引擎组件缺失",
            causes: ["TreeNB 主包内的 LiveContainer framework 未加载或安装不完整。"],
            steps: [
                "完全结束 TreeNB 后重新打开。",
                "重新安装完整 TreeNB 主包。",
                "若仍出现，导出日志和 .ips 后反馈；不要反复删除树 APP 数据。"
            ],
            note: "这是主包组件问题，导入另一张 p12 通常不能解决。"
        ),
        TNBErrorGuideEntry(
            id: "engine-restart-14",
            title: "无法重启进入树 APP",
            signature: "LCEngineErrorDomain · code 14\n无法重启进入 guest",
            keywords: "lcengineerror 14 restart guest jit jitless 无法重启",
            causes: ["当前没有可用 JIT，或 JIT-less 证书尚未正确配置。"],
            steps: [
                "确认 TreeNB 由支持 JIT 的侧载方式运行，或已导入有效 JIT-less p12。",
                "使用 TreeNB 菜单里的“一键自举中心”检查配对和证书状态。",
                "配置完成后重新点树 APP，不要在后台连续快速重试。"
            ],
            note: "JIT 与 JIT-less 是两种运行条件；证书只解决 JIT-less 路径，不会给系统注入 JIT。"
        ),
        TNBErrorGuideEntry(
            id: "engine-container",
            title: "容器目录或应用不存在",
            signature: "LCEngineErrorDomain · code 2 / 4 / 20 / 21\n目录创建失败 / guest 不存在 / 删除失败",
            keywords: "lcengineerror 2 4 20 21 目录 guest 不存在 删除失败",
            causes: [
                "设备存储空间不足、容器目录不可写，或应用列表还保留已失效记录。",
                "侧载重签后 App Group 不可用，容器已回退到 Documents。"
            ],
            steps: [
                "检查 iPhone 储存空间并关闭占用较大的后台任务。",
                "回到树应用列表下拉刷新。",
                "若条目指向不存在的应用，删除该条目后重新导入 IPA。"
            ],
            note: "新版在 App Group 不可用时会回退 Documents；不要把正常回退误判为必须重签。"
        ),
        TNBErrorGuideEntry(
            id: "zsign-8",
            title: "树 APP 重签失败",
            signature: "LCEngineErrorDomain · code 8\nZSign 签名失败",
            keywords: "lcengineerror 8 zsign 签名失败 重签",
            causes: ["p12 密码错误、证书过期、证书不含私钥，或 guest 包已经损坏。"],
            steps: [
                "重新导入原始 p12，密码使用导出时的密码；无密码证书留空。",
                "执行重签所有应用并查看失败应用名。",
                "对失败的单个应用删除后重新导入 IPA。"
            ],
            note: "这个 code 8 属于 LCEngineErrorDomain，与 TreeNB.OperationError 8 的含义不同。"
        ),
        TNBErrorGuideEntry(
            id: "ipa-invalid",
            title: "IPA 导入失败",
            signature: "LCEngineErrorDomain · code 7 / 11 / 12\nPayload/*.app、Info.plist 缺失或解压失败",
            keywords: "lcengineerror 7 11 12 ipa 解压 payload info.plist 导入失败",
            causes: ["文件不是有效 IPA、下载不完整，或压缩包结构不是标准 Payload/*.app。"],
            steps: [
                "重新从原始来源下载 IPA，确认下载大小完整。",
                "不要用聊天软件二次压缩或重命名伪造扩展名。",
                "使用“安装 IPA”重新导入；若仍失败，保留原文件并导出日志。"
            ],
            note: "TreeNB 会清理解压路径并拒绝越界条目；畸形压缩包不会被强行安装。"
        ),
        TNBErrorGuideEntry(
            id: "device-connection",
            title: "设备连接或配对失败",
            signature: "IdeviceGateway / Minimuxer\nno device / connection failed / pairing error",
            keywords: "no device connection pairing minimuxer idevice 配对 连接失败 usb vpn",
            causes: ["USB 连接不稳定、配对文件失效、设备未解锁，或网络路径不适用于当前连接模式。"],
            steps: [
                "解锁 iPhone 并重新插拔数据线，等待“信任此电脑”。",
                "在一键自举中心重新导入有效配对文件。",
                "Wi-Fi / VPN 模式下确认手机与 TreeNB 可互相访问。",
                "查看诊断日志中的 stage、domain 和 code，不要只依赖“连接失败”四个字。"
            ],
            note: "切换 Apple ID 不需要重新配对；配对文件和账号证书是两套不同数据。"
        ),
        TNBErrorGuideEntry(
            id: "profile-install",
            title: "描述文件安装失败",
            signature: "installProvisioningProfile / misagent_install\nEXC_BAD_ACCESS / SIGSEGV",
            keywords: "profile misagent provisioning 描述文件 sigsegv exc_bad_access 安装",
            causes: [
                "旧版把 C libimobiledevice 与 Rust IDevice 的同名 misagent 函数一起链接，函数返回类型被错误解读。",
                "当前设备连接或描述文件本身也可能返回普通错误；需要按日志中的真实错误码区分。"
            ],
            steps: [
                "使用包含 A7/B1err 修复的新版 TreeNB。",
                "若仍失败，导出诊断日志；不要反复点安装。",
                "若伴随 SIGSEGV，同时保存系统 .ips，便于按 UUID 符号化。"
            ],
            note: "新版已断开 C gateway 的同名符号链接，并对错误对象指针做二次防护；不能仅凭提示文案判断修复。"
        ),
        TNBErrorGuideEntry(
            id: "switch-missing-certificate",
            title: "切换团队时提示缺少证书",
            signature: "此团队尚未归档证书 / 这个 ID 还没有可用的团队签名证书",
            keywords: "切换 团队 证书 未归档 missing certificate",
            causes: ["所选团队的证书尚未导入；本机缓存可能仍有可用私钥，切换时会先检查缓存。"],
            steps: [
                "点该 Apple ID 的“为此 ID 导入 p12 证书”。",
                "导入与 10 位 Team ID 对应的 p12。",
                "确认团队显示“证书已归档”后再切换。"
            ],
            note: "找不到证书时不会清空当前证书，也不会把旧团队证书错配给新团队。"
        ),
        TNBErrorGuideEntry(
            id: "no-stored-team",
            title: "找不到已保存的团队",
            signature: "No stored team with identifier",
            keywords: "no stored team identifier 团队 不存在 switch",
            causes: ["CoreData 中还没有该 Apple ID 的团队记录。"],
            steps: [
                "导入该团队的 p12；新版会从证书 OU 自动识别并补建团队。",
                "或在团队选择页手动填写准确的 10 位 Team ID。",
                "重新切换，不要重新登录已有账号。"
            ],
            note: "OU 是 X.509 ASN.1 字段；新版解析证书主题，不再在 DER 中搜索明文 OU=。"
        ),
        TNBErrorGuideEntry(
            id: "sigsegv",
            title: "主包闪退：SIGSEGV / EXC_BAD_ACCESS",
            signature: "EXC_BAD_ACCESS · SIGSEGV · KERN_INVALID_ADDRESS",
            keywords: "sigsegv exc_bad_access kern_invalid_address ips 闪退 崩溃",
            causes: ["原生指针生命周期、FFI ABI 或动态库签名问题。单凭弹窗无法可靠判断。"],
            steps: [
                "记录发生前的操作：侧载、安装描述文件、切账号或启动树 APP。",
                "保存系统分析报告（设置 → 隐私与安全性 → 分析与改进 → 分析数据）。",
                "在“错误对照与日志”导出 guest 日志。",
                "反馈时同时提供 TreeNB 版本、iPhone 型号、系统版本和 .ips。"
            ],
            note: "日志不记录密码、p12 内容、私钥和 Token；导出前仍应检查是否附带了无关个人信息。"
        )
    ]
}

struct TNBErrorGuideView: View {
    @State private var selectedMode = 0
    @State private var searchText = ""
    @State private var logText = LCEngineEntry.guestLogText()
    @State private var showShare = false
    @State private var showClearConfirmation = false
    @State private var showMailComposer = false
    @State private var showMailFallback = false

    private var filteredEntries: [TNBErrorGuideEntry] {
        guard !searchText.isEmpty else { return TNBErrorGuideContent.entries }
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return TNBErrorGuideContent.entries.filter {
            [$0.title, $0.signature, $0.keywords, $0.causes.joined(separator: " "), $0.steps.joined(separator: " ")]
                .joined(separator: " ").lowercased().contains(needle)
        }
    }

    private var deviceDescription: String {
        "\(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)"
    }

    private var appVersionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
    }

    private func feedbackBody(includeLog: Bool) -> String {
        var body = """
        请描述遇到的问题和复现步骤：

        错误原文：
        \(searchText.isEmpty ? "请补充" : searchText)

        TreeNB：\(appVersionDescription)
        设备：\(deviceDescription)
        """
        if includeLog {
            body += "\n\nTreeNB 诊断日志：\n\(String(logText.suffix(12000)))"
        }
        return body
    }

    private var mailFallbackURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "zhuxiandong@gmail.com"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "TreeNB 错误反馈"),
            URLQueryItem(name: "body", value: feedbackBody(includeLog: true))
        ]
        return components.url
    }

    private func sendFeedback() {
        if MFMailComposeViewController.canSendMail() {
            showMailComposer = true
        } else if let mailFallbackURL {
            showMailFallback = true
            UIApplication.shared.open(mailFallbackURL)
        } else {
            showMailFallback = true
        }
    }

    var body: some View {
        List {
            Section {
                Picker("诊断模式", selection: $selectedMode) {
                    Text("错误对照").tag(0)
                    Text("诊断日志").tag(1)
                }
                .pickerStyle(.segmented)
                Text(selectedMode == 0
                     ? "输入错误原文或错误码搜索。对照表完全内置，断网也能查看。"
                     : "这里记录侧载安装、树 APP 启动、冷接管、修补、重签和容器错误；不会记录密码、p12、私钥或 Token。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                SwiftUI.Button(action: sendFeedback) {
                    Label("没有遇到过的错误？一键提交给开发者", systemImage: "envelope")
                }
                .buttonStyle(.bordered)
            }

            if selectedMode == 0 {
                Section {
                    TextField("例如：OperationError 8、9120、code signature invalid", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if filteredEntries.isEmpty {
                    Section {
                        Text("没有找到对应条目。可切到“诊断日志”，复制错误原文后反馈。")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(filteredEntries) { entry in
                        NavigationLink {
                            TNBErrorGuideDetailView(entry: entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title).font(.subheadline.weight(.semibold))
                                Text(entry.signature.components(separatedBy: "\n").first ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            } else {
                Section {
                    Text(logText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text("guest-launch.log")
                } footer: {
                    Text("日志按时间顺序记录，超过 512 KB 自动轮换一份。分享前请确认没有额外粘贴个人信息。")
                }
            }
        }
        .navigationTitle("错误对照与日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                SwiftUI.Button(action: sendFeedback) {
                    Image(systemName: "envelope")
                }
                .accessibilityLabel("提交错误反馈")
                if selectedMode == 1 {
                    SwiftUI.Button {
                        UIPasteboard.general.string = logText
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("复制日志")
                    SwiftUI.Button {
                        showShare = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("导出日志")
                    SwiftUI.Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("清空日志")
                }
            }
        }
        .sheet(isPresented: $showShare) {
            TNBActivityView(items: [LCEngineEntry.guestLogFileURL()])
        }
        .sheet(isPresented: $showMailComposer) {
            TNBMailComposer(
                subject: "TreeNB 错误反馈",
                body: feedbackBody(includeLog: false),
                attachmentURL: LCEngineEntry.guestLogFileURL()
            )
        }
        .alert("邮件功能不可用", isPresented: $showMailFallback) {
            SwiftUI.Button("复制反馈内容") {
                UIPasteboard.general.string = feedbackBody(includeLog: true)
            }
            SwiftUI.Button("好", role: .cancel) {}
        } message: {
            Text("无法直接创建邮件。请复制反馈内容，发送到 zhuxiandong@gmail.com；系统可能已尝试打开邮件 App。")
        }
        .alert("清空诊断日志？", isPresented: $showClearConfirmation) {
            SwiftUI.Button("取消", role: .cancel) {}
            SwiftUI.Button("清空", role: .destructive) {
                LCEngineEntry.clearGuestLog()
                logText = LCEngineEntry.guestLogText()
            }
        } message: {
            Text("此操作只删除诊断日志，不删除应用、账号、证书或配对文件。")
        }
        .onAppear { logText = LCEngineEntry.guestLogText() }
    }
}

private struct TNBErrorGuideDetailView: View {
    let entry: TNBErrorGuideEntry

    var body: some View {
        List {
            Section {
                Text(entry.signature)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text("错误特征")
            }
            Section {
                ForEach(Array(entry.causes.enumerated()), id: \.offset) { _, cause in
                    Label(cause, systemImage: "circle.fill")
                        .font(.footnote)
                }
            } header: {
                Text("常见原因")
            }
            Section {
                ForEach(Array(entry.steps.enumerated()), id: \.offset) { index, step in
                    Label {
                        Text(step).font(.footnote)
                    } icon: {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .frame(width: 22, height: 22)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
            } header: {
                Text("按顺序排查")
            } footer: {
                Text(entry.note)
            }
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TNBActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct TNBMailComposer: UIViewControllerRepresentable {
    let subject: String
    let body: String
    let attachmentURL: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients(["zhuxiandong@gmail.com"])
        composer.setSubject(subject)
        composer.setMessageBody(body, isHTML: false)
        if let data = try? Data(contentsOf: attachmentURL) {
            composer.addAttachmentData(data, mimeType: "text/plain", fileName: "TreeNB-guest-launch.log")
        }
        return composer
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            controller.dismiss(animated: true)
        }
    }
}
