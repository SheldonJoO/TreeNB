//
//  SideStoreCompat.swift
//  TreeNB —— 单包兼容层
//
//  上游 openSSS 的部分源码（CacheAppOperation / CacheResignedMetadataOperation）
//  用 `SideStore.debugLog(...)` 调用日志。在原工程里 `SideStore` 是 target/module 名，
//  所以这是对模块内全局 `debugLog` 的限定调用。TreeNB 把 SideStore 源码直接编进主 App，
//  不再存在名为 SideStore 的 module，于是报 `cannot find 'SideStore' in scope`。
//
//  这里补一个同名 namespace，把调用转发给 SideStore/Core/Logging/SideStoreLogging.swift
//  里的全局 `debugLog`，保持上游源码零改动。
//

import Foundation

// 在文件作用域先捕获全局 debugLog，避免 enum 内同名方法造成递归调用。
private let treeNBGlobalDebugLog: (String) -> Void = { debugLog($0) }

public enum SideStore {
    public static func debugLog(_ text: @autoclosure () -> String) {
        treeNBGlobalDebugLog(text())
    }
}
