//
//  TNBAccountVault.swift
//  TreeNB —— 多 Apple ID 保险库
//
//  设计目标（用户侧）：
//  1. TreeNB 上固定保存多个 Apple ID，每个 id 的账号、团队、证书（含私钥）、
//     anisette、登录 token 各自独立，切换 = 激活，不是重新登录。
//  2. 电脑侧载用过的 id 证书可以直接带过来用（导入账号配置 / 导入 p12），
//     不会吊销电脑那边的证书；同一个证书可以多设备签名。
//  3. 手机上也可以再登录另一个 id，两条路径并存，随时切回。
//
//  为什么需要这一层：
//  上游 Keychain 只保存「一份」Apple ID 凭据（email/password/adsid/token），
//  CoreData 虽然能存多个 Account/Team，但 AuthManager.switchActiveTeam()
//  只翻数据库标记、不换 Keychain 凭据 —— 切到别的 id 就不匹配，
//  于是被迫「重新登录」。保险库把每个 id 的完整凭据留在 Keychain，
//  切换时整包写回，从根本上消掉这个重登要求。
//

import Foundation
import UIKit
import CoreData
import CryptoKit
import CommonCrypto
import SideSign

// MARK: - 数据模型

struct TNBTeamRecord: Codable, Identifiable, Hashable {
    let identifier: String
    let name: String
    let type: String
    var id: String { identifier }
}

struct TNBAccountRecord: Codable, Identifiable, Hashable {
    var id: UUID
    var email: String
    var teams: [TNBTeamRecord]
    var activeTeamIdentifier: String?
    var password: String?
    var adsid: String?
    var xcodeToken: String?
    var certificateP12: Data?
    var certificatePassword: String?
    var anisetteIdentifier: String?
    var anisetteAdiBlob: String?
    /// local = 手机登录；computer = 从电脑账号配置导入；p12 = 手动导入证书
    var source: String
    var updatedAt: Date

    var activeTeam: TNBTeamRecord? {
        guard let identifier = activeTeamIdentifier else { return teams.first }
        return teams.first { $0.identifier == identifier } ?? teams.first
    }

    var hasUsableCredentials: Bool {
        (xcodeToken != nil && adsid != nil) || password != nil
    }

    var hasCertificate: Bool {
        guard let data = certificateP12 else { return false }
        return !data.isEmpty
    }
}

private struct TNVaultContainer: Codable {
    var version: Int
    var currentID: UUID?
    var accounts: [TNBAccountRecord]
}

// MARK: - 保险库

@MainActor
final class TNBAccountVault: ObservableObject {
    static let shared = TNBAccountVault()

    @Published private(set) var accounts: [TNBAccountRecord] = []

    private var currentID: UUID?

    private init() {
        reload()
    }

    // MARK: 读取 / 持久化

    func reload() {
        guard let data = Keychain.shared.tnbAccountVaultData,
              let container = try? JSONDecoder().decode(TNVaultContainer.self, from: data) else {
            migrateFromCurrentState()
            return
        }
        self.accounts = container.accounts
        self.currentID = container.currentID ?? container.accounts.first(where: {
            $0.email.caseInsensitiveCompare(Keychain.shared.appleIDEmailAddress ?? "") == .orderedSame
        })?.id
        if accounts.isEmpty {
            migrateFromCurrentState()
        }
    }

    private func persist() {
        let container = TNVaultContainer(version: 1, currentID: currentID, accounts: accounts)
        if let data = try? JSONEncoder().encode(container) {
            Keychain.shared.tnbAccountVaultData = data
        }
        objectWillChange.send()
        NotificationCenter.default.post(name: .tnbAccountVaultChanged, object: nil)
    }

    var activeAccount: TNBAccountRecord? {
        accounts.first { $0.id == currentID }
    }

