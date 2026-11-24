//
//  TNBOSUpdateBlockerView.swift
//  TreeNB —— 屏蔽 iOS 更新（集成进 openSSS「设置 → 高级设置」）
//
//  提供两个 Apple 签名的 tvOS 描述文件，点按后用 Safari 打开在线地址，
//  iOS 会下载描述文件并引导到「设置 → 通用 → VPN 与设备管理」完成安装。
//  Apple 不允许 App 直接安装描述文件，Safari 是唯一合规路径。
//

import Foundation
import UIKit

public final class TNBOSUpdateBlockerView: UITableViewController {

    private struct Profile {
        let title: String
        let detail: String
        let url: String
        let icon: String
    }

    private let profiles: [Profile] = [
        Profile(title: "屏蔽 iOS 更新（爱思版）",
                detail: "爱思助手提供 · 关闭系统自动下载更新",
                url: "https://d-updater.i4.cn/web/mobileconfig/iOS26.mobileconfig",
                icon: "shield.slash"),
        Profile(title: "屏蔽 iOS 更新（尝鲜派版）",
                detail: "尝鲜派提供 · 关闭系统自动下载更新",
                url: "https://media.sunbelife.com/2026-06-04-noota-26.mobileconfig",
                icon: "shield.slash"),
        Profile(title: "体验测试版 iOS",
                detail: "前往 beta.apple.com 注册描述文件",
                url: "https://beta.apple.com/",
                icon: "sparkles")
    ]

    public init() {
        super.init(style: .insetGrouped)
        title = "屏蔽 iOS 更新"
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    public override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "osblock.cell")
    }

    public override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? profiles.count : 1
    }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "描述文件" : "说明"
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "osblock.cell", for: indexPath)
        if indexPath.section == 0 {
            let p = profiles[indexPath.row]
            var cfg = cell.defaultContentConfiguration()
            cfg.text = p.title
            cfg.secondaryText = p.detail
            cfg.secondaryTextProperties.color = .secondaryLabel
            cfg.image = UIImage(systemName: p.icon)
            cell.contentConfiguration = cfg
            cell.accessoryType = .disclosureIndicator
        } else {
            var cfg = cell.defaultContentConfiguration()
            cfg.text = "下载后请前往 设置 → 通用 → VPN 与设备管理 安装，重启后生效。"
            cfg.textProperties.font = .systemFont(ofSize: 13)
            cfg.textProperties.color = .secondaryLabel
            cell.contentConfiguration = cfg
            cell.accessoryType = .none
            cell.selectionStyle = .none
        }
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0, indexPath.row < profiles.count,
              let url = URL(string: profiles[indexPath.row].url) else { return }
        openInSafari(url)
    }

    private func openInSafari(_ url: URL) {
        // 用系统 Safari 打开：mobileconfig 必须由 Safari 下载才能进入描述文件安装流程。
        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                let alert = UIAlertController(title: "无法打开",
                                              message: "请用 Safari 手动打开该描述文件地址。",
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .default))
                self.present(alert, animated: true)
            }
        }
    }
}
