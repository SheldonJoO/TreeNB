//
//  GlassChrome.swift
//  TreeNB
//
//  全 App 玻璃（导航栏 + Tab 栏）——v3：iOS 26/27 原生 Liquid Glass
//
//  演进：
//  v1 swizzling 往 bar 里插自定义 UIVisualEffectView → 真机穿模（层级压住标题/内容）。
//  v2 改用 UIBarAppearance.backgroundEffect = UIBlurEffect(systemUltraThinMaterial)，
//     不再穿模，但那是 iOS 13 老式毛玻璃，且在 iOS 26+ 上会【覆盖系统原生 Liquid Glass】，
//     所以真机看不到 iOS 27 的玻璃质感。
//  v3 按 Apple《 adopting Liquid Glass》与 iOS 26 适配实践：
//     iOS 26+ 走透明 appearance、不设 backgroundEffect、不给自定义背景色，
//     让 UINavigationBar / UITabBar 自己渲染原生 Liquid Glass（折射/高光/形变）；
//     iOS 15~25 回退 v2 的 UIBlurEffect 毛玻璃，保持旧系统观感。
//
//  说明：UIBarAppearance.backgroundEffect 到 iOS 26 SDK 仍是 UIBlurEffect?，
//        UIGlassEffect 继承 UIVisualEffect、不能直接赋值，故正解是「不覆盖、交给系统」。
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

        // 字面量进二进制，供 assemble_ipa.sh 校验玻璃实现已编入（保留 V2 key 兼容校验）。
        NSLog("[TreeNB] TNB_GLASS_APPEARANCE_V2 installed (v3 liquid glass)")
    }

    /// ShellTabBarController.makeNavigationBarAppearance() 也用这份 appearance，
    /// 避免它自己创建的 opaque appearance 覆盖全局设置。
    static func makeNavigationAppearance() -> UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        // iOS 26+：不设 backgroundEffect / backgroundColor，系统原生 Liquid Glass 生效。
        if #available(iOS 26.0, *) {
            appearance.shadowColor = .clear
        } else {
            appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
            appearance.backgroundColor = .clear
            appearance.shadowColor = .clear
        }
        return appearance
    }

    static func makeTabBarAppearance() -> UITabBarAppearance {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        // iOS 26+：transparent + nil 背景，让系统 Tab 栏渲染原生 Liquid Glass。
        if #available(iOS 26.0, *) {
            appearance.shadowColor = .clear
        } else {
            appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
            appearance.backgroundColor = .clear
            appearance.shadowColor = .clear
        }
        return appearance
    }
}
