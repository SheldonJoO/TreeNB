//
//  LCEngineEntry.m
//  TreeNB —— LiveContainer 引擎适配层实现
//
//  这是"进程接管式引擎"变成"可嵌入库"的关键胶水。设计要点：
//   1. 不在 +load 里做任何 swizzle —— 上游 LCBootstrap 的 UIApplication/NSBundle
//      swizzle 必须延迟到 launchGuestApp 时才安装，避免污染宿主 openSSS 的启动。
//   2. invokeAppMain 是 LC 内部 static 函数，无法直接调；这里通过设置
//      LCUserDefaults 的选择状态 + 调用 dlsym 到的 LiveContainerMain 间接触发。
//      真正的 guest 入口复用上游 LCBootstrap.m:749 的 LiveContainerMain。
//   3. 宿主冲突隔离：guest 退出后 restoreAfterGuestExit 负责把被 swizzle 的
//      NSBundle.mainBundle / UIApplication 状态还原到 openSSS。
//

#import "LCEngineEntry.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#include <archive.h>
#include <archive_entry.h>
#include <time.h>

NSErrorDomain const TNBEngineErrorDomain = @"com.openssai.app.LCEngineError";

// 上游 LCSharedUtils.h 暴露的接口（framework 内可见）。
// launchToGuestAppWithClassicMode: 是 guest 启动的正解：它会按是否有 JIT /
// TrollStore 决定用 LSApplicationWorkspace 重启 App 并 SIGKILL 自己，
// 重启后由 AppDelegate 冷启动钩子调 LiveContainerMain 接管进程跑 guest。
@interface LCSharedUtils : NSObject
+ (NSURL *)appGroupPath;
+ (NSString *)appGroupID;
+ (NSString *)certificatePassword;
+ (NSString *)teamIdentifier;
+ (BOOL)launchToGuestAppWithClassicMode:(NSUInteger)classicMode;
+ (NSString *)findDefaultContainerWithBundleId:(NSString *)bundleId;
@end

// 上游 LiveContainerMain(int argc, char *argv[]) —— 通过 dlsym 拿到
typedef int (*TNBLCMainFn)(int, char **);

// LCAppInfo 在 LiveContainerSwiftUI.framework 里（主 App 已 link）。
// 这里用 protocol + NSClassFromString 调用，避免 LiveContainerShared 反向依赖 SwiftUI framework。
@protocol TNBLCAppInfoBridge <NSObject>
- (id)initWithBundlePath:(NSString *)bundlePath;
- (NSString *)bundleIdentifier;
- (NSString *)dataUUID;
- (void)setDataUUID:(NSString *)uuid;
- (void)setRelativeBundlePath:(NSString *)path;
- (BOOL)is32bit;
- (BOOL)isJITNeeded;
- (NSUInteger)defaultClassicMode;
- (void)save;
- (void)patchExecAndSignIfNeedWithCompletionHandler:(void (^)(bool success, NSString *errorInfo))completionHandler
                                    progressHandler:(void (^)(NSProgress *progress))progressHandler
                                           forceSign:(BOOL)forceSign;
@end

// IPA 解压。IPA 就是 zip（Payload/*.app），复用上游 unarchive.m 的 libarchive 参数，
// 但加上路径清洗，避免恶意 IPA 用 ../ 写到容器外。
static int TNBExtractIPAAtPath(NSString *ipaPath, NSString *destPath, void (^progress)(double fraction)) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:destPath withIntermediateDirectories:YES attributes:nil error:nil];

    int64_t total = 0;
    int64_t done = 0;
    int flags = ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_ACL | ARCHIVE_EXTRACT_FFLAGS;

    struct archive *a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    if (archive_read_open_filename(a, ipaPath.fileSystemRepresentation, 10240) != ARCHIVE_OK) {
        archive_read_free(a);
        return 1;
    }
    struct archive_entry *entry = NULL;
    // 第一遍只统计字节数，供进度条使用
    while (archive_read_next_header(a, &entry) != ARCHIVE_EOF) {
        total += archive_entry_size(entry);
    }
    archive_read_close(a);
    archive_read_free(a);

    // 第二遍实际解压
    a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    if (archive_read_open_filename(a, ipaPath.fileSystemRepresentation, 10240) != ARCHIVE_OK) {
        archive_read_free(a);
        return 1;
    }
    int result = 0;
    while (archive_read_next_header(a, &entry) != ARCHIVE_EOF) {
        const char *raw = archive_entry_pathname(entry);
        if (!raw) { archive_read_data_skip(a); continue; }
        NSString *rel = [NSString stringWithUTF8String:raw] ?: @"";
        // 跳过 macOS 资源分支文件
        if ([rel hasPrefix:@"__MACOSX/"] || [rel.lastPathComponent hasPrefix:@"._"]) {
            archive_read_data_skip(a);
            continue;
        }
        // 去掉绝对路径与 .. 分量，确保只能写到 destPath 内
        NSMutableArray *safe = [NSMutableArray array];
        for (NSString *part in [rel componentsSeparatedByString:@"/"]) {
            if (part.length == 0 || [part isEqualToString:@"."] || [part isEqualToString:@".."]) { continue; }
            [safe addObject:part];
        }
        rel = [safe componentsJoinedByString:@"/"];
        if (rel.length == 0) { archive_read_data_skip(a); continue; }
        archive_entry_set_pathname(entry, [destPath stringByAppendingPathComponent:rel].fileSystemRepresentation);

        if (archive_read_extract(a, entry, flags) != ARCHIVE_OK) {
            NSLog(@"[TreeNB] 解压条目失败: %@", rel);
            result = 1;
            break;
        }
        done += archive_entry_size(entry);
        if (progress) { progress(total > 0 ? (double)done / (double)total : 0.5); }
    }
    archive_read_close(a);
    archive_read_free(a);
    return result;
}

