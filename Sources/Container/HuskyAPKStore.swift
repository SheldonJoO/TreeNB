//
//  HuskyAPKStore.swift
//  TreeNB —— Husk 翻译层 APK 管理
//
//  负责：导入 APK 到 App 文档目录、调用翻译层扫描引擎、判断是否可运行、
//  提供每个游戏的数据目录。纯数据层，UI 在 HuskyAPKView。
//

import Foundation
import UIKit
import HuskyEngine

/// 一个已导入的 APK（及其分拆包）。
struct HuskyApp: Identifiable {
    let id: String          // 目录名
    let apks: [String]      // 主包在前
    var label: String
    var engine: String
    var supported: Bool
    var detail: String

    var mainAPK: String { apks.first ?? "" }
}

/// APK 扫描结果里的关键字段（husk_tl_scan 的 JSON）。
private struct ScanReport: Decodable {
    let engine: String?
    let ok: Bool?
    let abis: [String]?
    let dexCount: Int?
    let libraries: [ScanLib]?
    let verdict: String?
    let summary: String?

    struct ScanLib: Decodable {
        let name: String?
    }
}

final class HuskyAPKStore: ObservableObject {
    static let shared = HuskyAPKStore()

    @Published private(set) var apps: [HuskyApp] = []

    /// APK 存放根目录（Documents/HuskyAPKs/<id>/）。
    private var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("HuskyAPKs", isDirectory: true)
    }

    private init() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    /// 扫描 result.json 得到引擎/支持状态。
    private func describe(apks: [String]) -> (engine: String, supported: Bool, detail: String) {
        let json = HuskyEngine.shared.scanAPKs(apks)
        guard let data = json.data(using: .utf8),
              let report = try? JSONDecoder().decode(ScanReport.self, from: data) else {
            return ("未知", false, "无法解析 APK 信息")
        }
        let engine = report.engine ?? "Java"
        let abis = report.abis ?? []
        let libs = report.libraries?.compactMap { $0.name } ?? []
        // ObjC int 导入 Swift 为 Int32，需显式转换（dexCount 在 wrapper 是 int）。
        let dex = Int32(report.dexCount ?? 0)
        let supported = HuskyEngine.shared.engineIsSupported(engine, dexCount: dex, abis: abis, libraries: libs)
        let detail = supported ? (report.summary ?? engine) : Self.unsupportedReason(engine: engine, abis: abis, dexCount: dex)
        return (engine, supported, detail)
    }

    /// 按扫描结果给出具体原因，避免笼统的「需要 Java 运行时或非 arm 架构」。
    private static func unsupportedReason(engine: String, abis: [String], dexCount: Int32) -> String {
        let hasARM = abis.contains { $0 == "arm64-v8a" || $0 == "armeabi-v7a" || $0 == "armeabi" }
        if !hasARM {
            return abis.isEmpty
                ? "未检测到 native 库（可能是纯 Java 应用），翻译层暂不支持"
                : "仅含 \(abis.joined(separator: "/")) 架构，本翻译层只支持 arm 架构"
        }
        if engine == "Unity 6" {
            return "Unity 6 暂不支持，可尝试 Unity 2022 及更早版本"
        }
        if engine == "Java" || dexCount > 0 {
            return "「\(engine)」需要 Java 运行时，当前引擎暂不支持"
        }
        return "「\(engine)」引擎暂不支持"
    }

    /// 从文件选择器导入一个或多个 APK。返回新导入的 app id。
    @discardableResult
    func importAPKs(from urls: [URL]) -> String? {
        let apkURLs = urls.filter { $0.pathExtension.lowercased() == "apk" }
        guard let first = apkURLs.first else { return nil }

        // 用文件名 + 大小做稳定 id（同一批分拆包共用前缀时归到同一 app）。
        let base = (first.deletingPathExtension().lastPathComponent as NSString)
            .replacingOccurrences(of: " ", with: "_")
        let id = "\(base)-\(first.fileSize)-\(Int(Date().timeIntervalSince1970))"
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var saved: [String] = []
        for (index, url) in apkURLs.enumerated() {
            let name = index == 0 ? "base.apk" : "split\(index).apk"
            let dst = dir.appendingPathComponent(name)
            if url.isFileURL {
                try? FileManager.default.copyItem(at: url, to: dst)
            }
            // 主包优先：base 排第一，其余按序。
            saved.append(dst.path)
        }
        guard !saved.isEmpty else { return nil }

        let info = describe(apks: saved)
        let app = HuskyApp(id: id, apks: saved, label: base,
                           engine: info.engine, supported: info.supported, detail: info.detail)
        // 缓存描述，避免每次列表都重扫（重扫较慢）。
        let meta: [String: Any] = ["label": app.label, "engine": app.engine,
                                   "supported": app.supported, "detail": app.detail]
        try? JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))

        reload()
        return id
    }

    /// 重新读取所有已导入 app。
    func reload() {
        var result: [HuskyApp] = []
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs where dir.isDir {
            let apks = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension.lowercased() == "apk" }
                .sorted { a, b in
                    if a.lastPathComponent == "base.apk" { return true }
                    if b.lastPathComponent == "base.apk" { return false }
                    return a.lastPathComponent < b.lastPathComponent
                }
                .map { $0.path } ?? []
            guard !apks.isEmpty else { continue }

            var label = dir.lastPathComponent
            var engine = "未知"
            var supported = false
            var detail = ""
            if let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
               let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                label = meta["label"] as? String ?? label
                engine = meta["engine"] as? String ?? engine
                supported = meta["supported"] as? Bool ?? false
                detail = meta["detail"] as? String ?? ""
                // 迁移：旧版缓存的是笼统文案，重扫一次换成具体原因并回写。
                if detail == "当前不支持：需要 Java 运行时或非 arm 架构" {
                    let info = describe(apks: apks)
                    engine = info.engine; supported = info.supported; detail = info.detail
                    let fresh: [String: Any] = ["label": label, "engine": engine,
                                               "supported": supported, "detail": detail]
                    try? JSONSerialization.data(withJSONObject: fresh).write(to: dir.appendingPathComponent("meta.json"))
                }
            } else {
                let info = describe(apks: apks)
                engine = info.engine; supported = info.supported; detail = info.detail
            }
            result.append(HuskyApp(id: dir.lastPathComponent, apks: apks, label: label,
                                   engine: engine, supported: supported, detail: detail))
        }
        apps = result.sorted { $0.label < $1.label }
    }

    /// 游戏数据目录。
    func dataDir(for app: HuskyApp) -> String {
        root.appendingPathComponent(app.id, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true).path
    }

    /// JIT-less AOT 缓存目录：APK 里的 arm64 .so 转成签名 dylib 后放这里。
    func aotCacheDir() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("HuskyJITless", isDirectory: true).path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 用当前账号的开发者证书，把 APK 里的 arm64 .so 转成签名 dylib（JIT-less 前提）。
    /// 必须在 launch 前调用。返回 (准备好的库数量, 错误信息)；库数量为 0 且 APK
    /// 本就没有 .so 时也算成功（纯 DEX 不走原生库），由调用方结合引擎判断。
    func prepareAOT(apkPaths: [String]) -> (ready: Int, error: String?) {
        // 主 App 的签名证书：与侧载 TreeNB 用的是同一张，team 天然匹配。
        let cm = CertificateManager.shared
        let active = cm.activeCertificate ?? (try? cm.loadActiveCertificate())
        guard let active, !active.p12Data.isEmpty else {
            return (0, "没有可用的签名证书。请先到「我的 → 证书」重置为当前账号证书。")
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.openssai.app"
        var err: NSString? = nil
        // ObjC 的 prepareAOTForAPKs: 被 Swift 3 导入为 prepareAOT(forAPKs:)
        // （For 当作介词拆分），返回 int 导入为 Int32，需显式转 Int。
        let ready32 = HuskyEngine.shared.prepareAOT(
            forAPKs: apkPaths,
            cacheDir: aotCacheDir(),
            p12: active.p12Data,
            password: active.password ?? "",
            certTag: active.serialNumber,
            signIdent: bundleID,
            error: &err)
        let ready = Int(ready32)
        if ready < 0 {
            return (0, err as String? ?? "AOT 转换失败")
        }
        // 证书链提取失败时 err 会是警告（ready >= 0），透传给 UI 提示。
        let warning = (err as String?) ?? ""
        return (ready, warning.isEmpty ? nil : warning)
    }

    func remove(_ app: HuskyApp) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(app.id))
        reload()
    }
}

private extension URL {
    var isDir: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
    var fileSize: Int {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }
}
