//
//  HuskyEngine.h
//  TreeNB —— Husk 翻译层适配层（独立 framework 入口）
//
//  把 Husk 的 translation-layer-next（纯 C，5.17 万行，脱离 QEMU 独立）封装成
//  ObjC 单例，Swift 侧 `import HuskyEngine` 即可调用，无需主 App bridging header。
//
//  这套运行时不启动 Android、不要 Linux 内核、不要系统镜像：直接在宿主进程里
//  解释 APK 的 DEX + arm64 原生库，图形经 ANGLE → CAMetalLayer。
//  只覆盖有引擎驱动的游戏（Unity/Godot/cocos/SDL/UE4/Flutter/GameMaker 等）；
//  纯 Java 应用需要额外带 java-runtime，当前版本不支持。
//
//  GPL-2.0-or-later：整合进树 App 后，分发版需遵守 GPL 开源义务。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 翻译层状态（对齐 husk-tl-unity-app.h 的 HUSK_UNITY_*）
typedef NS_ENUM(NSInteger, HuskyState) {
    HuskyStateIdle      = 0,
    HuskyStateStarting  = 1,
    HuskyStateRunning   = 2,
    HuskyStateFailed    = 3,
    HuskyStateEnded     = 4
};

@interface HuskyEngine : NSObject

+ (instancetype)shared;

/// 扫描一个或多个 APK（分拆包按主包在前传入），返回 husk_tl_scan 的 JSON 字符串。
/// JSON 含 engine / abis / dexCount / libraries 等字段，Swift 侧据此判断能否运行。
- (NSString *)scanAPKs:(NSArray<NSString *> *)paths;

/// JIT-less 准备：设置预编译 dylib 搜索目录（App Frameworks + 本机转换缓存）。
/// 证书转换本身由 Swift 侧复用树 App 的 p12 链路完成后，把目录传进来。
- (void)prepareJITLessWithAOTDirectories:(NSArray<NSString *> *)dirs;

/// 设置游戏可见的共享存储目录（/sdcard）。
- (void)setSharedStorageDirectory:(NSString *)dir;

/// 追加同应用的其它 APK（split / asset pack），launch 前调用，最多 3 个。
- (void)addPackage:(NSString *)apkPath;

/// 启动游戏。engine 是 scan JSON 里的 engine 字符串；metalLayer 是 CAMetalLayer 对象指针。
/// anglePath = libANGLE-shared.dylib 路径；caPath = cacert.pem 路径。
/// 返回 NO 表示已在运行或参数不可用。
- (BOOL)launchAPK:(NSString *)apkPath
           engine:(NSString *)engine
          dataDir:(NSString *)dataDir
       metalLayer:(nonnull void *)metalLayer
            width:(int)width
           height:(int)height
         anglePath:(NSString *)anglePath
            caPath:(NSString *)caPath;

/// 当前状态 / 已加载的 APK 路径（无则 nil）。
- (HuskyState)state;
- (nullable NSString *)loadedAPK;

/// 触控：phase 0=down 1=move 2=up 3=cancel，id 为指针 id。
- (void)touch:(int)phase pointer:(int)pid x:(float)x y:(float)y;
- (void)setPaused:(BOOL)paused;

/// 停止当前游戏并卸载其库。
- (void)unload;

/// 引擎字符串 → 是否能被翻译层原生驱动（对应 TLReport.nativeEngine 的判定）。
/// 返回 YES 表示可运行；NO 表示需要 Java runtime 或不支持。
- (BOOL)engineIsSupported:(NSString *)engine dexCount:(int)dexCount abis:(NSArray<NSString *> *)abis libraries:(NSArray<NSString *> *)libraries;

@end

NS_ASSUME_NONNULL_END
