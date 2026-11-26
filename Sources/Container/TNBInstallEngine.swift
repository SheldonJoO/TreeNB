//
//  TNBInstallEngine.swift
//  TreeNB —— 设备端签名安装引擎（App 内引擎）
//
//  目标：让"从网站下载的 IPA"能在设备上被真正签名并安装到系统，
//  而不是只躺在下载目录里。全程不需要电脑、不需要 siboot/SideInstaller。
//
//  设计原则（2026-11-26 调研结论）：
//  · openSSS/minimuxer 已经把 8 步里的 7 步实现好了：
//      配对文件 → minimuxerStart → fetchUDID →
//      AuthManager 登录会话 → FetchProvisioningProfiles →
//      AppBundleSigner 签名 → sendAppBundleAfc → installation_proxy 安装
//    这 20 步 pipeline 的现成入口就是 AppManager.install(.url)。
//  · 所以本引擎不是重新实现签名协议，而是"前置体检 + 喂给现成 pipeline + 结果回传"。
//  · 只借鉴 siboot 的思路，不引入其任何代码。
//
//  冷启动边界（诚实说明）：
//  首次把 TreeNB 装到裸机仍需外部种子（已有侧载工具 / 企业证书 OTA），
//  因为 TreeNB 没装上时跑不了自己的代码。本引擎负责的是"装好之后"，
//  让后续任意 IPA 都能在设备上自己签、自己装。
//

import Foundation
import UIKit

// MARK: - 引擎状态

enum TNBInstallStage: String, Sendable {
    case checking = "正在检查环境"
    case pairing = "正在连接设备"
    case account = "正在检查 Apple ID 账号"
    case installing = "正在签名并安装"
    case done = "完成"
    case failed = "失败"
}

struct TNBInstallEvent: Sendable {
    let stage: TNBInstallStage
    let progress: Double?
    let message: String
    init(stage: TNBInstallStage, progress: Double? = nil, message: String) {
        self.stage = stage
        self.progress = progress
        self.message = message
    }
}

// MARK: - 引擎

/// 设备端签名安装引擎。所有能力复用 openSSS 已有实现，本类只做编排与体检。
final class TNBInstallEngine {

    static let shared = TNBInstallEngine()
    private init() {}

    /// 引擎是否具备安装前置条件（配对文件 + 账号凭据）。
    /// 返回缺失项的人话说明，空数组表示就绪。
    func missingPrerequisites() -> [String] {
        var missing: [String] = []
        if !PairingFileManager.shared.hasPairingFile() {
            missing.append("设备配对文件（在「一键自举中心」导入）")
        }
        let cm = CertificateManager.shared
        let hasCert = (cm.activeCertificate ?? (try? cm.loadActiveCertificate())) != nil
        if !hasCert {
            missing.append("Apple ID 账号证书（在「我的」页登录 Apple ID）")
        }
        return missing
    }

    /// 启动设备连接：加载配对文件 → minimuxer → 验证 UDID。
    /// 这一步是系统安装区别于 guest 安装的关键前置（BootstrapCenterView 没做）。
    func connectDevice() async throws {
        guard let pf = PairingFileManager.shared.fetchPairingFile() else {
            throw TNBInstallError.missingPairing
        }
        try await minimuxerStart(pf, preferred: PairingFileManager.shared.preferredProtocol)
        _ = try await fetchUDID(forceLive: true)
    }

    /// 主入口：把一个本地 IPA 签名并安装到系统。
    ///
    /// - Parameters:
    ///   - ipaURL: 已下载到本地的 IPA 路径
    ///   - presentingViewController: 用于可能的登录/证书弹窗；传 nil 时尽量走静默会话
    ///   - onEvent: 进度回调（主线程）
    /// - Returns: 安装结果信息
    @discardableResult
    func install(
        ipaURL: URL,
        presentingViewController: UIViewController? = nil,
        onEvent: @escaping (TNBInstallEvent) -> Void
    ) async -> Result<String, TNBInstallError> {

        // 1) 环境体检
        onEvent(.init(stage: .checking, message: "正在检查 IPA 文件…"))
        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            return fail(.ipaNotFound, onEvent: onEvent)
        }

        let missing = missingPrerequisites()
        guard missing.isEmpty else {
            onEvent(.init(stage: .failed, message: "缺少前置条件：\(missing.joined(separator: "、"))"))
            return .failure(.prerequisites(missing))
        }

        // 2) 设备连接（配对文件 → minimuxer → UDID）
        onEvent(.init(stage: .pairing, message: "正在连接设备…"))
        do {
            try await connectDevice()
        } catch {
            onEvent(.init(stage: .failed, message: "设备连接失败：\(error.localizedDescription)"))
            return .failure(.deviceConnect(error.localizedDescription))
        }

        // 3) 账号会话：有 token 走静默，否则 AppManager.install 的 pipeline 会弹登录。
        onEvent(.init(stage: .account, message: "正在检查 Apple ID 账号…"))
        do {
            _ = try await AuthManager.shared.getAuthenticatedSession()
        } catch {
            // token/密码静默恢复失败：pipeline 内会用 SignInFlowHandler 弹交互登录。
            // 这里不直接失败，把交互交给 pipeline（presentingViewController 提供宿主）。
            onEvent(.init(stage: .account,
                          message: "需要 Apple ID 登录，请在弹窗中完成…"))
        }

        // 4) 交给 openSSS 现成的 20 步 pipeline（签名+上传+安装全在里面）
        onEvent(.init(stage: .installing, progress: 0,
                      message: "正在签名并安装（这一步可能需要 1-2 分钟）…"))
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<InstalledApp, Error>, Never>) in
            AppManager.shared.install(
                .url(ipaURL),
                presentingViewController: presentingViewController
            ) { result in
                cont.resume(returning: result)
            }
        }

        switch result {
        case .success(let app):
            let name = app.name ?? app.bundleIdentifier
            onEvent(.init(stage: .done, progress: 1, message: "安装成功：\(name) ✅"))
            return .success(name)
        case .failure(let error):
            return fail(.pipeline(error.localizedDescription), onEvent: onEvent)
        }
    }

    private func fail(_ err: TNBInstallError, onEvent: (TNBInstallEvent) -> Void) -> Result<String, TNBInstallError> {
        onEvent(.init(stage: .failed, message: err.localizedDescription))
        return .failure(err)
    }
}

// MARK: - 错误

enum TNBInstallError: LocalizedError, Sendable {
    case ipaNotFound
    case missingPairing
    case prerequisites([String])
    case deviceConnect(String)
    case pipeline(String)

    var errorDescription: String? {
        switch self {
        case .ipaNotFound: return "找不到 IPA 文件。"
        case .missingPairing: return "缺少设备配对文件。"
        case .prerequisites(let items): return "缺少前置条件：\(items.joined(separator: "、"))"
        case .deviceConnect(let m): return "设备连接失败：\(m)"
        case .pipeline(let m): return "签名安装失败：\(m)"
        }
    }
}