static NSString *TNBSanitizedBundleName(NSString *identifier) {
    if (identifier.length == 0) { return nil; }
    NSMutableString *out = [NSMutableString stringWithCapacity:identifier.length];
    for (NSUInteger i = 0; i < identifier.length; i++) {
        unichar c = [identifier characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-') {
            [out appendFormat:@"%C", c];
        }
    }
    return out.length ? [out copy] : nil;
}

@interface LCEngineEntry ()
@property (nonatomic, assign) TNBEngineStatus status;
@property (nonatomic, strong) NSURL *bundleRoot;       // Documents/Applications
@property (nonatomic, strong) NSURL *groupBundleRoot;  // AppGroup/LiveContainer/Applications
@property (nonatomic, assign) BOOL swizzledForGuest;
@end

@implementation LCEngineEntry

+ (instancetype)shared {
    static LCEngineEntry *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

#pragma mark - Guest 运行前置条件（TweakLoader symlink + 证书自动导入）

/// 上游只在 LiveContainerSwiftUIApp（SwiftUI App 入口）里创建 Documents/Tweaks；
/// TreeNB 主壳是 openSSS 的 UIKit App，那段 SwiftUI init 从不执行，导致
/// LCBootstrap.m 的 symlink() 因父目录不存在而静默失败 → guest dlopen
/// "@loader_path/../../Tweaks/TweakLoader.dylib" 报 no such file。
/// 由宿主在每次冷启动/常规启动时幂等补齐目录与软链。
+ (void)ensureTweakLoaderSymlink {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs.length) { return; }

    NSString *target = [[NSBundle mainBundle].bundlePath
        stringByAppendingPathComponent:@"Frameworks/TweakLoader.dylib"];
    if (![fm fileExistsAtPath:target]) {
        NSLog(@"[TreeNB] 严重：包内缺少 Frameworks/TweakLoader.dylib，guest 无法启动");
        [[NSUserDefaults standardUserDefaults] setObject:@"包内缺少 TweakLoader.dylib，请重装完整包"
                                                 forKey:@"TNBLastGuestLaunchError"];
        return;
    }

    // guest 的 @loader_path/../../Tweaks 解析到 Documents/Tweaks；
    // isSharedBundle 分支解析到 App Group/LiveContainer/Tweaks，一并补齐。
    NSMutableArray<NSString *> *tweakFolders = [NSMutableArray array];
    [tweakFolders addObject:[docs stringByAppendingPathComponent:@"Tweaks"]];
    NSURL *groupRoot = [fm containerURLForSecurityApplicationGroupIdentifier:@"group.openssai.app"];
    if (!groupRoot) { groupRoot = [LCSharedUtils appGroupPath]; }
    if (groupRoot) {
        [tweakFolders addObject:[[groupRoot URLByAppendingPathComponent:@"LiveContainer/Tweaks"] path]];
    }

    for (NSString *folder in tweakFolders) {
        [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *link = [folder stringByAppendingPathComponent:@"TweakLoader.dylib"];
        NSString *current = [fm destinationOfSymbolicLinkAtPath:link error:nil];
        BOOL linkOK = [current isEqualToString:target] && [fm fileExistsAtPath:link];
        if (!linkOK) {
            [fm removeItemAtPath:link error:nil];
            NSError *err = nil;
            if (![fm createSymbolicLinkAtPath:link withDestinationPath:target error:&err]) {
                NSLog(@"[TreeNB] TweakLoader symlink 建立失败 %@: %@", link, err.localizedDescription);
            } else {
                NSLog(@"[TreeNB] TweakLoader symlink 已建立 -> %@", target);
            }
        }
    }
}

/// 证书自动导入（team 感知）：
/// JITLess 要求 guest 必须用与宿主 App **完全相同 team** 的证书重签，否则签出来的
/// application-identifier / entitlements 与宿主不匹配 → dyld library validation 失败
/// → signal 级崩溃、走不到 OC 异常处理器（表现就是"闪退且无错误代码"）。
///
/// 打包时把若干 p12 注入 App bundle，文件名带 team：
///   TreeNBSigningCertificate-<TEAM>.p12，例如 TreeNBSigningCertificate-UBKLUGLLLK.p12
/// 启动时读取宿主实际签名 team（SecTaskCopyValueForEntitlement），优先选对应文件；
/// 若用户频繁换证书导致多个文件都在，只选 team 匹配的那个，避免又用错旧证书。
/// 检测到已导入证书的字节与应选证书不同，会自动刷新并重签。
+ (void)autoImportBundledCertificateIfNeeded {
    NSString *team = [LCSharedUtils teamIdentifier];
    NSLog(@"[TreeNB] 宿主签名 team=%@，开始匹配内置证书", team ?: @"(未知)");

    NSBundle *bundle = NSBundle.mainBundle;
    NSString *path = nil;
    // 1) 精确匹配 team 的证书
    if (team.length) {
        path = [bundle pathForResource:[NSString stringWithFormat:@"TreeNBSigningCertificate-%@", team]
                               ofType:@"p12"];
    }
    // 2) 兜底：无 team 信息时用通用名（老包兼容）
    if (!path.length) {
        path = [bundle pathForResource:@"TreeNBSigningCertificate" ofType:@"p12"];
    }
    // 3) 再兜底：bundle 里任意 TreeNBSigningCertificate-*.p12 取第一个
    if (!path.length) {
        for (NSString *p in [bundle pathsForResourcesOfType:@"p12" inDirectory:nil]) {
            if ([[p lastPathComponent] hasPrefix:@"TreeNBSigningCertificate"]) { path = p; break; }
        }
    }
    if (!path.length) { NSLog(@"[TreeNB] 未找到任何内置证书"); return; }

    NSData *p12 = [NSData dataWithContentsOfFile:path];
    if (!p12.length) { return; }

    // 已导入的就是目标证书（且 team 没变）→ 不重复导入、不重签。
    NSData *existing = [[self tnb_certDefaults] objectForKey:kTNBKeyCertData] ?:
                       [NSUserDefaults.standardUserDefaults objectForKey:kTNBKeyCertData];
    NSString *boundTeam = [[NSUserDefaults standardUserDefaults] stringForKey:@"TNBCertBoundTeam"];
    if ([existing isEqualToData:p12] && [boundTeam isEqualToString:team ?: @""]) {
        NSLog(@"[TreeNB] 内置证书未变化，跳过导入");
        return;
    }

    [self importJITLessCertificate:p12 password:@""];
    [[NSUserDefaults standardUserDefaults] setObject:(team ?: @"") forKey:@"TNBCertBoundTeam"];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"TNBAutoResignPending"];
    NSLog(@"[TreeNB] 已自动导入内置证书 %@ (%lu bytes)",
          [path lastPathComponent], (unsigned long)p12.length);
}

