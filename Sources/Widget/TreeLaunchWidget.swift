//
//  TreeLaunchWidget.swift
//  TreeNB —— 树应用小组件（并入 openSSS AltWidgetBundle）
//
//  并入方式：在 AltWidget/AltWidgetBundle.swift 的 body 里加一行：
//      TreeLaunchWidget()
//  （本文件不含 @main，因为 openSSS 已有唯一 @main AltWidgetBundle）
//
//  显示 TreeNB 容器里侧载的 App，点击 openssai://container-launch 深链启动。
//  从上游 TreeWidget.swift (~400 行) 精简：保留 Grid/锁屏样式、Keychain 主通道、
//  App Group 兜底，去掉诊断面板等调试代码。
//

import SwiftUI
import WidgetKit

// MARK: - Timeline

struct TreeLaunchProvider: TimelineProvider {
    func placeholder(in context: Context) -> TreeLaunchEntry {
        TreeLaunchEntry(date: Date(), apps: [])
    }
    func getSnapshot(in context: Context, completion: @escaping (TreeLaunchEntry) -> Void) {
        completion(TreeLaunchEntry(date: Date(), apps: load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TreeLaunchEntry>) -> Void) {
        let entry = TreeLaunchEntry(date: Date(), apps: load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
    private func load() -> [TNBWidgetAppEntry] {
        if let snapshot = TNBWidgetStore.read(), !snapshot.apps.isEmpty {
            return Array(snapshot.apps.prefix(12))
        }
        // App Group 兜底
        for gid in ["group.openssai.app", "group.com.SideStore.SideStore"] {
            guard let root = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: gid)?
                .appendingPathComponent("TreeWidget/apps.json"),
                  let data = try? Data(contentsOf: root),
                  let snapshot = try? JSONDecoder().decode(TNBWidgetSnapshot.self, from: data),
                  !snapshot.apps.isEmpty else { continue }
            return Array(snapshot.apps.prefix(12))
        }
        return []
    }
}

struct TreeLaunchEntry: TimelineEntry {
    let date: Date
    let apps: [TNBWidgetAppEntry]
}

// MARK: - Views

struct TreeLaunchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TreeLaunchEntry

    var body: some View {
        Group {
            if entry.apps.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "tree.fill").font(.title3).foregroundStyle(.green)
                    Text("树应用：暂无侧载应用").font(.caption2).multilineTextAlignment(.center)
                }
            } else {
                switch family {
                case .systemSmall:
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 10) {
                        ForEach(Array(entry.apps.prefix(4))) { AppTile(app: $0) }
                    }
                case .systemMedium:
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(Array(entry.apps.prefix(8))) { AppTile(app: $0) }
                    }
                case .systemLarge:
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 16) {
                        ForEach(entry.apps) { AppTile(app: $0) }
                    }
                case .accessoryCircular:
                    if let app = entry.apps.first, let url = app.launchURL {
                        Link(destination: url) {
                            ZStack {
                                AccessoryWidgetBackground()
                                if let img = app.image {
                                    Image(uiImage: img).resizable().scaledToFit().padding(8)
                                } else {
                                    Image(systemName: "tree.fill")
                                }
                            }
                        }
                    }
                case .accessoryRectangular:
                    HStack(spacing: 8) {
                        ForEach(Array(entry.apps.prefix(3))) { app in
                            if let url = app.launchURL {
                                Link(destination: url) {
                                    VStack { appIcon(app); Text(app.name).font(.caption2).lineLimit(1) }
                                }
                            }
                        }
                    }
                case .accessoryInline:
                    if let app = entry.apps.first {
                        Link(destination: app.launchURL ?? URL(string: "openssai://")!) {
                            Label(app.name, systemImage: "tree.fill")
                        }
                    }
                default:
                    EmptyView()
                }
            }
        }
        .modifier(WidgetBackground())
    }

    @ViewBuilder
    private func appIcon(_ app: TNBWidgetAppEntry) -> some View {
        if let img = app.image {
            Image(uiImage: img).resizable().scaledToFit().frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        } else {
            Image(systemName: "app.fill").frame(width: 32, height: 32)
        }
    }
}

private struct AppTile: View {
    let app: TNBWidgetAppEntry
    var body: some View {
        Group {
            if let url = app.launchURL {
                Link(destination: url) { tile }
            } else { tile }
        }
    }
    private var tile: some View {
        VStack(spacing: 4) {
            if let img = app.image {
                Image(uiImage: img).resizable().scaledToFit().frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "app.fill").resizable().scaledToFit().frame(width: 36, height: 36)
                    .foregroundStyle(.tint)
            }
            Text(app.name).font(.caption2).lineLimit(1).foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct WidgetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.containerBackground(for: .widget) { Color(.systemBackground) }
        } else { content }
    }
}

// MARK: - Widget 定义（无 @main）

struct TreeLaunchWidget: Widget {
    let kind = "com.openssai.app.treeLaunchWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TreeLaunchProvider()) { entry in
            TreeLaunchWidgetView(entry: entry)
        }
        .configurationDisplayName("🌲树应用")
        .description("一键打开树应用容器中已安装的应用")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
