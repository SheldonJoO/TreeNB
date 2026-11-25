//
//  GlassChrome.swift
//  TreeNB
//
//  全 App 统一「液态玻璃」外观（导航栏 + Tab 栏）。
//
//  背景：CI 使用 Xcode 16.4 / iOS18.5 SDK 编译。iOS26+ 的原生 Liquid Glass
//  只对用 iOS26 SDK 构建的 App 自动生效；旧 SDK 应用即使把 appearance 改成
//  configureWithDefaultBackground，系统仍给不透明背景，真机看不到玻璃。
//  这里不依赖 SwiftUI .glassEffect()，而是给 UINavigationBar / UITabBar
//  直接挂 UIVisualEffectView(.systemUltraThinMaterial)，并把原生背景清空。
//  这样 iOS15~27 都有真实动态毛玻璃，不依赖 SDK 版本。
//

import UIKit
import ObjectiveC

private let tnbGlassBlurTag = 20261125

private enum GlassChromeOnce {
    static let run: Void = {
        GlassChrome.swizzle(UINavigationBar.self, newSelectorName: "tnbGlassNavLayout")
        GlassChrome.swizzle(UITabBar.self, newSelectorName: "tnbGlassTabLayout")
    }()
}

enum GlassChrome {
    /// 在 UIApplicationMain 之前调用一次。用 method swizzling 覆盖所有
    /// UINavigationBar / UITabBar（包括模态弹出的导航控制器），无需逐个改页面。
    static func install() {
        _ = GlassChromeOnce.run
    }

    fileprivate static func swizzle(_ cls: AnyClass, newSelectorName: String) {
        let originalSelector = NSSelectorFromString("layoutSubviews")
        let newSelector = NSSelectorFromString(newSelectorName)
        guard let originalMethod = class_getInstanceMethod(cls, originalSelector),
              let newMethod = class_getInstanceMethod(cls, newSelector) else { return }

        // 若 layoutSubviews 只是从 UIView 继承来的，class_addMethod 会在本机类上
        // 加一个 override，指向我们的实现；再把备用 selector 换成原实现，
        // 于是 swizzled 方法内部调用同名 selector 就是调用系统原实现。
        if class_addMethod(cls, originalSelector,
                           method_getImplementation(newMethod),
                           method_getTypeEncoding(newMethod)) {
            class_replaceMethod(cls, newSelector,
                                method_getImplementation(originalMethod),
                                method_getTypeEncoding(originalMethod))
        } else {
            method_exchangeImplementations(originalMethod, newMethod)
        }
    }

    fileprivate static func attach(to bar: UIView) {
        guard bar.viewWithTag(tnbGlassBlurTag) == nil else { return }

        let blur: UIVisualEffectView
        if #available(iOS 13.0, *) {
            blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        } else {
            blur = UIVisualEffectView(effect: UIBlurEffect(style: .light))
        }
        blur.tag = tnbGlassBlurTag
        blur.isUserInteractionEnabled = false
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.clipsToBounds = true
        blur.layer.cornerRadius = bar is UINavigationBar ? 20 : 22
        if #available(iOS 13.0, *) {
            blur.layer.maskedCorners = bar is UINavigationBar
                ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
        blur.layer.borderWidth = 0.5
        blur.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor

        // 轻微色调层：让毛玻璃在纯色背景上也看得出「玻璃」质感，随深浅模式切换。
        let tint = UIView()
        tint.isUserInteractionEnabled = false
        tint.translatesAutoresizingMaskIntoConstraints = false
        tint.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0, green: 0, blue: 0, alpha: 0.22)
                : UIColor(red: 1, green: 1, blue: 1, alpha: 0.38)
        }
        blur.contentView.addSubview(tint)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor),
            tint.topAnchor.constraint(equalTo: blur.contentView.topAnchor),
            tint.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor),
        ])

        bar.insertSubview(blur, at: 0)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            blur.topAnchor.constraint(equalTo: bar.topAnchor),
            blur.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])

        // 清掉系统自己的不透明背景，否则它会盖在毛玻璃上面。
        if let navigationBar = bar as? UINavigationBar {
            navigationBar.isTranslucent = true
            navigationBar.setBackgroundImage(UIImage(), for: .default)
            navigationBar.shadowImage = UIImage()
        } else if let tabBar = bar as? UITabBar {
            tabBar.isTranslucent = true
            tabBar.backgroundImage = UIImage()
            tabBar.shadowImage = UIImage()
        }
    }
}

extension UINavigationBar {
    @objc(tnbGlassNavLayout)
    fileprivate func tnbGlassNavLayout() {
        // 交换后这里实际调用的是系统原 layoutSubviews。
        tnbGlassNavLayout()
        GlassChrome.attach(to: self)
    }
}

extension UITabBar {
    @objc(tnbGlassTabLayout)
    fileprivate func tnbGlassTabLayout() {
        tnbGlassTabLayout()
        GlassChrome.attach(to: self)
    }
}