/// 自动导入证书后的首次启动，用该证书把已装 guest 重签一次（异步，不阻塞 UI）。
- (void)autoResignGuestsIfNeeded {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (![d boolForKey:@"TNBAutoResignPending"]) { return; }
    [d removeObjectForKey:@"TNBAutoResignPending"];
    NSArray<NSString *> *guests = [self installedGuestBundleNames] ?: @[];
    if (guests.count == 0) { return; }
    [LCEngineEntry resignAllGuestsWithCompletion:^(BOOL success, NSString *detail) {
        NSLog(@"[TreeNB] 自动重签结果: %@ / %@", success ? @"OK" : @"FAIL", detail);
        if (!success) {
            [[NSUserDefaults standardUserDefaults]
                setObject:[NSString stringWithFormat:@"证书自动重签失败：%@", detail]
                   forKey:@"TNBLastGuestLaunchError"];
        }
    }];
}

#pragma mark - Host launch overrides

// 从宿主 Info.plist 安全取第一个 URL scheme。不能用 KVC 链式下标：
// 重签后 CFBundleURLTypes 可能被改写/为空，链式下标会抛 NSRangeException。
+ (NSString *)hostURLSchemeFromInfo {
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    NSArray *types = info[@"CFBundleURLTypes"];
    if (![types isKindOfClass:[NSArray class]]) { return nil; }
    for (NSDictionary *type in types) {
        if (![type isKindOfClass:[NSDictionary class]]) { continue; }
        NSArray *schemes = type[@"CFBundleURLSchemes"];
        if ([schemes isKindOfClass:[NSArray class]] && schemes.count > 0 &&
            [schemes.firstObject isKindOfClass:[NSString class]]) {
            return schemes.firstObject;
        }
    }
    return nil;
}

// 上游 LiveContainerMain 冷启动瞬间用宿主 Info.plist / App Group 现算
// lcAppUrlScheme / lcAppGroupPath 两个全局量；单包重签后这两个来源都不可靠
// （scheme 顺序可变、appGroupID 退回 @"Unknown" → containerURL 为 nil）。
// patch 后的 LCBootstrap 会优先读下面两个 UserDefaults 覆盖键。
// 幂等：冷启动接管最顶部与 bootstrap 都调用，保证任何进入 LiveContainerMain
// 的路径都已备好正确值，且 appGroupPath 绝不为 nil。
+ (void)ensureHostLaunchOverrides {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];

    NSString *scheme = [self hostURLSchemeFromInfo];
    // 宿主声明了 openssai / sidestore / livecontainer，优先选我们自己的。
    for (NSString *candidate in @[ @"openssai", @"sidestore", @"livecontainer" ]) {
        NSArray *types = [NSBundle mainBundle].infoDictionary[@"CFBundleURLTypes"];
        for (NSDictionary *type in types ?: @[]) {
            if ([type isKindOfClass:[NSDictionary class]] &&
                [(type[@"CFBundleURLSchemes"] ?: @[]) containsObject:candidate]) {
                scheme = candidate;
                break;
            }
        }
        if ([scheme isEqualToString:candidate]) { break; }
    }
    if (scheme.length) { [d setObject:scheme forKey:@"TNBHostUrlScheme"]; }

    // App Group 容器根：上游要的是根（它自己再拼 LiveContainer/Data/...）。
    // 已声明 group → LCSharedUtils.appGroupID → Documents 兜底，绝不为 nil。
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *groupRoot = [fm containerURLForSecurityApplicationGroupIdentifier:@"group.openssai.app"];
    if (!groupRoot) { groupRoot = [LCSharedUtils appGroupPath]; }
    NSString *groupPath = groupRoot.path;
    if (!groupPath.length) {
        groupPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    }
    if (groupPath.length) { [d setObject:groupPath forKey:@"TNBHostAppGroupPath"]; }

    [d synchronize];
    NSLog(@"[TreeNB] host overrides: scheme=%@, appGroupPath=%@", scheme, groupPath);

    // guest 运行时前置条件：补 Documents/Tweaks 目录 + TweakLoader.dylib 软链。
    // 必须在进入 LiveContainerMain 之前完成，否则 guest 的 dlopen 立即失败。
    [self ensureTweakLoaderSymlink];
    // 首次启动自动导入内置 p12，省掉手动导入（无密码证书留空即可）。
    [self autoImportBundledCertificateIfNeeded];
}

#pragma mark - Cold launch takeover

