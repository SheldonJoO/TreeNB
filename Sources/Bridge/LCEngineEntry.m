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

NSErrorDomain const TNBEngineErrorDomain = @"com.openssai.app.LCEngineError";

// 上游 LCSharedUtils.h 暴露的接口（framework 内可见）
@interface LCSharedUtils : NSObject
+ (NSURL *)appGroupPath;
+ (NSString *)appGroupID;
@end

// 上游 LiveContainerMain(int argc, char *argv[]) —— 通过 dlsym 拿到
typedef int (*TNBLCMainFn)(int, char **);

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
    self.groupBundleRoot = [groupRoot URLByAppendingPathComponent:@"LiveContainer/Applications"
                                                       isDirectory:YES];

    for (NSURL *root in @[self.bundleRoot, self.groupBundleRoot]) {
        if (!root) { continue; }
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
    // 实现委托给上游 LCMachOUtils/LCUtils 的安装流水线：
    //   unzip → 找 Info.plist → patch MachO (LC_LOAD_DYLIB) → 注入 TweakLoader → ZSign → 落盘
    // 这里给出框架与调用顺序；具体 patch/sign 原语来自 LiveContainerShared.framework。
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (progress) { progress(@"unzip", 0.1); }

        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        NSError *err = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:tmp
                                  withIntermediateDirectories:YES attributes:nil error:&err];
        if (err) { [self finishInstall:NO path:nil error:err completion:completion]; return; }

        // TODO(upstream): 调用 LCMachOUtils.unzipIPA(ipaURL, to: tmp)
        // 由 prepare_dependencies.sh 保证 LCMachOUtils 在 framework 内可见。
        if (progress) { progress(@"patch", 0.5); }

        // TODO(upstream): 找 .app → LCMachOUtils.patchMachOForGuest(appPath)
        if (progress) { progress(@"sign", 0.8); }

        NSError *signErr = nil;
        // 这里先做路径存在性检查，真正的 ZSign 由 signGuestAtPath: 完成
        NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:tmp error:&err];
        NSString *appName = [[contents filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"pathExtension == 'app'"]] firstObject];
        if (!appName) {
            NSError *e = [NSError errorWithDomain:TNBEngineErrorDomain code:7
                                        userInfo:@{NSLocalizedDescriptionKey:@"IPA 内找不到 .app"}];
            [self finishInstall:NO path:nil error:e completion:completion];
            return;
        }
        NSString *appPath = [tmp stringByAppendingPathComponent:appName];
        if (![self signGuestAtPath:appPath error:&signErr]) {
            [self finishInstall:NO path:nil error:signErr completion:completion];
            return;
        }

        // 落盘到 bundleRoot
        NSString *dest = [self.bundleRoot URLByAppendingPathComponent:appName].path;
        [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
        if (![[NSFileManager defaultManager] moveItemAtPath:appPath toPath:dest error:&err]) {
            [self finishInstall:NO path:nil error:err completion:completion];
            return;
        }

        if (progress) { progress(@"install", 1.0); }
        [self finishInstall:YES path:dest error:nil completion:completion];
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
