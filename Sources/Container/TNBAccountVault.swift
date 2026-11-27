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

struct TNBCertificateRecord: Codable, Hashable {
    let teamID: String
    let p12: Data
    let password: String?
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
    var certificates: [TNBCertificateRecord]?
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
        ((xcodeToken?.isEmpty == false) && (adsid?.isEmpty == false)) || (password?.isEmpty == false)
    }

    var hasCertificate: Bool {
        guard let data = certificateP12 else { return false }
        return !data.isEmpty
    }

    func certificate(forTeam teamID: String?) -> (p12: Data, password: String?)? {
        if let teamID, let certificate = certificates?.first(where: { $0.teamID == teamID }) {
            return (certificate.p12, certificate.password)
        }
        if let teamID, let p12 = certificateP12,
           let certificateTeam = TNBAccountVault.teamID(from: p12, password: certificatePassword),
           certificateTeam == teamID {
            return (p12, certificatePassword)
        }
        guard teamID == nil, let p12 = certificateP12 else { return nil }
        return (p12, certificatePassword)
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
        self.accounts = Self.deduplicated(container.accounts, preferredID: container.currentID)
        self.currentID = container.currentID ?? container.accounts.first(where: {
            $0.email.caseInsensitiveCompare(Keychain.shared.appleIDEmailAddress ?? "") == .orderedSame
        })?.id
        if let currentID, !accounts.contains(where: { $0.id == currentID }) {
            self.currentID = accounts.first(where: {
                $0.email.caseInsensitiveCompare(Keychain.shared.appleIDEmailAddress ?? "") == .orderedSame
            })?.id ?? accounts.first?.id
        }
        if accounts.isEmpty {
            migrateFromCurrentState()
        } else if self.accounts != container.accounts {
            persist()
        }
    }

    private static func deduplicated(_ records: [TNBAccountRecord], preferredID: UUID?) -> [TNBAccountRecord] {
        var result: [TNBAccountRecord] = []
        for record in records {
            guard let index = result.firstIndex(where: {
                $0.email.caseInsensitiveCompare(record.email) == .orderedSame
            }) else {
                result.append(record)
                continue
            }
            var existing = result[index]
            if existing.id != preferredID, record.id == preferredID { existing.id = record.id }
            if existing.password?.isEmpty != false { existing.password = record.password }
            if existing.adsid?.isEmpty != false { existing.adsid = record.adsid }
            if existing.xcodeToken?.isEmpty != false { existing.xcodeToken = record.xcodeToken }
            if existing.certificateP12 == nil { existing.certificateP12 = record.certificateP12 }
            if existing.certificatePassword == nil { existing.certificatePassword = record.certificatePassword }
            if existing.anisetteIdentifier == nil { existing.anisetteIdentifier = record.anisetteIdentifier }
            if existing.anisetteAdiBlob == nil { existing.anisetteAdiBlob = record.anisetteAdiBlob }
            if existing.activeTeamIdentifier == nil { existing.activeTeamIdentifier = record.activeTeamIdentifier }
            for team in record.teams where !existing.teams.contains(where: { $0.identifier == team.identifier }) {
                existing.teams.append(team)
            }
            var certificates = existing.certificates ?? []
            for certificate in record.certificates ?? [] {
                if let certificateIndex = certificates.firstIndex(where: { $0.teamID == certificate.teamID }) {
                    if record.updatedAt > existing.updatedAt {
                        certificates[certificateIndex] = certificate
                    }
                } else {
                    certificates.append(certificate)
                }
            }
            existing.certificates = certificates.isEmpty ? nil : certificates
            if record.updatedAt > existing.updatedAt { existing.updatedAt = record.updatedAt }
            result[index] = existing
        }
        return result
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
                if !existing.teams.contains(where: { $0.identifier == record.teams[0].identifier }) {
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
        let keychain = Keychain.shared
        guard let email = keychain.appleIDEmailAddress, !email.isEmpty else { return }
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
        if let password = keychain.appleIDPassword { accounts[index].password = password }
        if let adsid = keychain.appleIDAdsid { accounts[index].adsid = adsid }
        if let token = keychain.appleIDXcodeToken { accounts[index].xcodeToken = token }
        if let identifier = AnisetteConfigManager.shared.anisetteIdentifier {
            accounts[index].anisetteIdentifier = identifier
        }
        if let blob = AnisetteConfigManager.shared.anisetteAdiBlob {
            accounts[index].anisetteAdiBlob = blob
        }
        let teams = (try? DatabaseManager.shared.viewContext.fetch(Team.fetchRequest())) ?? []
        let accountTeams = teams.filter { $0.account?.appleID?.caseInsensitiveCompare(email) == .orderedSame }
        if let cert = keychain.signingCertificate {
            let certificateTeam = Self.teamID(from: cert, password: keychain.signingCertificatePassword)
            let belongsToAccount = certificateTeam == nil
                ? !accounts[index].teams.isEmpty
                : accountTeams.contains(where: { $0.identifier == certificateTeam })
                    || accounts[index].teams.contains(where: { $0.identifier == certificateTeam })
            if belongsToAccount {
                storeCertificate(cert, password: keychain.signingCertificatePassword, at: &accounts[index])
            }
        }
        for team in accountTeams {
            let record = TNBTeamRecord(identifier: team.identifier, name: team.name,
                                       type: team.type.localizedDescription)
            if !accounts[index].teams.contains(where: { $0.identifier == record.identifier }) {
                accounts[index].teams.append(record)
            }
        }
        if let activeTeamID = accountTeams.first(where: { $0.isActiveTeam })?.identifier {
            accounts[index].activeTeamIdentifier = activeTeamID
        }
        accounts[index].updatedAt = Date()
        currentID = accounts[index].id
        persist()
    }

    /// 登录新 Apple ID 完成后调用；同一 Apple ID 更新原记录，不制造重复账号。
    func captureCurrentAsNewAccount(source: String = "local") {
        captureCurrent()
        guard let email = Keychain.shared.appleIDEmailAddress,
              let index = accounts.firstIndex(where: {
                  $0.email.caseInsensitiveCompare(email) == .orderedSame
              }) else { return }
        accounts[index].source = source
        currentID = accounts[index].id
        persist()
    }

    private func storeCertificate(_ p12: Data, password: String?, at record: inout TNBAccountRecord) {
        guard !p12.isEmpty else { return }
        if let teamID = Self.teamID(from: p12, password: password) {
            var certificates = record.certificates ?? []
            certificates.removeAll { $0.teamID == teamID }
            certificates.append(TNBCertificateRecord(teamID: teamID, p12: p12, password: password))
            record.certificates = certificates
        }
        if record.certificateP12 == nil {
            record.certificateP12 = p12
            record.certificatePassword = password
        }
    }

    // MARK: 切换：整包凭据回写 + 团队标记 + 证书激活

    /// 切到某个已保存的 Apple ID / 团队。不需要重新输入账号密码。
    func activate(accountID: UUID, teamIdentifier: String?) async throws {
        captureCurrent()
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            throw TNVaultError.accountNotFound
        }
        var record = accounts[index]
        guard record.hasUsableCredentials else { throw TNVaultError.missingCredentials }
        let requestedTeam = teamIdentifier ?? record.activeTeamIdentifier
        if let requestedTeam {
            guard Self.isValidTeamIdentifier(requestedTeam) else { throw TNVaultError.invalidTeam }
            if !record.teams.contains(where: { $0.identifier == requestedTeam }) {
                let team = TNBTeamRecord(identifier: requestedTeam, name: "手动添加的团队", type: "开发者团队")
                record.teams.append(team)
            }
        }
        let targetTeamID = requestedTeam ?? record.teams.first?.identifier
        if let targetTeamID { try ensureTeamRecord(email: record.email, teamID: targetTeamID) }

        var storedCertificate = record.certificate(forTeam: targetTeamID)
        if storedCertificate == nil, let teamID = targetTeamID {
            storedCertificate = cachedCertificate(for: teamID)
        }
        let certificate = try storedCertificate.map {
            try CertificateManager.parse($0.p12, password: $0.password)
        }
        let manager = CertificateManager.shared
        let previousCertificate = manager.activeCertificate?.certificate
        let context = DatabaseManager.shared.viewContext
        let previousTeamID = ((try? context.fetch(Team.fetchRequest())) ?? [])
            .first(where: { $0.isActiveTeam })?.identifier

        do {
            try manager.setActiveCertificate(certificate)
            if let teamID = targetTeamID {
                try await AuthManager.shared.switchActiveTeam(to: teamID)
            } else {
                await AuthManager.shared.signOut(keepCertificate: true, keepAnisetteData: true)
            }
        } catch {
            if let previousTeamID {
                try? await AuthManager.shared.switchActiveTeam(to: previousTeamID)
            }
            try? manager.setActiveCertificate(previousCertificate)
            throw error
        }

        let keychain = Keychain.shared
        keychain.appleIDEmailAddress = record.email
        keychain.appleIDPassword = record.password
        keychain.appleIDAdsid = record.adsid
        keychain.appleIDXcodeToken = record.xcodeToken
        AnisetteConfigManager.shared.anisetteIdentifier = record.anisetteIdentifier
        AnisetteConfigManager.shared.anisetteAdiBlob = record.anisetteAdiBlob
        AnisetteDataManager.shared.clearCache()

        guard let updatedIndex = accounts.firstIndex(where: { $0.id == accountID }) else {
            throw TNVaultError.accountNotFound
        }
        accounts[updatedIndex] = record
        if let storedCertificate {
            storeCertificate(storedCertificate.p12, password: storedCertificate.password, at: &accounts[updatedIndex])
        }
        accounts[updatedIndex].activeTeamIdentifier = targetTeamID
        accounts[updatedIndex].updatedAt = Date()
        currentID = accountID
        persist()
        debugLog("[TreeNB][Vault] activated \(record.email) team=\(targetTeamID ?? "none") cert=\(certificate != nil)")
    }

    nonisolated static func isValidTeamIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57)
        }
    }

    /// 从 p12 里读出 OU=TEAMID，并补建 CoreData 团队记录。
    /// 电脑导过来的账号在手机上往往只有证书、没有开发者团队记录，
    /// 不补这一步 switchActiveTeam 会报 “No stored team with identifier”。
    nonisolated static func teamID(from p12: Data, password: String?) -> String? {
        guard let cert = try? CertificateManager.parse(p12, password: password),
              let der = cert.data else { return nil }
        let text = String(decoding: der, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: "OU=([A-Z0-9]{10})"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func ensureTeamRecord(email: String, teamID: String) throws {
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
        let existingTeam = (try? context.fetch(teamRequest))?.first
        if let existingTeam {
            if existingTeam.account !== account {
                existingTeam.setValue(account, forKey: "account")
                try context.save()
            }
            return
        }
        guard let entity = NSEntityDescription.entity(forEntityName: "Team", in: context) else { return }
        let team = NSManagedObject(entity: entity, insertInto: context)
        team.setValue(teamID, forKey: "identifier")
        team.setValue("TreeNB 导入的团队", forKey: "name")
        team.setValue(NSNumber(value: 0), forKey: "typeValue")
        team.setValue(false, forKey: "isActiveTeam")
        team.setValue(account, forKey: "account")
        do { try context.save() } catch {
            debugLog("[TreeNB][Vault] failed to save team \(teamID): \(error)")
            throw error
        }
    }

    /// 从本地证书缓存里找属于该 team 的证书，供旧版本已切换但未归档的记录恢复。
    private func cachedCertificate(for teamIdentifier: String) -> (p12: Data, password: String?)? {
        let manager = CertificateManager.shared
        let needle = Data(teamIdentifier.utf8)
        var candidates = manager.getAllLocalCertificates()
        if let active = manager.activeCertificate?.certificate { candidates.append(active) }
        for cert in candidates {
            guard let der = cert.data, der.range(of: needle) != nil else { continue }
            let password = manager.getPassword(for: cert)
            guard let data = try? CertificateManager.convert(cert, password: password),
                  Self.teamID(from: data, password: password) == teamIdentifier else { continue }
            return (data, password)
        }
        return nil
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
        if let password = imported.password { accounts[index].password = password }
        storeCertificate(imported.certificateData, password: imported.certificatePassword, at: &accounts[index])
        if !imported.anisetteIdentifier.isEmpty {
            accounts[index].anisetteIdentifier = imported.anisetteIdentifier
        }
        if !imported.anisetteAdiBlob.isEmpty {
            accounts[index].anisetteAdiBlob = imported.anisetteAdiBlob
        }
        accounts[index].source = "computer"
        accounts[index].updatedAt = Date()
        if let tid = Self.teamID(from: imported.certificateData, password: imported.certificatePassword) {
            let team = TNBTeamRecord(identifier: tid, name: "TreeNB 导入的团队", type: "电脑证书")
            if !accounts[index].teams.contains(where: { $0.identifier == tid }) {
                accounts[index].teams.append(team)
            }
            try ensureTeamRecord(email: imported.email, teamID: tid)
        }
        persist()
        debugLog("[TreeNB][Vault] imported computer account: \(imported.email)")
        return accounts[index]
    }

    /// 把某个保存的 id 导出成加密账号配置，方便带回电脑继续用。
    func exportAccountBackup(accountID: UUID, filePassword: String) throws -> Data {
        guard let record = accounts.first(where: { $0.id == accountID }),
              let certificate = record.certificate(forTeam: record.activeTeamIdentifier) else {
            throw TNVaultError.missingCertificate
        }
        let imported = ImportedAccount(
            version: ImportedAccount.currentVersion,
            email: record.email,
            password: record.password,
            certificateData: certificate.p12,
            certificatePassword: certificate.password,
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
        var record = accounts[index]
        storeCertificate(p12, password: password, at: &record)
        if let teamID = Self.teamID(from: p12, password: password) {
            let team = TNBTeamRecord(identifier: teamID, name: "证书中的开发者团队", type: "证书识别")
            if !record.teams.contains(where: { $0.identifier == teamID }) {
                record.teams.append(team)
            }
            if record.activeTeamIdentifier == nil { record.activeTeamIdentifier = teamID }
            try ensureTeamRecord(email: record.email, teamID: teamID)
        }
        record.updatedAt = Date()
        accounts[index] = record
        persist()
    }

    func remove(accountID: UUID) async throws {
        guard accounts.contains(where: { $0.id == accountID }) else { return }
        let wasActive = currentID == accountID
        let nextAccount = accounts.first { $0.id != accountID }
        accounts.removeAll { $0.id == accountID }
        if wasActive { currentID = nextAccount?.id }
        persist()
        if wasActive {
            await AuthManager.shared.signOut(keepCertificate: true, keepAnisetteData: true)
            if let nextAccount { try await activate(accountID: nextAccount.id, teamIdentifier: nextAccount.activeTeamIdentifier) }
        }
    }

    /// 团队列表由调用方在成功登录后刷新（Developer Portal 返回的 teams）。
    func updateTeams(email: String, teams: [TNBTeamRecord]) {
        guard let index = accounts.firstIndex(where: {
            $0.email.caseInsensitiveCompare(email) == .orderedSame
        }) else { return }
        var merged = accounts[index].teams
        for team in teams where !merged.contains(where: { $0.identifier == team.identifier }) {
            merged.append(team)
        }
        accounts[index].teams = merged
        accounts[index].updatedAt = Date()
        persist()
    }
}

// MARK: - 错误

enum TNVaultError: LocalizedError {
    case accountNotFound
    case missingCertificate
    case missingCredentials
    case invalidTeam
    case invalidBackup

    var errorDescription: String? {
        switch self {
        case .accountNotFound: return "找不到这个 Apple ID 的保存记录。"
        case .missingCertificate: return "这个 Apple ID 还没有保存签名证书。请先登录或导入 p12。"
        case .missingCredentials: return "这个 Apple ID 还没有保存登录凭据。请先登录一次，之后切换无需重新登录。"
        case .invalidTeam: return "团队 ID 应为 10 位大写字母或数字。"
        case .invalidBackup: return "账号配置文件格式不对或密码错误。"
        }
    }
}

extension Notification.Name {
    static let tnbAccountVaultChanged = Notification.Name("tnbAccountVaultChanged")
}