+ (BOOL)takeOverIfGuestPending {
    // ★ 必须在 LiveContainerMain 之前：注入宿主 URL scheme / App Group 覆盖值，
    //   否则上游现算的 lcAppUrlScheme/lcAppGroupPath 在重签环境里会拿错或为 nil。
    [self ensureHostLaunchOverrides];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *selected = [defaults stringForKey:@"selected"];

    // 没有待启动 guest：正常的 openSSS 冷启动，直接返回 NO。
    if (selected.length == 0 || [selected isEqualToString:@"ui"]) {
        return NO;
    }
    // LCOpenSideStore=YES 是 openSSS-as-guest 分支，不属于容器 guest，不接管。
    if ([defaults boolForKey:@"LCOpenSideStore"]) {
        return NO;
    }

    // ★ 新鲜度门禁：selected 可能是上次 guest 退出后残留的旧值。widget 深链冷启
    //   时 URL 还没到 SceneDelegate，若在这里直接接管就会误进"上次打开的 App"。
    //   只认 15 秒内由 launchGuestApp 写入的意图标记；过期则视为残留，清掉并返回 NO，
    //   让宿主正常启动，等 SceneDelegate 收到深链后由 router 精确写入并重启。
    id tsObj = [defaults objectForKey:@"TNBGuestLaunchIntentTS"];
    NSTimeInterval ts = [tsObj isKindOfClass:[NSNumber class]] ? [tsObj doubleValue] : 0;
    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - ts;
    if (ts <= 0 || age > 15) {
        NSLog(@"[TreeNB] 冷启动放弃残留 selected=%@ (age=%.1fs)，交还宿主等深链", selected, age);
        [defaults removeObjectForKey:@"selected"];
        [defaults removeObjectForKey:@"selectedContainer"];
        [defaults removeObjectForKey:@"TNBGuestLaunchIntentTS"];
        return NO;
    }

    NSLog(@"[TreeNB] 冷启动接管 guest: %@ (intent age=%.1fs)", selected, age);

    // ★ 严格校验 guest 元数据：LiveContainerMain 找不到 guest 时会 fallback 去
    //   dlopen LiveContainerSwiftUI 的 main() 起它自己的 UI —— 但 TreeNB 的 UI 是
    //   openSSS 的 UIKit，二次起 UI 必然乱套。所以只有确认 guest 完整存在才接管。
    NSArray *docPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = docPaths.firstObject;
    NSString *guestApp = [docs stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"Applications/%@", selected]];
    NSString *appInfoPath = [guestApp stringByAppendingPathComponent:@"LCAppInfo.plist"];
    NSDictionary *guestInfo = [NSDictionary dictionaryWithContentsOfFile:appInfoPath];
    if (!guestInfo || guestInfo[@"LCDataUUID"] == nil) {
        NSLog(@"[TreeNB] 冷启动接管放弃：guest 元数据缺失 (%@)", appInfoPath);
        [defaults removeObjectForKey:@"selected"];
        [defaults removeObjectForKey:@"selectedContainer"];
        [defaults removeObjectForKey:@"TNBGuestLaunchIntentTS"];
        return NO;
    }

    TNBLCMainFn lcMain = (TNBLCMainFn)dlsym(RTLD_DEFAULT, "LiveContainerMain");
    if (!lcMain) {
        NSLog(@"[TreeNB] 冷启动接管失败：找不到 LiveContainerMain 符号");
        [defaults removeObjectForKey:@"selected"];
        [defaults removeObjectForKey:@"selectedContainer"];
        [defaults removeObjectForKey:@"TNBGuestLaunchIntentTS"];
        return NO;
    }

    // LiveContainerMain 内部读 selected 键走 invokeAppMain。
    // guest 成功接管时它不会返回（guest 的 UIApplicationMain 接管进程）；
    // 只有 guest 启动失败才返回非 0，或没有找到 guest 时走到 dlopen SwiftUI main（返回）。
    // 只要它返回，就说明没能交给 guest —— 清理状态，让宿主正常启动。
    int argc = 1;
    char *argv[] = { "TreeNB", NULL };
    int result = lcMain(argc, argv);
    NSLog(@"[TreeNB] LiveContainerMain 返回 %d（未交出进程，回落宿主 UI）", result);

    // ★ 透传 guest 启动失败的真实原因到 UI：上游 invokeAppMain 失败时把错误写进
    //   "error" 键。不读它就会变成"闪一下回主界面却没有任何提示"，无法排障。
    //   Swift 容器页在 refresh 时读取并展示 TNBLastGuestLaunchError。
    NSString *guestError = [defaults stringForKey:@"error"];
    if (guestError.length) {
        [defaults setObject:guestError forKey:@"TNBLastGuestLaunchError"];
        [defaults removeObjectForKey:@"error"];
        NSLog(@"[TreeNB] guest 启动失败原因: %@", guestError);
    }

    [defaults removeObjectForKey:@"selected"];
    [defaults removeObjectForKey:@"selectedContainer"];
    [defaults removeObjectForKey:@"launchAppUrlScheme"];
    [defaults removeObjectForKey:@"TNBGuestLaunchIntentTS"];
    return NO;
}

#pragma mark - Bootstrap

