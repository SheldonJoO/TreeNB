//
//  TreeLaunchWidget.swift
//  TreeNB —— 树应用小组件（并入 openSSS AltWidgetBundle）
//
//  并入方式：在 AltWidget/AltWidgetBundle.swift 的 body 里加一行：
//      TreeLaunchWidget()
//  （本文件不含 @main，因为 openSSS 已有唯一 @main AltWidgetBundle）
//
//  显示 TreeNB 容器里侧载的 App。点击统一用 Link 深链（上游 LC 真机验证方案）：
//    openssai://livecontainer-launch?bundle-name=X
//  host 必须是 livecontainer-launch —— guest 前台时 LiveContainer 的 TweakLoader
//  hook 只认这个 host 做 App 切换；用 container-launch 会被静默吞掉（点组件无反应）。
//  两条路径都能精确启动指定 guest：
//    · guest 前台：hook → launchToGuestAppWithURL → 写 selected + 新鲜度标记 → 重启接管
//    · 宿主前台/冷启：SceneDelegate → TNBDeepLinkRouter → launchGuestApp → 重启接管
//  App Intent（Button(intent:)）方案在侧载 widget 上实测点击无响应，已弃用。
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

// MARK: - 点击封装：Link 深链（所有系统统一，上游真机验证方案）

private struct LaunchLabel<Content: View>: View {
    let app: TNBWidgetAppEntry
    let content: Content

    init(app: TNBWidgetAppEntry, @ViewBuilder content: () -> Content) {
        self.app = app
        self.content = content()
    }

    var body: some View {
        Group {
            if let url = app.launchURL {
                Link(destination: url) { content }
            } else {
                content
            }
        }
    }
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
                    // 主屏图标是 60pt；2×2 布局用 60pt 与原生物理尺寸一致。
                    // 行距收紧到 8pt：60 图标 + 2 spacing + 13 文字 ≈ 75pt/tile，
                    // 2 行 + 8 = 158pt 正好塞满 small widget，避免底部文字被裁。
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 8) {
                        ForEach(Array(entry.apps.prefix(4))) { AppTile(app: $0, iconSize: 60) }
                    }
                case .systemMedium:
                    // 4 列每列约 75pt；58pt 图标 + 2 spacing + 13 文字 ≈ 73pt/tile，
                    // 2 行 + 8 = 154pt < 158pt，完整显示不裁切。
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                        ForEach(Array(entry.apps.prefix(8))) { AppTile(app: $0, iconSize: 58) }
                    }
                case .systemLarge:
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(entry.apps) { AppTile(app: $0, iconSize: 58) }
                    }
                case .accessoryCircular:
                    if let app = entry.apps.first {
                        LaunchLabel(app: app) {
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
                            LaunchLabel(app: app) {
                                VStack { appIcon(app); Text(app.name).font(.caption2).lineLimit(1) }
                            }
                        }
                    }
                case .accessoryInline:
                    if let app = entry.apps.first {
                        LaunchLabel(app: app) {
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
    /// 图标边长，默认接近 iOS 主屏原生图标（60pt）。圆角按主屏比例 ≈ 22.37% 缩放。
    var iconSize: CGFloat = 60
    var body: some View {
        LaunchLabel(app: app) { tile }
    }
    private var tile: some View {
        VStack(spacing: 2) {
            if let img = app.image {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.2237))
            } else {
                Image(systemName: "app.fill").resizable().scaledToFit()
                    .frame(width: iconSize, height: iconSize)
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
