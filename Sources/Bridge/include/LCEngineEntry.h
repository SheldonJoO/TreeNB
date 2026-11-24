//
//  LCEngineEntry.h
//  TreeNB —— LiveContainer 引擎适配层（framework 入口）
//
//  背景：上游 main.c 里 LiveContainerMain() 是进程主入口，会抢 UIApplicationMain。
//  TreeNB 反转主从后，openSSS 才是主 executable，本文件提供一组"被宿主调用"的入口：
//    · TNBEngineBootstrap  —— 初始化 LC 引擎（App Group / Keychain / 路径），不抢主循环
//    · TNBLaunchGuestApp   —— 启动一个 guest（内部仍走 invokeAppMain 进程接管）
//    · TNBInstallIPA       —— 导入 IPA 到容器
//    · TNBListInstalledApps—— 列出已安装 guest
//    · TNBSignGuestApp     —— 对 patch 后的 guest 做本地签名（走 ZSign）
//
//  这些函数是 Objective-C 实现的，Swift 侧通过 module LiveContainerShared 直接调用。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 引擎初始化结果
typedef NS_ENUM(NSInteger, TNBEngineStatus) {
    TNBEngineStatusNotInitialized = 0,
    TNBEngineStatusReady,
    TNBEngineStatusFailed
};

/// guest 启动错误域
FOUNDATION_EXPORT NSErrorDomain const TNBEngineErrorDomain;

/// 安装进度回调。phase: "unzip"/"patch"/"sign"/"install"，progress 0..1
typedef void (^TNBInstallProgress)(NSString *phase, double progress);
typedef void (^TNBInstallCompletion)(BOOL success, NSString *_Nullable appBundlePath, NSError *_Nullable error);

@interface LCEngineEntry : NSObject

/// 单例。宿主 AppDelegate 启动后调用 bootstrap 一次。
+ (instancetype)shared;

/// 冷启动接管钩子。必须在进程 main.swift 里、宿主 UIApplicationMain **之前**调用。
/// 绝不能放到 didFinishLaunchingWithOptions —— 那时 UIApplication 单例已创建，
/// guest 再调一次 UIApplicationMain 会触发 "Dispatch queue already set" 断言闪退。
/// 若上次容器点按写入了 guest 选择状态（selected 键），本方法会 dlsym
/// LiveContainerMain 并把进程主线权交给 guest —— 正常情况下不会返回；
/// 若 guest 启动失败或没有待启动 guest，则清理状态并返回 NO，调用方再启动宿主。
/// @return YES 表示已交出进程（调用方应直接退出，不得再调 UIApplicationMain）；
///         NO 表示调用方应正常启动宿主 openSSS。
+ (BOOL)takeOverIfGuestPending;

/// 幂等补齐 guest 运行前置条件：Documents/Tweaks 目录与 TweakLoader.dylib 软链。
/// 上游只在 LiveContainerSwiftUIApp 的 SwiftUI init 里建这个目录，TreeNB 的 UIKit
/// 主壳从不执行它，导致 symlink() 静默失败、guest dlopen 报 no such file。
+ (void)ensureTweakLoaderSymlink;

/// 首次启动自动导入 App bundle 内置的 JIT-less p12 证书（若用户尚未手动导入）。
+ (void)autoImportBundledCertificateIfNeeded;

/// 自动导入证书后，用该证书把已装 guest 重签一次（异步，不阻塞 UI）。
- (void)autoResignGuestsIfNeeded;

/// 引擎是否已就绪
@property (nonatomic, readonly) TNBEngineStatus status;

/// 初始化引擎：设置 App Group 路径、Keychain group、LCPath 根目录。
/// 必须在任何 guest 操作前调用一次；重复调用幂等。
- (BOOL)bootstrapWithError:(NSError **)error;

/// 启动一个已安装的 guest App。
/// @param bundleName  .app 目录名（对应 LCAppInfo.relativeBundlePath）
/// @param containerFolderName  容器 folderName，nil 表示默认容器
/// @param urlStr  可选的启动 URL（guest 的 url scheme），nil 表示普通启动
/// @param classicMode  0=正常 1=经典模式（注入方式不同），一般传 0
/// @param error  失败原因
/// @return YES 表示已成功把进程主线权交给 guest（此后不会返回到 openSSS UI，直到悬浮键返回）
///
/// 注意：这是 LiveContainer 的本质——guest 全屏运行时宿主 UI 让出主循环。
/// TreeNB 的"无跳转"指的是不再从 openSSS 跳到 *另一个 App*，而是 App 内切 guest 页面。
- (BOOL)launchGuestApp:(NSString *)bundleName
       containerFolder:(nullable NSString *)containerFolderName
              launchURL:(nullable NSString *)urlStr
           classicMode:(NSUInteger)classicMode
                  error:(NSError **)error;

///  guest 通过悬浮键返回后，宿主 AppDelegate 调这个恢复引擎状态
///  （清 LCOpenSideStore 标志、恢复 window、重发 Widget timeline）
- (void)restoreAfterGuestExit;

/// 导入 IPA 到容器。异步，进度/完成都走主线程回调。
- (void)installIPAAtURL:(NSURL *)ipaURL
               progress:(nullable TNBInstallProgress)progress
             completion:(TNBInstallCompletion)completion;

/// 列出已安装的 guest（返回 .app 目录名数组）
- (NSArray<NSString *> *)installedGuestBundleNames;

/// 卸载一个已安装的 guest：删除 .app 目录 + 它的容器数据目录 + 小组件筛选记录。
/// 必须从磁盘真删，否则 installedGuestBundleNames 下次扫描会把它捞回来（"删了又出现"）。
/// @param bundleName  .app 目录名
/// @param error  失败原因
/// @return YES 表示删除完成
- (BOOL)uninstallGuest:(NSString *)bundleName error:(NSError **)error;

/// 本地签名一个已 patch 的 guest（ZSign + 证书来自 Keychain）
- (BOOL)signGuestAtPath:(NSString *)appPath error:(NSError **)error;

#pragma mark - JITLess 证书管理

/// 是否已配置 JIT-less 签名证书（p12 数据 + 密码都在）。
/// 配置后客端启动会跳过 JIT 检测，guest 用该证书 ZSign 重签后即可无 JIT 运行。
+ (BOOL)hasJITLessCertificate;

/// 导入 JIT-less 证书。p12 数据与密码写入 App Group 共享存储（与上游 LCUtils 读取位置一致），
/// 并同时写 standardUserDefaults 兜底。写入后所有已安装 guest 在下次启动时用新证书重签。
/// @param p12Data  .p12 文件的原始字节
/// @param password p12 导入密码
+ (void)importJITLessCertificate:(NSData *)p12Data password:(NSString *)password;

/// 移除 JIT-less 证书（回到需要 JIT 的模式）。
+ (void)removeJITLessCertificate;

/// 对已安装但目前签名无效/未签名的 guest 用当前证书强制重签。
/// 切到 JITLess 模式后调用一次，让之前导入的 app 也能无 JIT 启动。
/// @param completion 主线程回调，success=是否全部成功，detail=结果描述
+ (void)resignAllGuestsWithCompletion:(void (^)(BOOL success, NSString *detail))completion;

@end

NS_ASSUME_NONNULL_END