- (BOOL)bootstrapWithError:(NSError **)error {
    if (self.status == TNBEngineStatusReady) { return YES; }

    NSFileManager *fm = [NSFileManager defaultManager];

    // 容器根目录：复用 openSSS 主 App Group（entitlements 已含 group.com.openssai.app）
    NSURL *docs = [[fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    self.bundleRoot = [docs URLByAppendingPathComponent:@"Applications" isDirectory:YES];

    NSURL *groupRoot = [NSFileManager.defaultManager
        containerURLForSecurityApplicationGroupIdentifier:@"group.openssai.app"];
    if (!groupRoot) {
        // fallback：侧载环境真实 group 可能带 team 前缀，从运行时 entitlement 读
        groupRoot = [LCSharedUtils appGroupPath];
    }
    // ★ 侧载重签后 App Group 极可能完全拿不到（groupRoot == nil）：
    //   此时 groupBundleRoot 也是 nil，数组字面量塞它
    //   会因插入 nil 抛 NSInvalidArgumentException，Swift 侧 do/catch 捕获不了，
    //   表现就是「点容器 Tab 瞬间闪退」。fallback 到 Documents，保证容器始终可用。
    NSURL *effectiveGroupRoot = groupRoot ?: docs;
    self.groupBundleRoot = [effectiveGroupRoot URLByAppendingPathComponent:@"LiveContainer/Applications"
                                                       isDirectory:YES];

    // 同样禁止数组字面量里出现 nil：逐个 condition 添加。
    NSMutableArray<NSURL *> *roots = [NSMutableArray arrayWithCapacity:2];
    if (self.bundleRoot) { [roots addObject:self.bundleRoot]; }
    if (self.groupBundleRoot) { [roots addObject:self.groupBundleRoot]; }
    for (NSURL *root in roots) {
        NSError *createErr = nil;
        [fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:&createErr];
        if (createErr) {
            if (error) {
                *error = [NSError errorWithDomain:TNBEngineErrorDomain code:2
                                        userInfo:@{NSLocalizedDescriptionKey:
                                            [NSString stringWithFormat:@"容器目录创建失败: %@", createErr.localizedDescription]}];
            }
            self.status = TNBEngineStatusFailed;
            return NO;
        }
    }

    // 冷启动与常规启动两条路径都注入宿主 URL scheme / App Group 覆盖值，
    // 保证上游 LiveContainerMain 现算的 lcAppUrlScheme/lcAppGroupPath 拿正确值。
    [LCEngineEntry ensureHostLaunchOverrides];

    // ★ 关键：不在这里安装任何 UIApplication/NSBundle swizzle。
    //   上游工程的 swizzle 是进程级的，宿主 openSSS 还在跑主循环，提前 swizzle 会打架。
    //   真正需要时由 launchGuestApp 内部触发。

    self.status = TNBEngineStatusReady;
    NSLog(@"[TreeNB] LC engine bootstrap OK (bundleRoot=%@, groupRoot=%@)",
          self.bundleRoot.path, self.groupBundleRoot.path);

    // 内置证书首次自动导入后，用该证书把已装 guest 重签一次（后台，不阻塞 UI）。
    [self autoResignGuestsIfNeeded];
    return YES;
}

#pragma mark - Launch guest

- (BOOL)launchGuestApp:(NSString *)bundleName
       containerFolder:(NSString *)containerFolderName
              launchURL:(NSString *)urlStr
           classicMode:(NSUInteger)classicMode
                  error:(NSError **)error {
    if (self.status != TNBEngineStatusReady) {
        if (![self bootstrapWithError:error]) { return NO; }
    }

    // 确认 guest 存在
    NSURL *appPath = [self.bundleRoot URLByAppendingPathComponent:bundleName isDirectory:YES];
    if (![[NSFileManager defaultManager] fileExistsAtPath:appPath.path]) {
        appPath = [self.groupBundleRoot URLByAppendingPathComponent:bundleName isDirectory:YES];
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:appPath.path]) {
        if (error) {
            *error = [NSError errorWithDomain:TNBEngineErrorDomain code:4
                                    userInfo:@{NSLocalizedDescriptionKey:
                                        [NSString stringWithFormat:@"guest 不存在: %@", bundleName]}];
        }
        return NO;
    }

    // 读 guest 元数据，拿容器 folderName 和 classicMode。
    // 上游 LCBootstrap invokeAppMain 强依赖 LCAppInfo.plist 的 LCDataUUID。
    NSString *dataUUID = containerFolderName;
    NSUInteger effectiveClassic = classicMode;
    Class infoClass = NSClassFromString(@"LCAppInfo");
    id<TNBLCAppInfoBridge> appInfo = infoClass ?
        [(id<TNBLCAppInfoBridge>)[infoClass alloc] initWithBundlePath:appPath.path] : nil;
    if (dataUUID.length == 0) {
        dataUUID = [appInfo dataUUID];
    }
    if (dataUUID.length == 0) {
        dataUUID = [LCSharedUtils findDefaultContainerWithBundleId:bundleName];
    }
    if (effectiveClassic == 0) {
        effectiveClassic = [appInfo defaultClassicMode];
    }
    if (dataUUID.length == 0) {
        dataUUID = bundleName;
    }

    // ★ 写入 LC 冷启动选择状态。键名必须和上游 LCBootstrap.m:759 完全一致：
    //   selected / selectedContainer / launchAppUrlScheme / LCOpenSideStore。
    NSUserDefaults *lcDefaults = [NSUserDefaults standardUserDefaults];
    [lcDefaults setObject:bundleName forKey:@"selected"];
    [lcDefaults setObject:dataUUID forKey:@"selectedContainer"];
    if (urlStr) {
        [lcDefaults setObject:urlStr forKey:@"launchAppUrlScheme"];
    } else {
        [lcDefaults removeObjectForKey:@"launchAppUrlScheme"];
    }
    [lcDefaults setBool:NO forKey:@"LCOpenSideStore"];
    // ★ 启动意图新鲜度标记：只有"本次主动发起的启动"才带这个时间戳。
    //   main.swift 冷启动接管时只认 15 秒内写入的 selected，避免 widget 冷启时
    //   误用上次残留的 selected 抢先进旧 guest（导致"点组件进错 App"）。
    //   容器页点 App / router 深链都会走这里写入，重启后标记是新鲜的 → 正常接管。
    [lcDefaults setObject:@([[NSDate date] timeIntervalSince1970])
                   forKey:@"TNBGuestLaunchIntentTS"];
    [lcDefaults synchronize];

    self.swizzledForGuest = YES;

    // ★ 进程接管：委托上游 LCSharedUtils。它负责：
    //   1) 判断 JIT/TrollStore/JITLess 路径；
    //   2) 用 LSApplicationWorkspace 重启本 App，并在 completion 里 SIGKILL 当前进程；
    //   3) 重启后 AppDelegate 冷启动钩子调 LiveContainerMain → invokeAppMain → guest。
    // 正常成功时本进程被 SIGKILL，此行之后不会执行。
    BOOL launched = [LCSharedUtils launchToGuestAppWithClassicMode:effectiveClassic];
    if (!launched) {
        // 没触发重启：清理状态，避免下次冷启动误进 guest。
        [self restoreAfterGuestExit];
        if (error) {
            *error = [NSError errorWithDomain:TNBEngineErrorDomain code:14
                                    userInfo:@{NSLocalizedDescriptionKey:
                                        @"无法重启进入 guest。请确认已获取 JIT（SideStore/爱思等注入 JIT）"
                                        @"或已配置 JITLess 证书，然后重试"}];
        }
        return NO;
    }

    // 走到这里说明重启已发出但进程未被立刻杀死（极少数情形）。
    // 返回 YES，让冷启动接管完成后续；同时不再热调 LiveContainerMain，避免二次初始化崩溃。
    return YES;
}

#pragma mark - Restore

- (void)restoreAfterGuestExit {
    NSUserDefaults *lcDefaults = [NSUserDefaults standardUserDefaults];
    [lcDefaults removeObjectForKey:@"selected"];
    [lcDefaults removeObjectForKey:@"selectedContainer"];
    [lcDefaults removeObjectForKey:@"launchAppUrlScheme"];
    [lcDefaults removeObjectForKey:@"TNBGuestLaunchIntentTS"];
    [lcDefaults setBool:NO forKey:@"LCOpenSideStore"];
    [lcDefaults synchronize];

    self.swizzledForGuest = NO;

    // 通知 Widget 刷新（guest 列表可能变了）
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TNBGuestDidExitNotification"
                                                        object:nil];
}

