//
//  HuskyEngine.m
//  TreeNB —— Husk 翻译层适配层
//
//  直接调用 translation-layer-next 的 C API。这些 C 函数编在同一个 framework 里，
//  符号可见。engine → launch 函数的映射照抄 Husk 的 TLUnityView.swift launch(width:height:)。
//

#import "HuskyEngine.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

// husk_tl_scan / read_entry / free —— 旧 translation-layer/husk-tl.h
#include "../src/translation-layer/husk-tl.h"
// 启动 / 状态 / 触控 / 引擎判定 —— 新 translation-layer-next
#include "../src/translation-layer-next/husk-tl-unity-app.h"
// JIT-less dylib 搜索目录
#include "../src/translation-layer-next/husk-tl-ld.h"

@implementation HuskyEngine

+ (instancetype)shared {
    static HuskyEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

#pragma mark - 扫描

- (NSString *)scanAPKs:(NSArray<NSString *> *)paths {
    if (paths.count == 0) return @"{}";
    const char **cPaths = (const char **)calloc(paths.count, sizeof(char *));
    if (!cPaths) return @"{}";
    for (NSUInteger i = 0; i < paths.count; i++) {
        cPaths[i] = [paths[i] fileSystemRepresentation];
    }
    char *raw = husk_tl_scan(cPaths, (int)paths.count);
    free(cPaths);
    if (!raw) return @"{}";
    NSString *json = [NSString stringWithUTF8String:raw] ?: @"{}";
    husk_tl_free(raw);
    return json;
}

#pragma mark - JIT-less / 资源

- (void)prepareJITLessWithAOTDirectories:(NSArray<NSString *> *)dirs {
    // TL_NO_XMEM=1：不创建可执行内存，库全部从签名 dylib 映射。
    setenv("TL_NO_XMEM", "1", 1);
    NSString *joined = [dirs componentsJoinedByString:@":"];
    tl_ld_set_aot_dir(joined.UTF8String ?: "");
}

- (void)setSharedStorageDirectory:(NSString *)dir {
    husk_native_set_shared_storage(dir.UTF8String);
}

- (void)addPackage:(NSString *)apkPath {
    husk_native_add_package(apkPath.fileSystemRepresentation);
}

#pragma mark - 启动

- (BOOL)launchAPK:(NSString *)apkPath
           engine:(NSString *)engine
          dataDir:(NSString *)dataDir
       metalLayer:(void *)metalLayer
            width:(int)width
           height:(int)height
         anglePath:(NSString *)anglePath
            caPath:(NSString *)caPath {
    const char *apk = apkPath.fileSystemRepresentation;
    const char *data = dataDir.fileSystemRepresentation;
    const char *angle = anglePath.fileSystemRepresentation;
    const char *ca = caPath.fileSystemRepresentation;
    void *layer = metalLayer;

    // 与 Husk TLUnityView.launch 的 switch 一致。
    if ([engine hasPrefix:@"Unity"]) {
        return husk_unity_launch(apk, data, layer, width, height, angle, ca);
    }
    if ([engine isEqualToString:@"Godot"]) {
        return husk_godot_launch(apk, data, layer, width, height, angle, ca);
    }
    if ([engine isEqualToString:@"Minecraft"]) {
        return husk_gameactivity_launch(apk, data, layer, width, height, angle, ca);
    }
    if ([engine isEqualToString:@"Unreal Engine"]) {
        return husk_ue4_launch(apk, data, layer, width, height, angle, ca);
    }
    if ([engine isEqualToString:@"Rockstar"]) {
        return husk_gta_launch(apk, data, layer, width, height, angle, ca);
    }
    if ([engine isEqualToString:@"GameMaker"]) {
        return husk_gamemaker_launch(apk, data, layer, width, height, angle, ca);
    }
    if ([engine isEqualToString:@"Flutter"]) {
        return husk_flutter_launch(apk, data, layer, width, height, angle, ca);
    }
    if ([engine isEqualToString:@"Cocos"]) {
        return husk_cocos_launch(apk, data, layer, width, height, angle, ca);
    }
    if ([engine isEqualToString:@"NativeActivity"]) {
        return husk_ue4_launch(apk, data, layer, width, height, angle, ca);
    }
    // 其余（libGDX / Java / React Native / 无引擎但有 DEX）需要 java-runtime，
    // 当前版本未随包携带，拒绝启动并交由 UI 提示。
    return NO;
}

#pragma mark - 状态 / 触控

- (HuskyState)state {
    return (HuskyState)husk_unity_state();
}

- (nullable NSString *)loadedAPK {
    const char *c = husk_native_loaded_apk();
    return c ? [NSString stringWithUTF8String:c] : nil;
}

- (void)touch:(int)phase pointer:(int)pid x:(float)x y:(float)y {
    husk_unity_touch(phase, pid, x, y);
}

- (void)setPaused:(BOOL)paused {
    husk_unity_set_paused(paused ? true : false);
}

- (void)unload {
    husk_native_unload();
}

#pragma mark - 引擎支持判定

- (BOOL)engineIsSupported:(NSString *)engine dexCount:(int)dexCount abis:(NSArray<NSString *> *)abis libraries:(NSArray<NSString *> *)libraries {
    // 对齐 TLReport.nativeEngine：
    // 1) 必须含 arm64 或 arm32 ABI（纯 x86 不行）；无原生库但有 DEX = Java，当前不支持。
    if (abis.count == 0) return NO;
    BOOL hasARM = [abis containsObject:@"arm64-v8a"] || [abis containsObject:@"armeabi-v7a"] || [abis containsObject:@"armeabi"];
    if (!hasARM) return NO;

    // 2) 有原生引擎驱动的才支持。SDL/Python/Flutter 走 Java runtime（这里不支持），
    //    Cocos 只有 Geometry Dash（带 libfmod.so）走原生驱动。
    if ([engine hasPrefix:@"Unity"] && ![engine isEqualToString:@"Unity 6"]) return YES;
    if ([engine isEqualToString:@"Godot"]) return YES;
    if ([engine isEqualToString:@"Minecraft"]) return YES;
    if ([engine isEqualToString:@"Unreal Engine"]) return YES;
    if ([engine isEqualToString:@"Rockstar"]) return YES;
    if ([engine isEqualToString:@"GameMaker"]) return YES;
    if ([engine isEqualToString:@"NativeActivity"]) return YES;
    if ([engine isEqualToString:@"Cocos"]) {
        for (NSString *lib in libraries) {
            if ([lib isEqualToString:@"libfmod.so"]) return YES;
        }
        return NO;
    }
    return NO;
}

@end
