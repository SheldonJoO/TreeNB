//
//  WidgetSettings.swift
//  TreeNB —— 小组件 App 快照写入 + 手动筛选设置
//
//  背景：小组件（TNBWidgetStore）从 Keychain/App Group 读 TNBWidgetSnapshot，
//  但宿主侧从未实现写入端（原注释里说的 TreeWidgetSnapshotWriterV2.refresh()
//  根本不存在），导致小组件永远显示"暂无侧载应用"。
//
//  本文件补上写入端，并提供筛选 UI：用户勾选哪些容器 App 上小组件。
//  Keychain service/account 必须与 TreeWidgetBridge.swift 的 TNBWidgetStore 完全一致。
//

import Foundation
import UIKit
import SwiftUI
import WidgetKit

// MARK: - 快照写入器

enum TNBWidgetSnapshotWriter {

    /// 手动勾选的 bundleName 列表。空 = 自动模式（显示全部）。
    /// 存 standard + app group，保证 appex 也能读到（如果能读）。
    static let selectionKey = "TNBWidgetSelectedApps"
    static var manualSelection: [String] {
        get {
            let group = UserDefaults(suiteName: "group.openssai.app")?.stringArray(forKey: selectionKey) ?? []
            return group.isEmpty ? (UserDefaults.standard.stringArray(forKey: selectionKey) ?? []) : group
        }
        set {
            UserDefaults.standard.set(newValue, forKey: selectionKey)
            UserDefaults(suiteName: "group.openssai.app")?.set(newValue, forKey: selectionKey)
        }
    }

    /// 扫到的一个候选 App
    struct Scanned {
        let bundleName: String   // .app 目录名（= 启动 selected 键）
        let name: String
        let iconData: String?
    }

    /// 扫描容器里已安装的 guest App（只扫 TreeNB 自己装的目录）
    static func scanInstalledApps() -> [Scanned] {
        let fm = FileManager.default
        var roots: [URL] = []
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            roots.append(docs.appendingPathComponent("Applications", isDirectory: true))
        }
        for gid in ["group.openssai.app", "group.com.SideStore.SideStore"] {
            if let g = fm.containerURL(forSecurityApplicationGroupIdentifier: gid) {
                roots.append(g.appendingPathComponent("LiveContainer/Applications", isDirectory: true))
            }
        }

        var seen = Set<String>()
        var result: [Scanned] = []
        for root in roots {
            let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            for dir in names where dir.lowercased().hasSuffix(".app") {
                guard !seen.contains(dir) else { continue }
                let appURL = root.appendingPathComponent(dir)
                guard fm.fileExists(atPath: appURL.appendingPathComponent("Info.plist").path) else { continue }
                seen.insert(dir)

                let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")) as? [String: Any]
                let name = (info?["CFBundleDisplayName"] as? String)
                    ?? (info?["CFBundleName"] as? String)
                    ?? (dir as NSString).deletingPathExtension

                result.append(Scanned(bundleName: dir,
                                      name: name,
                                      iconData: iconBase64(iconData(for: appURL, info: info))))
            }
        }
        return result
    }

    /// 找图标：先 CFBundleIconFile，再 CFBundleIcons 主图标，最后常见默认名
    private static func iconData(for appURL: URL, info: [String: Any]?) -> UIImage? {
        var candidates: [String] = []
        if let f = info?["CFBundleIconFile"] as? String { candidates.append(f) }
        if let icons = info?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
            if let files = primary["CFBundleIconFiles"] as? [String] { candidates.append(contentsOf: files) }
            if let f = primary["CFBundleIconFiles"] as? String { candidates.append(f) }
        }
        candidates.append(contentsOf: ["AppIcon", "Icon", "app"])
        for name in candidates {
            let path = appURL.appendingPathComponent(name).path
            let png = path.hasSuffix(".png") ? path : path + ".png"
            if let img = UIImage(contentsOfFile: png) { return img }
            if let img = UIImage(contentsOfFile: path) { return img }
        }
        return nil
    }

    private static func iconBase64(_ image: UIImage?) -> String? {
        guard let image else { return nil }
        let size = CGSize(width: 72, height: 72)
        let renderer = UIGraphicsImageRenderer(size: size)
        let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return scaled.pngData()?.base64EncodedString()
    }

    /// 重新生成快照并写入 Keychain + App Group，刷新 Widget timeline
    @discardableResult
    static func refresh() -> Int {
        let scanned = scanInstalledApps()
        let manual = Set(manualSelection)
        let automatic = manual.isEmpty

        var entries: [TNBWidgetAppEntry] = []
        var seen = Set<String>()
        for app in scanned {
            guard !seen.contains(app.bundleName) else { continue }
            if !automatic && !manual.contains(app.bundleName) { continue }
            seen.insert(app.bundleName)
            let key = app.bundleName.filter { $0.isLetter || $0.isNumber }
            entries.append(TNBWidgetAppEntry(name: app.name,
                                             bundleName: app.bundleName,
                                             container: "",
                                             icon: "\(key).png",
                                             iconData: app.iconData))
        }

        let snapshot = TNBWidgetSnapshot(version: 1, apps: entries)
        TNBWidgetStore.write(snapshot)
        TNBWidgetStore.writeToAppGroup(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        return entries.count
    }
}

// MARK: - 筛选设置 UI

struct WidgetAppSelectionView: View {
    @State private var apps: [TNBWidgetSnapshotWriter.Scanned] = []
    @State private var selected: Set<String> = []
    @State private var status = ""

    var body: some View {
        Form {
            Section {
                Text("勾选要显示在小组件里的应用。一个都不勾则自动显示全部。保存后小组件会立即刷新。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if apps.isEmpty {
                    Text("还没有检测到容器里安装的应用。请先在容器页导入 IPA。")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(apps, id: \.bundleName) { app in
                        Toggle(isOn: Binding(
                            get: { selected.contains(app.bundleName) },
                            set: { on in
                                if on { selected.insert(app.bundleName) }
                                else { selected.remove(app.bundleName) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).font(.subheadline)
                                Text(app.bundleName).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("已安装的容器应用（\(apps.count)）")
            }
            Section {
                SwiftUI.Button {
                    save()
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("保存并刷新小组件")
                    }
                }
                SwiftUI.Button("恢复自动显示全部") {
                    selected = []
                    TNBWidgetSnapshotWriter.manualSelection = []
                    let n = TNBWidgetSnapshotWriter.refresh()
                    status = "已恢复自动模式，写入 \(n) 个应用"
                }
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("操作")
            }
        }
        .navigationTitle("小组件应用")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apps = TNBWidgetSnapshotWriter.scanInstalledApps()
            selected = Set(TNBWidgetSnapshotWriter.manualSelection)
        }
    }

    private func save() {
        TNBWidgetSnapshotWriter.manualSelection = selected.sorted()
        let n = TNBWidgetSnapshotWriter.refresh()
        status = "已写入 \(n) 个应用，小组件已刷新"
    }
}