#pragma mark - Install

- (void)installIPAAtURL:(NSURL *)ipaURL
               progress:(TNBInstallProgress)progress
             completion:(TNBInstallCompletion)completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __block BOOL finished = NO;
        void (^finish)(BOOL, NSString *, NSError *) = ^(BOOL ok, NSString *path, NSError *err) {
            if (finished) { return; }
            finished = YES;
            [self finishInstall:ok path:path error:err completion:completion];
        };

        if (self.status != TNBEngineStatusReady) {
            NSError *bootErr = nil;
            if (![self bootstrapWithError:&bootErr]) { finish(NO, nil, bootErr); return; }
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:ipaURL.path]) {
            NSError *e = [NSError errorWithDomain:TNBEngineErrorDomain code:10
                                        userInfo:@{NSLocalizedDescriptionKey:@"找不到选择的 IPA 文件"}];
            finish(NO, nil, e); return;
        }

        // 1) 解压 IPA（Payload/*.app）
        if (progress) { progress(@"解压", 0.05); }
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"TNBImport-%@", [NSUUID UUID].UUIDString]];
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        int rc = TNBExtractIPAAtPath(ipaURL.path, tmp, ^(double fraction) {
            if (progress) { progress(@"解压", 0.05 + 0.55 * fraction); }
        });
        if (rc != 0) {
            NSError *e = [NSError errorWithDomain:TNBEngineErrorDomain code:11
                                        userInfo:@{NSLocalizedDescriptionKey:@"IPA 解压失败，文件可能损坏或不是有效的 IPA"}];
            finish(NO, nil, e); return;
        }

        // 2) 定位 Payload 里的 .app
        NSString *payload = [tmp stringByAppendingPathComponent:@"Payload"];
        NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:payload error:nil] ?: @[];
        NSString *appName = [[contents filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"pathExtension == 'app'"]] firstObject];
        if (!appName) {
            NSError *e = [NSError errorWithDomain:TNBEngineErrorDomain code:7
                                        userInfo:@{NSLocalizedDescriptionKey:@"IPA 内找不到 Payload/*.app"}];
            finish(NO, nil, e); return;
        }
        NSString *appPath = [payload stringByAppendingPathComponent:appName];
        NSDictionary *appInfoPlist = [NSDictionary dictionaryWithContentsOfFile:
                                      [appPath stringByAppendingPathComponent:@"Info.plist"]];
        if (!appInfoPlist) {
            NSError *e = [NSError errorWithDomain:TNBEngineErrorDomain code:12
                                        userInfo:@{NSLocalizedDescriptionKey:@"IPA 内找不到 Info.plist"}];
            finish(NO, nil, e); return;
        }

        // 3) 落盘到容器目录。目录名用脱敏 bundle id（也是启动 selected 键的值）。
        //    同名冲突保留旧版改名，避免覆盖正在用的 guest。
        NSString *ident = TNBSanitizedBundleName(appInfoPlist[@"CFBundleIdentifier"]) ?: appName;
        NSString *folderName = [ident hasSuffix:@".app"] ? ident : [ident stringByAppendingString:@".app"];
        NSString *dest = [self.bundleRoot URLByAppendingPathComponent:folderName].path;
        if ([[NSFileManager defaultManager] fileExistsAtPath:dest]) {
            folderName = [NSString stringWithFormat:@"%@_%ld.app", ident, (long)time(NULL)];
            dest = [self.bundleRoot URLByAppendingPathComponent:folderName].path;
        }
        NSError *moveErr = nil;
        [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
        if (![[NSFileManager defaultManager] moveItemAtPath:appPath toPath:dest error:&moveErr]) {
            finish(NO, nil, moveErr); return;
        }

        // 4) 用上游 LCAppInfo 建立完整 guest 元数据 + MachO patch + ZSign。
        //    这一步是 guest 能否启动的关键：invokeAppMain 强依赖 LCAppInfo.plist
        //    里的 LCDataUUID / LCOrignalBundleIdentifier / LCPatchRevision。
        if (progress) { progress(@"修补", 0.75); }
        Class infoClass = NSClassFromString(@"LCAppInfo");
        id<TNBLCAppInfoBridge> appInfo = infoClass ?
            [(id<TNBLCAppInfoBridge>)[infoClass alloc] initWithBundlePath:dest] : nil;
        if (!appInfo) {
            // SwiftUI framework 未加载：报明确错误，不要留下一个永远启动不了的 guest。
            NSError *e = [NSError errorWithDomain:TNBEngineErrorDomain code:13
                                        userInfo:@{NSLocalizedDescriptionKey:
                                            @"引擎组件缺失（LCAppInfo 不可用），无法建立可运行的应用"}];
            finish(NO, nil, e); return;
        }

        // 4a) 生成 dataUUID（=容器数据目录名）并建好容器骨架。
        //     上游 LCAppModel 在新建 app 时会做这件事；这里等价补上。
        NSString *dataUUID = [appInfo dataUUID];
        if (dataUUID.length == 0) {
            dataUUID = [NSUUID UUID].UUIDString;
            [appInfo setDataUUID:dataUUID];
        }
        [appInfo setRelativeBundlePath:folderName];
        [appInfo save];

        NSString *dataRoot = [NSString stringWithFormat:@"%@/Data/Application/%@",
                              self.bundleRoot.path, dataUUID];
        for (NSString *sub in @[@"", @"Library/Caches", @"Library/Cookies", @"Documents", @"SystemData", @"tmp"]) {
            NSString *p = sub.length ? [dataRoot stringByAppendingPathComponent:sub] : dataRoot;
            [[NSFileManager defaultManager] createDirectoryAtPath:p withIntermediateDirectories:YES
                                       attributes:nil error:nil];
        }

        // 4b) patch + 签名。签名失败（如未配置证书/JITLess）不算导入失败——
        //     app 已落盘且元数据齐全，用户配好 JIT/证书后可再强制签名启动。
        [appInfo patchExecAndSignIfNeedWithCompletionHandler:^(bool success, NSString *errorInfo) {
            if (!success) {
                NSLog(@"[TreeNB] 警告: patch/签名未完全成功: %@（可配置 JIT/证书后重试）", errorInfo);
            }
            if (progress) { progress(@"完成", 1.0); }
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TNBGuestDidExitNotification" object:nil];
            finish(YES, dest, nil);
        } progressHandler:^(NSProgress *signProgress) {
            if (progress) { progress(@"签名", 0.85 + 0.14 * signProgress.fractionCompleted); }
        } forceSign:NO];

        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    });
}

