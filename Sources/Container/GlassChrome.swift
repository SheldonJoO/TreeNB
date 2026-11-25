//
//  GlassChrome.swift
//  TreeNB
//
//  全 App 毛玻璃（导航栏 + Tab 栏）——v2
//
//  v1 用 method swizzling 往 UINavigationBar / UITabBar 里 insertSubview
//  挂自定义 UIVisualEffectView。真机出现「穿模」：自定义 blur 的 frame 跟随
//  bar 的 layoutSubviews 变化，覆盖到大标题区域且层级压住标题/内容，
//  同时 appearance 被清空后系统不再提供背景，视觉上反而没有玻璃。
//
//  v2 不再碰 bar 的子视图层级，直接用系统 UIBarAppearance.backgroundEffect：
//  UINavigationBar / UITabBar 自己按这个 effect 生成并管理背景 UIVisualEffectView，
//  标题、按钮、内容都在正确层级之上，不会穿模；iOS 13~27 都有真实动态毛玻璃。
//  不依赖 iOS 26 SDK 的 .glassEffect()。
//

import UIKit

enum GlassChrome {
    /// 在 UIApplicationMain 之前调用一次。只设置 UIAppearance 代理，
    /// 不 swizzle、不插子视图，所有 bar（含模态弹出的导航控制器）统一生效。
    static func install() {
        let nav = makeNavigationAppearance()
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav

        let tab = makeTabBarAppearance()
        UITabBar.appearance().standardAppearance = tab
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = tab
        }

        // 字面量进二进制，供 assemble_ipa.sh 校验 v2 已编入。
        NSLog("[TreeNB] TNB_GLASS_APPEARANCE_V2 installed")
    }

    /// ShellTabBarController.makeNavigationBarAppearance() 也用这份appearance，
    /// 避免它自己创建的 opaque appearance 覆盖全局设置。
    static func makeNavigationAppearance() -> UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        appearance.backgroundColor = .clear
        appearance.shadowColor = .clear
        return appearance
    }

    static func makeTabBarAppearance() -> UITabBarAppearance {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        appearance.backgroundColor = .clear
        appearance.shadowColor = .clear
        return appearance
    }
}
