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

/// 冷启动接管钩子。必须在 didFinishLaunchingWithOptions 的**最顶部**调用。
/// 若上次容器点按写入了 guest 选择状态（selected 键），本方法会 dlsym
/// LiveContainerMain 并把进程主线权交给 guest —— 正常情况下不会返回；
/// 若 guest 启动失败或没有待启动 guest，则清理状态并返回 NO，App 继续正常启动 openSSS。
/// @return YES 表示已交出进程（调用方不应再继续初始化 UI）；NO 表示正常启动宿主。
+ (BOOL)takeOverIfGuestPending;

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

/// 本地签名一个已 patch 的 guest（ZSign + 证书来自 Keychain）
- (BOOL)signGuestAtPath:(NSString *)appPath error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