- (void)finishInstall:(BOOL)success
                 path:(NSString *)path
                error:(NSError *)error
           completion:(TNBInstallCompletion)completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) { completion(success, path, error); }
    });
}

#pragma mark - List

- (NSArray<NSString *> *)installedGuestBundleNames {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSURL *root in @[self.bundleRoot ?: [NSNull null], self.groupBundleRoot ?: [NSNull null]]) {
        if (![root isKindOfClass:[NSURL class]]) { continue; }
        NSArray *names = [fm contentsOfDirectoryAtPath:((NSURL *)root).path error:nil] ?: @[];
        for (NSString *name in names) {
            if ([name.pathExtension isEqualToString:@"app"] && ![result containsObject:name]) {
                [result addObject:name];
            }
        }
    }
    return result;
}

#pragma mark - Uninstall

- (BOOL)uninstallGuest:(NSString *)bundleName error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSURL *> *appPaths = [NSMutableArray array];
    if (self.bundleRoot) {
        [appPaths addObject:[self.bundleRoot URLByAppendingPathComponent:bundleName isDirectory:YES]];
    }
    if (self.groupBundleRoot) {
        [appPaths addObject:[self.groupBundleRoot URLByAppendingPathComponent:bundleName isDirectory:YES]];
    }

    // 删除前先读 LCAppInfo 拿 dataUUID，好把容器数据目录一起清掉。
    NSMutableSet<NSString *> *dataUUIDs = [NSMutableSet set];
    for (NSURL *appPath in appPaths) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                              [appPath URLByAppendingPathComponent:@"LCAppInfo.plist"].path];
        NSString *uuid = info[@"LCDataUUID"];
        if (uuid.length) { [dataUUIDs addObject:uuid]; }
    }

    NSInteger removed = 0;
    for (NSURL *appPath in appPaths) {
        if ([fm fileExistsAtPath:appPath.path]) {
            NSError *rmErr = nil;
            if (![fm removeItemAtURL:appPath error:&rmErr]) {
                if (error) {
                    *error = [NSError errorWithDomain:TNBEngineErrorDomain code:20
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:@"删除应用目录失败: %@", rmErr.localizedDescription]}];
                }
                return NO;
            }
            removed++;
        }
    }

    // 容器数据：bundleRoot/Data/Application/<dataUUID>（安装时创建的骨架）
    if (self.bundleRoot) {
        NSURL *dataRoot = [self.bundleRoot URLByAppendingPathComponent:@"Data/Application" isDirectory:YES];
        for (NSString *uuid in dataUUIDs) {
            NSURL *dataDir = [dataRoot URLByAppendingPathComponent:uuid isDirectory:YES];
            if ([fm fileExistsAtPath:dataDir.path]) { [fm removeItemAtURL:dataDir error:nil]; }
        }
    }

    // 如果该 guest 正是上次启动选择，清掉，避免冷启动误进已删应用。
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([bundleName isEqualToString:[defaults stringForKey:@"selected"]]) {
        [defaults removeObjectForKey:@"selected"];
        [defaults removeObjectForKey:@"selectedContainer"];
    }

    if (removed == 0) {
        if (error) {
            *error = [NSError errorWithDomain:TNBEngineErrorDomain code:21
                                    userInfo:@{NSLocalizedDescriptionKey:
                                        [NSString stringWithFormat:@"未找到应用目录: %@", bundleName]}];
        }
        return NO;
    }
    NSLog(@"[TreeNB] 已卸载 guest: %@ (%ld 处目录)", bundleName, (long)removed);
    return YES;
}

#pragma mark - Sign