    /// 当前 Keychain 里的 email 是否已经是保险库里的某个账号。
    func record(forEmail email: String) -> TNBAccountRecord? {
        accounts.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }
    }

    // MARK: 首次迁移：把上游现状收编为第一条记录

    private func migrateFromCurrentState() {
        let keychain = Keychain.shared
        var byEmail: [String: TNBAccountRecord] = [:]

        let context = DatabaseManager.shared.viewContext
        let storedTeams = (try? context.fetch(Team.fetchRequest())) ?? []
        for team in storedTeams {
            let email = team.account?.appleID ?? keychain.appleIDEmailAddress ?? ""
            if email.isEmpty { continue }
            let record = TNBAccountRecord(
                id: UUID(),
                email: email,
                teams: [TNBTeamRecord(identifier: team.identifier,
                                       name: team.name,
                                       type: team.type.localizedDescription)],
                activeTeamIdentifier: team.isActiveTeam ? team.identifier : nil,
                password: nil,
                adsid: nil,
                xcodeToken: nil,
                certificateP12: nil,
                certificatePassword: nil,
                anisetteIdentifier: nil,
                anisetteAdiBlob: nil,
                source: "local",
                updatedAt: Date()
            )
            if var existing = byEmail[email.lowercased()] {
                if !existing.teams.contains(record.teams[0]) {
                    existing.teams.append(record.teams[0])
                }
                if record.activeTeamIdentifier != nil {
                    existing.activeTeamIdentifier = record.activeTeamIdentifier
                }
                byEmail[email.lowercased()] = existing
            } else {
                byEmail[email.lowercased()] = record
            }
        }

        if let email = keychain.appleIDEmailAddress, !email.isEmpty, byEmail[email.lowercased()] == nil {
            byEmail[email.lowercased()] = TNBAccountRecord(
                id: UUID(), email: email, teams: [], activeTeamIdentifier: nil,
                password: nil, adsid: nil, xcodeToken: nil,
                certificateP12: nil, certificatePassword: nil,
                anisetteIdentifier: nil, anisetteAdiBlob: nil,
                source: "local", updatedAt: Date()
            )
        }

        var all = Array(byEmail.values)
        if let email = keychain.appleIDEmailAddress,
           let index = all.firstIndex(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) {
            all[index].password = keychain.appleIDPassword
            all[index].adsid = keychain.appleIDAdsid
            all[index].xcodeToken = keychain.appleIDXcodeToken
            all[index].anisetteIdentifier = AnisetteConfigManager.shared.anisetteIdentifier
            all[index].anisetteAdiBlob = AnisetteConfigManager.shared.anisetteAdiBlob
            all[index].certificateP12 = keychain.signingCertificate
            all[index].certificatePassword = keychain.signingCertificatePassword
            all[index].source = "local"
            self.currentID = all[index].id
        } else {
            self.currentID = all.first?.id
        }
        self.accounts = all
        persist()
        debugLog("[TreeNB][Vault] migrated \(all.count) Apple ID(s) into account vault")
    }

    // MARK: 保存当前状态（切换前先归档，避免凭据丢失）

    /// 把当前 Keychain/证书/anisette 的瞬时状态写回当前激活记录。
    func captureCurrent() {
        guard let email = Keychain.shared.appleIDEmailAddress, !email.isEmpty else { return }
        var target = record(forEmail: email)
        if target == nil {
            target = TNBAccountRecord(
                id: UUID(), email: email, teams: [], activeTeamIdentifier: nil,
                password: nil, adsid: nil, xcodeToken: nil,
                certificateP12: nil, certificatePassword: nil,
                anisetteIdentifier: nil, anisetteAdiBlob: nil,
                source: "local", updatedAt: Date()
            )
            accounts.append(target!)
        }
        guard let index = accounts.firstIndex(where: { $0.id == target!.id }) else { return }
        accounts[index].password = Keychain.shared.appleIDPassword
        accounts[index].adsid = Keychain.shared.appleIDAdsid
        accounts[index].xcodeToken = Keychain.shared.appleIDXcodeToken
        accounts[index].anisetteIdentifier = AnisetteConfigManager.shared.anisetteIdentifier
        accounts[index].anisetteAdiBlob = AnisetteConfigManager.shared.anisetteAdiBlob
        if let cert = Keychain.shared.signingCertificate {
            accounts[index].certificateP12 = cert
            accounts[index].certificatePassword = Keychain.shared.signingCertificatePassword
        }
        let activeTeamID = (try? DatabaseManager.shared.viewContext.fetch(Team.fetchRequest()))
            .flatMap { $0.first { $0.isActiveTeam } }?.identifier
        if let activeTeamID { accounts[index].activeTeamIdentifier = activeTeamID }
        accounts[index].updatedAt = Date()
        currentID = accounts[index].id
        persist()
    }

    /// 登录新 Apple ID 完成后调用：把当前会话收编成一条新记录。
    func captureCurrentAsNewAccount(source: String = "local") {
        captureCurrent()
        guard let active = activeAccount else { return }
        guard let index = accounts.firstIndex(where: { $0.id == active.id }) else { return }
        accounts[index].source = source
        accounts[index].id = UUID() // 新记录，避免与原 id 合并
        currentID = accounts[index].id
        persist()
    }

    // MARK: 切换：整包凭据回写 + 团队标记 + 证书激活

    /// 切到某个已保存的 Apple ID / 团队。不需要重新输入账号密码。
    func activate(accountID: UUID, teamIdentifier: String?) async throws {
        captureCurrent()
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            throw TNVaultError.accountNotFound
        }
        let record = accounts[index]
        let targetTeamID = teamIdentifier ?? record.activeTeam?.identifier ?? record.teams.first?.identifier

        // 1) Keychain 凭据整包回写（这就是不再重登的关键）
        let keychain = Keychain.shared
        keychain.appleIDEmailAddress = record.email
        keychain.appleIDPassword = record.password
        keychain.appleIDAdsid = record.adsid
        keychain.appleIDXcodeToken = record.xcodeToken
        AnisetteConfigManager.shared.anisetteIdentifier = record.anisetteIdentifier
        AnisetteConfigManager.shared.anisetteAdiBlob = record.anisetteAdiBlob

        // 2) 证书：优先用本 id 保存的 p12；没有就从本地证书缓存按 team 找
        var certificateActivated = false
        if let p12 = record.certificateP12, !p12.isEmpty,
           let cert = try? CertificateManager.parse(p12, password: record.certificatePassword) {
            try? CertificateManager.shared.setActiveCertificate(cert)
            certificateActivated = true
        } else if let teamID = targetTeamID {
            certificateActivated = activateCachedCertificate(for: teamID)
        }
        if !certificateActivated {
            debugLog("[TreeNB][Vault] no local certificate for \(record.email); signing will provision one")
        }

        // 3) 数据库只负责激活团队标记；凭据已经由第 1 步对齐。
        //    电脑导入的 id 在手机上可能还没有团队记录 → 先补建再切。
        if let teamID = targetTeamID {
            ensureTeamRecord(email: record.email, teamID: teamID)
            do {
                try await AuthManager.shared.switchActiveTeam(to: teamID)
            } catch {
                ensureTeamRecord(email: record.email, teamID: teamID)
                do {
                    try await AuthManager.shared.switchActiveTeam(to: teamID)
                } catch {
                    // 凭据与证书已经写回；团队标记失败不阻断切换，
                    // 后续签名会提示用该 id 登录一次以补全团队信息。
                    debugLog("[TreeNB][Vault] team activation deferred: \(error)")
                }
            }
        } else {
            await AuthManager.shared.signOut(keepCertificate: true, keepAnisetteData: true)
        }

        accounts[index].activeTeamIdentifier = targetTeamID
        accounts[index].updatedAt = Date()
        currentID = record.id
        persist()
        debugLog("[TreeNB][Vault] activated \(record.email) team=\(targetTeamID ?? "none") cert=\(certificateActivated)")
    }

    /// 从 p12 里读出 OU=TEAMID，并补建 CoreData 团队记录。
    /// 电脑导过来的账号在手机上往往只有证书、没有开发者团队记录，
    /// 不补这一步 switchActiveTeam 会报 “No stored team with identifier”。
    private static func teamID(from p12: Data, password: String?) -> String? {
        guard let cert = try? CertificateManager.parse(p12, password: password),
              let der = cert.data else { return nil }
        let text = String(decoding: der, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: "OU=([A-Z0-9]{10})"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func ensureTeamRecord(email: String, teamID: String) {
        let context = DatabaseManager.shared.viewContext

        let accountRequest = Account.fetchRequest()
        accountRequest.predicate = NSPredicate(format: "%K ==[c] %@", #keyPath(Account.appleID), email)
        let account: NSManagedObject
        if let existing = (try? context.fetch(accountRequest))?.first {
            account = existing
        } else if let entity = NSEntityDescription.entity(forEntityName: "Account", in: context) {
            account = NSManagedObject(entity: entity, insertInto: context)
            account.setValue(email, forKey: "appleID")
            account.setValue(UUID().uuidString, forKey: "identifier")
            account.setValue("", forKey: "firstName")
            account.setValue("", forKey: "lastName")
            account.setValue(false, forKey: "isActiveAccount")
        } else {
            return
        }

        let teamRequest = Team.fetchRequest()
        teamRequest.predicate = NSPredicate(format: "%K == %@", #keyPath(Team.identifier), teamID)
        if (try? context.fetch(teamRequest))?.first != nil { return }
        guard let entity = NSEntityDescription.entity(forEntityName: "Team", in: context) else { return }
        let team = NSManagedObject(entity: entity, insertInto: context)
        team.setValue(teamID, forKey: "identifier")
        team.setValue("TreeNB 导入的团队", forKey: "name")
        team.setValue(NSNumber(value: 0), forKey: "typeValue")
        team.setValue(false, forKey: "isActiveTeam")
        team.setValue(account, forKey: "account")
        try? context.save()
    }

    /// 从本地证书缓存里找属于该 team 的证书并激活。
    @discardableResult
    private func activateCachedCertificate(for teamIdentifier: String) -> Bool {
        let manager = CertificateManager.shared
        let needle = Data(teamIdentifier.utf8)
        var candidates = manager.getAllLocalCertificates()
        if let active = manager.activeCertificate?.certificate { candidates.append(active) }
        for cert in candidates {
            guard let der = cert.data, der.range(of: needle) != nil else { continue }
            let password = manager.getPassword(for: cert)
            guard let data = try? CertificateManager.convert(cert, password: password),
                  let parsed = try? CertificateManager.parse(data, password: password) else { continue }
            try? manager.setActiveCertificate(parsed)
            return true
        }
        return false
    }

    // MARK: 导入 / 导出（电脑 ↔ 手机双向）

    /// 导入 SideStore / iLoader 导出的账号配置（加密的 ImportedAccount）。
    /// 只解密入库，不立刻覆盖当前激活账号，用户可以选择何时切换。
    func importAccountBackup(_ data: Data, filePassword: String) async throws -> TNBAccountRecord {
        let imported = try ImportExport.decryptAccount(data, filePassword: filePassword)
        captureCurrent()

        var record = record(forEmail: imported.email)
        if record == nil {
            record = TNBAccountRecord(
                id: UUID(), email: imported.email, teams: [], activeTeamIdentifier: nil,
                password: nil, adsid: nil, xcodeToken: nil,
                certificateP12: nil, certificatePassword: nil,
                anisetteIdentifier: nil, anisetteAdiBlob: nil,
                source: "computer", updatedAt: Date()
            )
            accounts.append(record!)
        }
        guard let index = accounts.firstIndex(where: { $0.id == record!.id }) else {
            throw TNVaultError.accountNotFound
        }
        accounts[index].password = imported.password
        accounts[index].certificateP12 = imported.certificateData
        accounts[index].certificatePassword = imported.certificatePassword
        accounts[index].anisetteIdentifier = imported.anisetteIdentifier
        accounts[index].anisetteAdiBlob = imported.anisetteAdiBlob
        accounts[index].source = "computer"
        accounts[index].updatedAt = Date()
        if let tid = Self.teamID(from: imported.certificateData, password: imported.certificatePassword) {
            let team = TNBTeamRecord(identifier: tid, name: "TreeNB 导入的团队", type: "电脑证书")
            if !accounts[index].teams.contains(team) { accounts[index].teams.append(team) }
            ensureTeamRecord(email: imported.email, teamID: tid)
        }
        persist()
        debugLog("[TreeNB][Vault] imported computer account: \(imported.email)")
        return accounts[index]
    }

    /// 把某个保存的 id 导出成加密账号配置，方便带回电脑继续用。
    func exportAccountBackup(accountID: UUID, filePassword: String) throws -> Data {
        guard let record = accounts.first(where: { $0.id == accountID }),
              let p12 = record.certificateP12 else {
            throw TNVaultError.missingCertificate
        }
        let imported = ImportedAccount(
            version: ImportedAccount.currentVersion,
            email: record.email,
            password: record.password,
            certificateData: p12,
            certificatePassword: record.certificatePassword,
            anisetteIdentifier: record.anisetteIdentifier ?? "",
            anisetteAdiBlob: record.anisetteAdiBlob ?? ""
        )
        return try ImportExport.encryptAccount(imported, filePassword: filePassword)
    }

    /// 给某个 id 绑定手动导入的 p12（iLoader / 电脑导出的证书）。
    func attachCertificate(accountID: UUID, p12: Data, password: String?) throws {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            throw TNVaultError.accountNotFound
        }
        _ = try CertificateManager.parse(p12, password: password)
        accounts[index].certificateP12 = p12
        accounts[index].certificatePassword = password
        accounts[index].updatedAt = Date()
        persist()
    }

    func remove(accountID: UUID) {
        accounts.removeAll { $0.id == accountID }
        if currentID == accountID {
            currentID = accounts.first?.id
            if let email = activeAccount?.email {
                Keychain.shared.appleIDEmailAddress = email
            }
        }
        persist()
    }

    /// 团队列表由调用方在成功登录后刷新（Developer Portal 返回的 teams）。
    func updateTeams(email: String, teams: [TNBTeamRecord]) {
        guard let index = accounts.firstIndex(where: {
            $0.email.caseInsensitiveCompare(email) == .orderedSame
        }) else { return }
        var merged = accounts[index].teams
        for team in teams where !merged.contains(team) { merged.append(team) }
        accounts[index].teams = merged
        accounts[index].updatedAt = Date()
        persist()
    }
}

// MARK: - 错误

enum TNVaultError: LocalizedError {
    case accountNotFound
    case missingCertificate
    case invalidBackup

    var errorDescription: String? {
        switch self {
        case .accountNotFound: return "找不到这个 Apple ID 的保存记录。"
        case .missingCertificate: return "这个 Apple ID 还没有保存签名证书。请先登录或导入 p12。"
        case .invalidBackup: return "账号配置文件格式不对或密码错误。"
        }
    }
}

extension Notification.Name {
    static let tnbAccountVaultChanged = Notification.Name("tnbAccountVaultChanged")
}
