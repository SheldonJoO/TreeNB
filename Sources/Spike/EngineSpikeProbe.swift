//
//  EngineSpikeProbe.swift
//  TreeNB —— 三问验证探针（Spike 阶段专用）
//
//  对应设计文档 §5 的三个问题：
//    Q1 主壳能起来吗   → probeHostShell()：openSSS Shell 起来后打印 Tab 数
//    Q2 引擎能内嵌吗   → probeEngineSymbols()：dlsym 能否拿到 LiveContainerMain
//    Q3 guest 能往返吗 → probeGuestRoundTrip()：启动→返回闭环
//
//  ★ 无需 Mac 控制台：结果存进 ProbeReport 单例，SpikeResultView 在 App 内直接显示红绿勾，
//    还能一键复制报告文本。只需把 IPA 装到真机、打开 App。
//
//  用法（二选一）：
//    A. 在 AppDelegate.didFinishLaunchingWithOptions 末尾调 EngineSpikeProbe.runSafeProbes()
//    B. 真机装包后，进容器 Tab 右上角「🧪 自检」入口手动跑（见 SpikeResultView）
//
//  ⚠️ 诊断工具，正式包用 #if DEBUG || TNB_SPIKE 门禁，不进 Release。
//

import Foundation
import UIKit
import SwiftUI
import LiveContainerShared

#if DEBUG || TNB_SPIKE

// MARK: - 结果模型

public struct ProbeResult: Identifiable {
    public let id = UUID()
    public let question: String
    public let detail: String
    public let passed: Bool
}

public final class ProbeReport: ObservableObject {
    public static let shared = ProbeReport()
    @Published public private(set) var results: [ProbeResult] = []
    @Published public private(set) var finishedAt: Date? = nil

    public func add(question: String, detail: String, passed: Bool) {
        DispatchQueue.main.async {
            self.results.append(ProbeResult(question: question, detail: detail, passed: passed))
            self.finishedAt = Date()
        }
    }
    public func reset() {
        DispatchQueue.main.async {
            self.results.removeAll()
            self.finishedAt = nil
        }
    }
    public var allPassed: Bool { !results.isEmpty && results.allSatisfy { $0.passed } }
    public var text: String {
        var lines = ["===== TreeNB Spike 自检报告 =====",
                     "时间: \(finishedAt.map { "\($0)" } ?? "未完成")"]
        for r in results { lines.append("\(r.passed ? "✅" : "❌") \(r.question): \(r.detail)") }
        lines.append(allPassed ? "结论: 全部通过，可写业务代码" : "结论: 未全绿，按 docs/Spike验证指南.md 处理")
        return lines.joined(separator: "\n")
    }
}

// MARK: - 探针

public enum EngineSpikeProbe {

    /// Q1：主壳是否正常（Tab 数应为 4）
    public static func probeHostShell() {
        let tabs = UIApplication.shared.windows.first?.rootViewController as? UITabBarController
        let count = tabs?.viewControllers?.count ?? -1
        let detail = "Tab 数 = \(count)（期望 4：Apps/定位/容器/我的）"
        ProbeReport.shared.add(question: "Q1 主壳能起来", detail: detail, passed: count == 4)
        log("Q1 \(detail) \(count == 4 ? "✅" : "❌")")
    }

    /// Q2：LC 引擎符号可解析 + bootstrap
    public static func probeEngineSymbols() {
        let names = ["LiveContainerMain"]
        var allOK = true
        var details: [String] = []
        for n in names {
            let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), n)
            let ok = p != nil
            allOK = allOK && ok
            details.append("\(n)=\(ok ? "✅" : "❌")")
        }
        var err: NSError?
        let bootOK = LCEngineEntry.shared().bootstrapWithError(&err)
        allOK = allOK && bootOK
        details.append("bootstrap=\(bootOK ? "✅" : "❌ \(err?.localizedDescription ?? "")")")
        let detail = details.joined(separator: ", ")
        ProbeReport.shared.add(question: "Q2 引擎能内嵌", detail: detail, passed: allOK)
        log("Q2 \(detail)")
    }

    /// Q3：guest 往返（需先安装一个最小 guest）
    public static func probeGuestRoundTrip(bundle: String) {
        var err: NSError?
        let ok = LCEngineEntry.shared().launchGuestApp(
            bundle, containerFolder: nil, launchURL: nil, classicMode: 0, error: &err)
        if ok {
            ProbeReport.shared.add(question: "Q3 guest 启动", detail: "已交给 guest，返回后确认闭环", passed: true)
            // guest 退出通知到达后追加"返回"结果
            NotificationCenter.default.addObserver(
                forName: Notification.Name("TNBGuestDidExitNotification"), object: nil, queue: .main) { _ in
                ProbeReport.shared.add(question: "Q3 guest 返回", detail: "收到返回通知，往返闭环成立", passed: true)
                log("Q3 guest 返回通知 ✅")
            }
        } else {
            ProbeReport.shared.add(question: "Q3 guest 启动", detail: err?.localizedDescription ?? "启动失败", passed: false)
        }
    }

    /// 安全探针 Q1+Q2（不碰 guest），可放 didFinishLaunching 末尾
    public static func runSafeProbes() {
        ProbeReport.shared.reset()
        log("===== TreeNB Spike 开始 =====")
        // 延迟到 UI 挂载后跑，确保 window.rootViewController 已就绪
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            probeHostShell()
            probeEngineSymbols()
        }
    }

    private static func log(_ s: String) { print("[TNB-SPIKE] \(s)") }
}

// MARK: - App 内可视化面板（无需控制台）

public struct SpikeResultView: View {
    @ObservedObject private var report = ProbeReport.shared
    @State private var guestBundle = ""
    @State private var showCopy = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(report.results) { r in
                        HStack(alignment: .top) {
                            Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(r.passed ? .green : .red)
                            VStack(alignment: .leading) {
                                Text(r.question).font(.headline)
                                Text(r.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if report.results.isEmpty {
                        Text("还没跑探针，点右上角「运行 Q1+Q2」")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("三问结果")
                }

                Section("Q3 guest 往返（需先装一个最小 guest）") {
                    TextField("guest .app 目录名，如 Demo.app", text: $guestBundle)
                    Button("启动 guest 测往返") {
                        if !guestBundle.isEmpty { EngineSpikeProbe.probeGuestRoundTrip(bundle: guestBundle) }
                    }
                }

                Section {
                    Button("复制报告文本") {
                        UIPasteboard.general.string = report.text
                        showCopy = true
                    }
                }
            }
            .navigationTitle("🧪 Spike 自检")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("运行 Q1+Q2") { EngineSpikeProbe.runSafeProbes() }
                }
            }
            .alert("报告已复制到剪贴板", isPresented: $showCopy) {
                Button("好", role: .cancel) {}
            }
            .onAppear { if report.results.isEmpty { EngineSpikeProbe.runSafeProbes() } }
        }
    }
}

#endif
