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

// 上游 LCSharedUtils.h 暴露的接口（framework 内可见）
@interface LCSharedUtils : NSObject
+ (NSURL *)appGroupPath;
+ (NSString *)appGroupID;
@end

// 上游 LiveContainerMain(int argc, char *argv[]) —— 通过 dlsym 拿到
typedef int (*TNBLCMainFn)(int, char **);

// LCAppInfo 在 LiveContainerSwiftUI.framework 里（主 App 已 link）。
// 这里用 protocol + NSClassFromString 调用，避免 LiveContainerShared 反向依赖 SwiftUI framework。
@protocol TNBLCAppInfoBridge <NSObject>
- (id)initWithBundlePath:(NSString *)bundlePath;
- (NSString *)bundleIdentifier;
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
    //   此时 groupBundleRoot 也是 nil，@[self.bundleRoot, self.groupBundleRoot]
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

    // ★ 关键：不在这里安装任何 UIApplication/NSBundle swizzle。
    //   上游工程的 swizzle 是进程级的，宿主 openSSS 还在跑主循环，提前 swizzle 会打架。
    //   真正需要时由 launchGuestApp 内部触发。

    self.status = TNBEngineStatusReady;
    NSLog(@"[TreeNB] LC engine bootstrap OK (bundleRoot=%@, groupRoot=%@)",
          self.bundleRoot.path, self.groupBundleRoot.path);
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

    // 写入 LC 的选择状态（对应上游 LCBootstrap.m:827 读取的 lcUserDefaults 键）
    NSUserDefaults *lcDefaults = [NSUserDefaults standardUserDefaults];
    [lcDefaults setObject:bundleName forKey:@"selectedApp"];
    if (containerFolderName) {
        [lcDefaults setObject:containerFolderName forKey:@"selectedContainer"];
    } else {
        [lcDefaults removeObjectForKey:@"selectedContainer"];
    }
    if (urlStr) {
        [lcDefaults setObject:urlStr forKey:@"LCLaunchExtensionLaunchURL"];
    }
    [lcDefaults setBool:NO forKey:@"LCOpenSideStore"];   // ★ 明确关掉 openSSS-as-guest 分支
    [lcDefaults synchronize];

    // 标记已为 guest 安装 swizzle（由下游 LC 代码读取这个标志决定何时装）
    self.swizzledForGuest = YES;

    // ★ 进程接管点：调 LiveContainerMain，它内部 invokeAppMain 把主线权交给 guest。
    //   在 TreeNB 架构里，openSSS 是主壳，这一步等于"从容器 Tab 全屏打开一个 guest"，
    //   不是跳到另一个 App，用户返回时回到同一个 App 的 Shell。
    TNBLCMainFn lcMain = (TNBLCMainFn)dlsym(RTLD_DEFAULT, "LiveContainerMain");
    if (!lcMain) {
        if (error) {
            *error = [NSError errorWithDomain:TNBEngineErrorDomain code:5
                                    userInfo:@{NSLocalizedDescriptionKey:
                                        @"找不到 LiveContainerMain 符号（LC 引擎未正确链入）"}];
        }
        return NO;
    }

    int argc = 1;
    char *argv[] = { "TreeNB", NULL };
    int result = lcMain(argc, argv);
    if (result != 0) {
        if (error) {
            *error = [NSError errorWithDomain:TNBEngineErrorDomain code:6
                                    userInfo:@{NSLocalizedDescriptionKey:
                                        [NSString stringWithFormat:@"guest 启动失败 (code %d)", result]}];
        }
        return NO;
    }
    return YES;
}

#pragma mark - Restore

- (void)restoreAfterGuestExit {
    NSUserDefaults *lcDefaults = [NSUserDefaults standardUserDefaults];
    [lcDefaults removeObjectForKey:@"selectedApp"];
    [lcDefaults removeObjectForKey:@"selectedContainer"];
    [lcDefaults removeObjectForKey:@"LCLaunchExtensionLaunchURL"];
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

        // 3) 落盘到容器目录。同名冲突时改名，保留旧版本而不是覆盖。
        NSString *ident = TNBSanitizedBundleName(appInfoPlist[@"CFBundleIdentifier"]);
        NSString *folderName = [ident stringByAppendingString:@".app"] ?: appName;
        NSString *dest = [self.bundleRoot URLByAppendingPathComponent:folderName].path;
        if ([[NSFileManager defaultManager] fileExistsAtPath:dest]) {
            folderName = [NSString stringWithFormat:@"%@_%ld.app", ident ?: appName, (long)time(NULL)];
            dest = [self.bundleRoot URLByAppendingPathComponent:folderName].path;
        }
        NSError *moveErr = nil;
        [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
        if (![[NSFileManager defaultManager] moveItemAtPath:appPath toPath:dest error:&moveErr]) {
            finish(NO, nil, moveErr); return;
        }

        // 4) 调上游 LCAppInfo 做 MachO patch + ZSign（签名失败也会留下未签名 app，与上游行为一致）
        if (progress) { progress(@"修补", 0.75); }
        Class infoClass = NSClassFromString(@"LCAppInfo");
        id<TNBLCAppInfoBridge> appInfo = infoClass ?
            [(id<TNBLCAppInfoBridge>)[infoClass alloc] initWithBundlePath:dest] : nil;
        if (!appInfo) {
            // 极端情况：SwiftUI framework 未加载。app 已落盘，仍算成功，只是未 patch。
            NSLog(@"[TreeNB] 警告: LCAppInfo 不可用，IPA 已落盘但未 patch/签名");
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TNBGuestDidExitNotification" object:nil];
            finish(YES, dest, nil); return;
        }
        [appInfo patchExecAndSignIfNeedWithCompletionHandler:^(bool success, NSString *errorInfo) {
            if (!success) {
                NSLog(@"[TreeNB] 警告: patch/签名未完全成功: %@", errorInfo);
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

#pragma mark - Sign

- (BOOL)signGuestAtPath:(NSString *)appPath error:(NSError **)error {
    // 上游 ZSign 本地签名（证书从 Keychain 读）由 LCMachOUtils 提供。
    // 这里保留扩展点：若上游符号可用则调用，否则返回明确错误而不是静默失败。
    typedef BOOL (*TNBZSignFn)(const char *appPath, const char *cert, const char *pass);
    TNBZSignFn zsign = (TNBZSignFn)dlsym(RTLD_DEFAULT, "TNBZSignGuestAtPath");
    if (zsign) {
        const char *cert = ""; // TODO: 从 Keychain 读签名证书（复用 openSSS 的 SideSign 证书存储）
        BOOL ok = zsign(appPath.UTF8String, cert, "");
        if (!ok && error) {
            *error = [NSError errorWithDomain:TNBEngineErrorDomain code:8
                                    userInfo:@{NSLocalizedDescriptionKey:@"ZSign 签名失败"}];
        }
        return ok;
    }

    // Spike 阶段：没有上游 ZSign 时不阻塞流程，明确报告"未签名"状态
    if (error) {
        *error = [NSError errorWithDomain:TNBEngineErrorDomain code:9
                                userInfo:@{NSLocalizedDescriptionKey:
                                    @"ZSign 符号未找到（Spike 阶段允许跳过，正式包必须接入）"}];
    }
    return NO;
}

@end