- (BOOL)signGuestAtPath:(NSString *)appPath error:(NSError **)error {
    // 走上游 LCAppInfo 的 patch + ZSign：它内部检测 certificatePassword，
    // 有证书就用 ZSign.dylib 里的 ZSigner 对 guest 重签；无证书会明确报错。
    Class infoClass = NSClassFromString(@"LCAppInfo");
    id<TNBLCAppInfoBridge> appInfo = infoClass ?
        [(id<TNBLCAppInfoBridge>)[infoClass alloc] initWithBundlePath:appPath] : nil;
    if (!appInfo) {
        if (error) {
            *error = [NSError errorWithDomain:TNBEngineErrorDomain code:9
                                    userInfo:@{NSLocalizedDescriptionKey:@"引擎组件缺失（LCAppInfo 不可用）"}];
        }
        return NO;
    }
    if (![self class].hasJITLessCertificate) {
        if (error) {
            *error = [NSError errorWithDomain:TNBEngineErrorDomain code:10
                                    userInfo:@{NSLocalizedDescriptionKey:
                                        @"尚未配置 JIT-less 签名证书，请先导入 p12 证书"}];
        }
        return NO;
    }
    __block BOOL signedOK = NO;
    __block NSString *signErr = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [appInfo patchExecAndSignIfNeedWithCompletionHandler:^(bool success, NSString *errorInfo) {
        signedOK = success;
        signErr = errorInfo;
        dispatch_semaphore_signal(sem);
    } progressHandler:^(NSProgress *p) {
    } forceSign:YES];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)));
    if (!signedOK && error) {
        *error = [NSError errorWithDomain:TNBEngineErrorDomain code:8
                                userInfo:@{NSLocalizedDescriptionKey:
                                    signErr ?: @"ZSign 签名失败，请检查证书是否过期/有效"}];
    }
    return signedOK;
}

#pragma mark - JITLess 证书管理

// 证书存储位置必须与上游完全对齐：
//   LCSharedUtils certificatePassword 读 appGroup suite 的 "LCCertificatePassword"
//   LCUtils certificateData 读 appGroup suite 的 "LCCertificateData"
// appGroupID 可能因重签拿不到，故 appGroup suite + standard 双写，读时任一命中即可。
static NSString *const kTNBKeyCertData = @"LCCertificateData";
static NSString *const kTNBKeyCertPass = @"LCCertificatePassword";
static NSString *const kTNBKeyCertDate = @"LCCertificateUpdateDate";

+ (NSUserDefaults *)tnb_certDefaults {
    NSString *gid = [LCSharedUtils appGroupID];
    NSUserDefaults *group = gid.length ? [[NSUserDefaults alloc] initWithSuiteName:gid] : nil;
    return group ?: NSUserDefaults.standardUserDefaults;
}

+ (BOOL)hasJITLessCertificate {
    NSData *data = [[self tnb_certDefaults] objectForKey:kTNBKeyCertData];
    if (data.length == 0) {
        data = [NSUserDefaults.standardUserDefaults objectForKey:kTNBKeyCertData];
    }
    // ★ 证书允许无密码：ZSign 的 PKCS12_parse 会先试空密码，且上游 invokeAppMain
    //   用 `!certificatePassword` 判断——空字符串 @"" 非 nil，能跳过 JIT 检查。
    //   所以只要密码键存在（哪怕值是 @""）就算已配置，不能要求 pass.length>0，
    //   否则无密码 p12 导入后会被误判为失败、且"重签所有应用"按钮永远不出现。
    NSString *pass = [LCSharedUtils certificatePassword];
    if (pass == nil) {
        pass = [[self tnb_certDefaults] objectForKey:kTNBKeyCertPass];
    }
    if (pass == nil) {
        pass = [NSUserDefaults.standardUserDefaults objectForKey:kTNBKeyCertPass];
    }
    return data.length > 0 && pass != nil;
}

+ (void)importJITLessCertificate:(NSData *)p12Data password:(NSString *)password {
    NSDate *now = [NSDate date];
    // ★ 空密码必须存成 @"\"（非 nil）：上游 LCSharedUtils certificatePassword 直接
    //   返回该键的值，invokeAppMain 用 `!certificatePassword` 判断是否需要 JIT。
    //   存 nil/不存会让判断成立 → JIT 检查失败 → guest "闪一下回主界面"。
    //   ZSign PKCS12_parse 会先尝试空密码，故 @"" 能正确解无密码 p12。
    NSString *storedPass = password ?: @"";
    for (NSUserDefaults *d in @[[self tnb_certDefaults], NSUserDefaults.standardUserDefaults]) {
        [d setObject:p12Data forKey:kTNBKeyCertData];
        [d setObject:storedPass forKey:kTNBKeyCertPass];
        [d setObject:now forKey:kTNBKeyCertDate];
        // 缓存 appGroupID，供下次冷启动快速定位（对齐上游 LCAppGroupID）
        NSString *gid = [LCSharedUtils appGroupID];
        if (gid.length) { [d setObject:gid forKey:@"LCAppGroupID"]; }
    }
    [NSUserDefaults.standardUserDefaults synchronize];
    NSLog(@"[TreeNB] JIT-less 证书已导入 (%lu bytes)", (unsigned long)p12Data.length);
}

+ (void)removeJITLessCertificate {
    for (NSUserDefaults *d in @[[self tnb_certDefaults], NSUserDefaults.standardUserDefaults]) {
        [d removeObjectForKey:kTNBKeyCertData];
        [d removeObjectForKey:kTNBKeyCertPass];
        [d removeObjectForKey:kTNBKeyCertDate];
    }
    [NSUserDefaults.standardUserDefaults synchronize];
}

+ (void)resignAllGuestsWithCompletion:(void (^)(BOOL success, NSString *detail))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (![self hasJITLessCertificate]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) { completion(NO, @"尚未配置 JIT-less 证书"); }
            });
            return;
        }
        LCEngineEntry *engine = [self shared];
        NSArray<NSString *> *guests = [engine installedGuestBundleNames] ?: @[];
        __block NSInteger okCount = 0;
        __block NSMutableArray<NSString *> *failed = [NSMutableArray array];
        for (NSString *name in guests) {
            NSURL *appURL = [engine.bundleRoot URLByAppendingPathComponent:name isDirectory:YES];
            NSError *e = nil;
            if ([engine signGuestAtPath:appURL.path error:&e]) { okCount++; }
            else { [failed addObject:name]; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *detail = [NSString stringWithFormat:@"已重签 %ld/%lu 个应用%@",
                (long)okCount, (unsigned long)guests.count,
                failed.count ? [NSString stringWithFormat:@"；失败: %@", [failed componentsJoinedByString:@", "]] : @""];
            if (completion) { completion(failed.count == 0, detail); }
        });
    });
}

@end
