#!/usr/bin/env bash
# patch_upstream.sh —— 把上游 openSSS / TreeNewBee 源码自动改造成 TreeNB 单包结构
#
# 前置：prepare_dependencies.sh 已把源码放到 upstream/openSSS 与 upstream/TreeNewBee。
# 本脚本做"结构性删除 + 身份归一 + Widget 并入"，是可重复执行的幂等补丁。
# 所有改动都打日志，失败即停（set -e）。
#
# 对应 docs/启动链改造设计.md §3 的分文件清单。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSS="$ROOT/upstream/openSSS"
LC="$ROOT/upstream/TreeNewBee"

log()  { printf '\033[1;34m[patch]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }

[ -d "$SSS/AltStore" ] || { echo "缺少 $SSS，先跑 prepare_dependencies.sh" >&2; exit 1; }
[ -d "$LC/LiveContainer" ] || { echo "缺少 $LC，先跑 prepare_dependencies.sh" >&2; exit 1; }

# ---------------------------------------------------------------------------
# A. TreeNewBee 侧：删除 openSSS-as-guest 的跳转分支
# ---------------------------------------------------------------------------
log "A. 删除 LC 侧的 openSSS 跳转分支"

# A1. 删除 openSSS 过场页（整个文件）
if [ -f "$LC/LiveContainerSwiftUI/Views/TreeOpenSSSTabView.swift" ]; then
  rm -f "$LC/LiveContainerSwiftUI/Views/TreeOpenSSSTabView.swift"
  ok "删除 TreeOpenSSSTabView.swift"
fi

# A2. 从 LCTabView 移除整个 openSSS Tab item
# 早期按行启发式删除会留下一个孤立的 `}`（TabView 里少一个 item），
# 导致 Swift 报 "expected declaration / extraneous '}' at top level"，
# 后续 sharedModel / errorInfo 等一堆 cannot find 都是级联误报。
# 现在改成：从 TreeOpenSSSTabView() 起，一直删到它对应的 .tag(...) 行（含），
# 按 Swift 语法保证括号配对。
if [ -f "$LC/LiveContainerSwiftUI/Views/LCTabView.swift" ]; then
  python3 - "$LC/LiveContainerSwiftUI/Views/LCTabView.swift" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
before = s
if 'TREENB_OPENS_TAB_REMOVED' not in s:
    lines = s.splitlines(keepends=True)
    out, i, removed = [], 0, False
    while i < len(lines):
        if 'TreeOpenSSSTabView' in lines[i]:
            # 吞掉整个 item：TreeOpenSSSTabView() → .tabItem { ... } → .tag(...)
            while i < len(lines) and not (
                '.tag(LCTabIdentifier.openSSS)' in lines[i] or '.tag(.openSSS)' in lines[i]
            ):
                i += 1
            i += 1  # 跳过 .tag 行
            while i < len(lines) and not lines[i].strip():
                i += 1  # 跳过尾随空行
            removed = True
            continue
        out.append(lines[i])
        i += 1
    s = ''.join(out)
    s = s.replace(
        '// TreeNewBee: 三个 Tab —— openSSS 放最左，点它一键进入内置 openSSS',
        '// TreeNB: 两个 Tab —— App 与设置；openSSS 已是主 App 本身，无过场页'
    )
    if removed:
        s = '// TREENB_OPENS_TAB_REMOVED: 单包架构，不再把 openSSS guest 化\n' + s
    open(p, 'w', encoding='utf-8').write(s)
print('  LCTabView.swift: %s' % ('已改' if s != before else '无需改（已幂等）'))
PY
fi

# A3. 保留 openSideStore() 入口但改成单包 no-op
# 不能整个删函数：LCAppListView / LCMultiLCManagementView 仍在调用它，
# 删除后会产生 cannot find 'openSideStore' 成员错误。TreeNB 下 openSSS 就是主 App，
# 这些调用的正确语义就是"不再跳转、直接返回"。
if [ -f "$LC/LiveContainerSwiftUI/Utilities/LCUtilsExtensions.swift" ]; then
  python3 - "$LC/LiveContainerSwiftUI/Utilities/LCUtilsExtensions.swift" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'TREENB_SIDESTORE_LAUNCH_DISABLED' not in s:
    pat = re.compile(r'\n\s*static func openSideStore\([^)]*\)\s*\{')
    m = pat.search(s)
    if m:
        k = s.find('{', m.end() - 1)
        depth = 0
        while k < len(s):
            if s[k] == '{':
                depth += 1
            elif s[k] == '}':
                depth -= 1
                if depth == 0:
                    k += 1
                    break
            k += 1
        replacement = '''
    // TREENB_SIDESTORE_LAUNCH_DISABLED: openSSS 已是主 App，不再拉起 guest。
    // 保留签名只为兼容现有调用点，所有调用都在此直接返回。
    static func openSideStore(delegate: LCAppModelDelegate? = nil, urlStr: String? = nil) {
        _ = delegate
        _ = urlStr
    }
'''
        s = s[:m.start()] + replacement + s[k:]
        open(p, 'w', encoding='utf-8').write(s)
        print('  LCUtilsExtensions.swift: openSideStore() 改为单包 no-op')
    else:
        print('  LCUtilsExtensions.swift: 未找到 openSideStore()')
else:
    print('  LCUtilsExtensions.swift: 已幂等（no-op 已注入）')
PY
fi

# A4. LCBootstrap.m 删除 LCOpenSideStore 分支（用 #if 0 完整包裹，保持可回溯）
if [ -f "$LC/LiveContainer/LCBootstrap.m" ]; then
  python3 - "$LC/LiveContainer/LCBootstrap.m" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
needle = 'if([lcUserDefaults boolForKey:@"LCOpenSideStore"]'
if needle in s and 'TREENB_GUEST_BRANCH_REMOVED' not in s:
    # 必须把整个 if 块用 #if 0 / #endif 成对包裹。早期版本只在 if 前插 #if 0
    # 没补 #endif，导致编译报 Unterminated conditional directive。
    idx = s.index(needle)
    line_start = s.rfind('\n', 0, idx) + 1
    indent = s[line_start:idx]
    brace_start = s.index('{', idx)
    depth, brace_end = 0, None
    for i in range(brace_start, len(s)):
        if s[i] == '{':
            depth += 1
        elif s[i] == '}':
            depth -= 1
            if depth == 0:
                brace_end = i + 1
                break
    if brace_end is None:
        print('  LCBootstrap.m: 找不到 if 块结束，跳过（请人工检查）')
    else:
        block = s[idx:brace_end]
        wrapped = ('#if 0 // TREENB_GUEST_BRANCH_REMOVED: openSSS 主壳化，不再作为 guest\n'
                   + indent + block + '\n'
                   + indent + '#endif')
        s = s[:idx] + wrapped + s[brace_end:]
        open(p, 'w', encoding='utf-8').write(s)
        print('  LCBootstrap.m: openSSS guest 分支已用 #if 0/#endif 完整屏蔽')
else:
    print('  LCBootstrap.m: 无需改或已改过')
PY
fi

# A4c. LCBootstrap.m 冷启动两个宿主相关全局量允许 TreeNB 覆盖。
# LiveContainerMain 开头无条件从宿主 Info.plist CFBundleURLTypes[0] 和
# containerURLForSecurityApplicationGroupIdentifier:appGroupID 现算 lcAppUrlScheme /
# lcAppGroupPath。单包重签后这两个来源都不可靠：URL scheme 可能被 SideStore/iloder
# 改写顺序，app group 可能拿不到（appGroupID 退回 @"Unknown" → containerURL 为 nil），
# 导致 guest 里 NSFileManager+GuestHooks 的 containerURL 崩、setContainerUsingByLC
# 用错 scheme。改为优先读 TreeNB 宿主在 UserDefaults 写的覆盖键，读不到才走原逻辑。
if [ -f "$LC/LiveContainer/LCBootstrap.m" ]; then
  python3 - "$LC/LiveContainer/LCBootstrap.m" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'TREENB_HOST_OVERRIDE' in s:
    print('  LCBootstrap.m: 宿主覆盖已注入（幂等）')
else:
    old_scheme = 'lcAppUrlScheme = NSBundle.mainBundle.infoDictionary[@"CFBundleURLTypes"][0][@"CFBundleURLSchemes"][0];'
    old_group = 'lcAppGroupPath = [[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[NSClassFromString(@"LCSharedUtils") appGroupID]] path];'
    new_scheme = '''// TREENB_HOST_OVERRIDE: 宿主可在 UserDefaults 注入正确的 URL scheme
    lcAppUrlScheme = [lcUserDefaults stringForKey:@"TNBHostUrlScheme"];
    if (!lcAppUrlScheme.length) {
        lcAppUrlScheme = NSBundle.mainBundle.infoDictionary[@"CFBundleURLTypes"][0][@"CFBundleURLSchemes"][0];
    }'''
    new_group = '''// TREENB_HOST_OVERRIDE: 宿主可注入已验证可用的 App Group 容器路径
    lcAppGroupPath = [lcUserDefaults stringForKey:@"TNBHostAppGroupPath"];
    if (!lcAppGroupPath.length) {
        lcAppGroupPath = [[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[NSClassFromString(@"LCSharedUtils") appGroupID]] path];
    }'''
    if old_scheme not in s or old_group not in s:
        print('  LCBootstrap.m: 未找到冷启动赋值锚点，跳过覆盖注入（请人工检查）')
    else:
        s = s.replace(old_scheme, new_scheme, 1).replace(old_group, new_group, 1)
        open(p, 'w', encoding='utf-8').write(s)
        print('  LCBootstrap.m: 宿主 URL scheme / App Group 覆盖已注入')
PY
fi

# A4e. LCBootstrap.m 建 TweakLoader symlink 时假设 tweakFolder 已存在，但上游
# 只有 LiveContainerSwiftUIApp（SwiftUI App 入口）会创建它。TreeNB 主壳是
# openSSS 的 UIKit App，那段 init 从不执行 → symlink() 因父目录不存在静默失败
# → guest dlopen "@loader_path/../../Tweaks/TweakLoader.dylib" 报 no such file。
# 另外上游用 fileExistsAtPath 判断断链不可靠，这里改成校验软链目标并强制重建。
if [ -f "$LC/LiveContainer/LCBootstrap.m" ]; then
  python3 - "$LC/LiveContainer/LCBootstrap.m" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'TREENB_TWEAKS_FIX' in s:
    print('  LCBootstrap.m: Tweaks symlink 修复已注入（幂等）')
else:
    old = '''    // Update TweakLoader symlink
    NSString *tweakLoaderPath = [tweakFolder stringByAppendingPathComponent:@"TweakLoader.dylib"];
    if (![fm fileExistsAtPath:tweakLoaderPath]) {
        remove(tweakLoaderPath.UTF8String);
        NSString *bundlePath = NSBundle.mainBundle.bundlePath;
        if([bundlePath hasSuffix:@"PlugIns/LiveProcess.appex"]) {
            // traverse back to LiveContainer.app
            bundlePath = bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
        }
        NSString *target = [bundlePath stringByAppendingPathComponent:@"Frameworks/TweakLoader.dylib"];
        symlink(target.UTF8String, tweakLoaderPath.UTF8String);
    }'''
    new = '''    // TREENB_TWEAKS_FIX: 上游只在 LiveContainerSwiftUIApp 的 SwiftUI init 里创建
    // tweakFolder；TreeNB 主壳是 UIKit App，那段 init 从不执行，symlink() 会因
    // 父目录不存在静默失败 → guest dlopen TweakLoader.dylib 报 no such file。
    [fm createDirectoryAtPath:tweakFolder withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *tweakLoaderPath = [tweakFolder stringByAppendingPathComponent:@"TweakLoader.dylib"];
    {
        NSString *bundlePath = NSBundle.mainBundle.bundlePath;
        if([bundlePath hasSuffix:@"PlugIns/LiveProcess.appex"]) {
            bundlePath = bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
        }
        NSString *target = [bundlePath stringByAppendingPathComponent:@"Frameworks/TweakLoader.dylib"];
        NSString *current = [fm destinationOfSymbolicLinkAtPath:tweakLoaderPath error:nil];
        if (![current isEqualToString:target] || ![fm fileExistsAtPath:tweakLoaderPath]) {
            remove(tweakLoaderPath.UTF8String);
            symlink(target.UTF8String, tweakLoaderPath.UTF8String);
        }
    }'''
    if old not in s:
        print('  LCBootstrap.m: 未找到 TweakLoader symlink 锚点，跳过（请人工检查）')
    else:
        s = s.replace(old, new, 1)
        open(p, 'w', encoding='utf-8').write(s)
        print('  LCBootstrap.m: Tweaks 目录/软链自愈已注入')
PY
fi

# A4d. LCSharedUtils launchToGuestAppWithClassicMode 重启本 App 时用
# NSUserDefaults.lcMainBundle.bundleIdentifier。但 lcMainBundle 是 C 全局，
# 只在 LiveContainerMain / LCRunGuestExtension 里赋值；宿主冷启动调用本方法时
# 两者都没进过 → lcMainBundle == nil → openApplicationWithBundleIdentifier:nil
# 内部 initWithContentsOfFile: 抛 NSInvalidArgumentException（2026-11-24 11:05 崩溃）。
# 改成优先用 [NSBundle mainBundle]（宿主 TreeNB 自己，正是要重启的目标），
# 保留上游 classicMode / SIGKILL 逻辑不变。
if [ -f "$LC/LiveContainer/LCSharedUtils.m" ]; then
  python3 - "$LC/LiveContainer/LCSharedUtils.m" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'TREENB_MAINBUNDLE_FIX' in s:
    print('  LCSharedUtils.m: mainBundle 兜底已注入（幂等）')
else:
    old = '[workspace openApplicationWithBundleIdentifier:NSUserDefaults.lcMainBundle.bundleIdentifier'
    new = ('// TREENB_MAINBUNDLE_FIX: 宿主冷启动时 lcMainBundle 尚未赋值，用 mainBundle 兜底\n'
           '    NSString *restartBundleId = NSUserDefaults.lcMainBundle.bundleIdentifier ?: NSBundle.mainBundle.bundleIdentifier;\n'
           '    [workspace openApplicationWithBundleIdentifier:restartBundleId')
    if old not in s:
        print('  LCSharedUtils.m: 未找到重启调用锚点，跳过（请人工检查）')
    else:
        s = s.replace(old, new, 1)
        open(p, 'w', encoding='utf-8').write(s)
        print('  LCSharedUtils.m: mainBundle nil 兜底已注入')
PY
fi

# A4f. 小组件在 guest 前台切换 App 时，走 TweakLoader hook → launchToGuestAppWithURL，
# 这条路写 selected 但不写 TreeNB 冷启动接管需要的新鲜度标记 TNBGuestLaunchIntentTS，
# 导致重启后被 takeOverIfGuestPending 的 15s 门拦下（ts=0）→ 退回宿主，表现为
# "点组件开哪个都是上次那个"。在 launchToGuestAppWithURL 写 selected 处补齐标记。
if [ -f "$LC/LiveContainer/LCSharedUtils.m" ]; then
  python3 - "$LC/LiveContainer/LCSharedUtils.m" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'TREENB_URL_LAUNCH_TS' in s:
    print('  LCSharedUtils.m: URL 启动新鲜度标记已注入（幂等）')
else:
    old = '''        [lcUserDefaults setObject:launchBundleId forKey:@"selected"];
        [lcUserDefaults setObject:containerFolderName forKey:@"selectedContainer"];'''
    new = '''        [lcUserDefaults setObject:launchBundleId forKey:@"selected"];
        [lcUserDefaults setObject:containerFolderName forKey:@"selectedContainer"];
        // TREENB_URL_LAUNCH_TS: guest 前台点小组件切换 App 走这条路，必须写新鲜度
        // 标记，否则重启后 TreeNB 冷启动接管门禁(ts<=0)会放弃 → 停在 openSSS。
        [lcUserDefaults setObject:@([[NSDate date] timeIntervalSince1970]) forKey:@"TNBGuestLaunchIntentTS"];
        [lcUserDefaults setBool:NO forKey:@"LCOpenSideStore"];'''
    if old not in s:
        sys.stderr.write('  LCSharedUtils.m: 未找到 URL 启动 selected 锚点，跳过（请人工检查）\n')
    else:
        s = s.replace(old, new, 1)
        open(p, 'w', encoding='utf-8').write(s)
        print('  LCSharedUtils.m: URL 启动新鲜度标记已注入')
PY
fi

# A4b. dyld_bypass_validation.h 里两个函数指针声明缺少 extern，是 C tentative
#      definition。多个 .m import 后会各自生成一份，xcodegen 工程下触发
#      "duplicate symbol '_orig_dyld_fcntl' / '_orig_dyld_mmap'"。加 extern 变纯声明。
if [ -f "$LC/LiveContainer/dyld_bypass_validation.h" ]; then
  python3 - "$LC/LiveContainer/dyld_bypass_validation.h" "$LC/LiveContainer/dyld_bypass_validation.m" <<'PY'
import sys
hp, mp = sys.argv[1], sys.argv[2]
s = open(hp, encoding='utf-8').read()
changed = False
for decl in ('int (*orig_dyld_fcntl)(int fildes, int cmd, void *param);',
             'int (*orig_dyld_mmap)(int fildes, int cmd, void *param);'):
    if decl in s and 'extern ' + decl not in s:
        s = s.replace(decl, 'extern ' + decl, 1)
        changed = True
if changed:
    open(hp, 'w', encoding='utf-8').write(s)
    print('  dyld_bypass_validation.h: orig_dyld_* 已加 extern，消除 tentative definition')

# 加 extern 后变量变成纯声明，必须有一个 .m 提供唯一真定义，否则
# 链接报 "Undefined symbols _orig_dyld_fcntl/_orig_dyld_mmap"。
m = open(mp, encoding='utf-8').read()
marker = '// TREENB: orig_dyld_* 唯一真定义'
if marker not in m:
    defs = (marker + '\n'
            'int (*orig_dyld_fcntl)(int fildes, int cmd, void *param) = 0;\n'
            'int (*orig_dyld_mmap)(int fildes, int cmd, void *param) = 0;\n')
    anchor = '#include "dyld_bypass_validation.h"'
    if anchor in m:
        m = m.replace(anchor, anchor + '\n' + defs, 1)
        open(mp, 'w', encoding='utf-8').write(m)
        print('  dyld_bypass_validation.m: 已补 orig_dyld_* 唯一真定义')
    else:
        print('  dyld_bypass_validation.m: 找不到 anchor，请人工检查')
PY
fi

# A5. SideStoreHooks.m bundle identity swizzle 屏蔽（宿主即本体，无需伪装）
if [ -f "$LC/SideStoreSupport/SideStoreHooks.m" ]; then
  python3 - "$LC/SideStoreSupport/SideStoreHooks.m" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'TREENB_SWIZZLE_DISABLED' not in s:
    s = '// TREENB_SWIZZLE_DISABLED: 宿主即 openSSS 本体，bundle identity swizzle 已无意义\n#if 0\n' + s + '\n#endif\n'
    open(p, 'w', encoding='utf-8').write(s)
    print('  SideStoreHooks.m: 已用 #if 0 屏蔽 swizzle')
else:
    print('  SideStoreHooks.m: 已屏蔽过')
PY
fi

# A6. IDevice.xcframework 必须是带 location_simulation 的自编译产物。
#     上游原始 Package.swift 就是 path: "../../../local/idevice/swift/IDevice.xcframework"
#     —— 这正是作者预期的「本地自编译」路径（注释明确写了 release 缺定位符号）。
#     build_idevice.sh 已在 prepare 阶段把带符号的 xcframework 落地到该路径。
#     这里做硬校验：既确保 path 没被改回 URL，也确保产物与四个定位符号都在。
DG_PKG="$SSS/Dependencies/minimuxer/DeviceGateway/Package.swift"
IDEF_XCF="$SSS/local/idevice/swift/IDevice.xcframework"
IDEF_LIB="$IDEF_XCF/ios-arm64/libidevice_ffi.a"
if [ -f "$DG_PKG" ]; then
  python3 - "$DG_PKG" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
# 若上游被改回 URL（例如手改），强行改回本地 path。
if 'url: "https://github.com/SideStore/idevice/releases' in s or 'checksum:' in s:
    import re
    s = re.sub(
        r'\.binaryTarget\(\s*name:\s*"IDevice"\s*,\s*url:\s*"[^"]+"\s*,\s*checksum:\s*"[^"]+"\s*\)',
        '.binaryTarget(\n            name: "IDevice",\n            path: "../../../local/idevice/swift/IDevice.xcframework"\n        )',
        s, count=1)
    open(p, 'w', encoding='utf-8').write(s)
    print('  DeviceGateway/Package.swift: IDevice 已改回本地自编译 path')
else:
    print('  DeviceGateway/Package.swift: IDevice 已是本地 path（无需改）')
PY
  grep -q 'path: "../../../local/idevice/swift/IDevice.xcframework"' "$DG_PKG" \
    || { echo "FATAL[A6]: IDevice binaryTarget 未指向本地自编译 path" >&2; exit 2; }
  # 产物存在 + 定位符号硬校验（缺一个都拒绝出包，杜绝回到假桩）
  [ -f "$IDEF_LIB" ] || { echo "FATAL[A6]: 缺少 $IDEF_LIB，请先跑 scripts/build_idevice.sh" >&2; exit 2; }
  for sym in location_simulation_new location_simulation_set \
             location_simulation_clear location_simulation_free; do
    [ "$(nm -gU "$IDEF_LIB" 2>/dev/null | grep -c "_${sym}$")" -gt 0 ] \
      || { echo "FATAL[A6]: 自编译 IDevice 缺符号 _${sym}" >&2; exit 2; }
  done
  ok "IDevice 自编译产物就位且四定位符号齐全（虚拟定位真修复）"
else
  echo "FATAL[A6]: DeviceGateway/Package.swift 缺失，无法接入 IDevice" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# B. openSSS 侧：加容器 Tab + 深链路由 + Widget 并入
# ---------------------------------------------------------------------------
log "B. openSSS 侧接入容器 Tab / 路由 / Widget"

# B1. ShellTabBarController：加容器 Tab
# 历史坑：早期用正则匹配 `profileNav]` / `self.viewControllers` 插入数组，
# 但上游真实变量是 profileNavigationController、且赋值是裸 `viewControllers = [...]`，
# 两个正则都匹配失败 → 补丁静默失效 → 打出来的包是纯 openSSS，没有容器 Tab。
# 现在改成完整多行字符串锚点精确替换，每步校验锚点存在，找不到直接报错退出（set -e），
# 绝不让"看着成功、实际没改"的情况再次发生。
SHELL="$SSS/AltStore/Shell/ShellTabBarController.swift"
if [ -f "$SHELL" ]; then
  python3 - "$SHELL" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
orig = s
changes = []

# 锚点 1：profileNavigationController 属性块之后插入容器 nav
a1 = '''    private lazy var profileNavigationController: UINavigationController = {
        makeNavigationController(rootViewController: profileViewController)
    }()
'''
prop = '''
    // TreeNB: 第四个 Tab —— 容器（LiveContainer 多开侧载）
    private lazy var containerNav: UINavigationController = {
        makeNavigationController(rootViewController: ContainerTabViewController())
    }()
'''
if 'private lazy var containerNav' not in s:
    if a1 not in s:
        sys.stderr.write('FATAL[B1]: 属性锚点未找到，上游 ShellTabBarController 结构已变\n')
        sys.exit(2)
    s = s.replace(a1, a1 + prop, 1)
    changes.append('containerNav 属性')

# 锚点 2：profileNavigationController.tabBarItem 之后插入容器 tabBarItem
a2 = '''        profileNavigationController.tabBarItem = UITabBarItem(
            title: NSLocalizedString("Me", comment: ""),
            image: UIImage(systemName: "person.crop.circle.fill"),
            tag: 2)
'''
tab = '''
        containerNav.tabBarItem = UITabBarItem(
            title: "🌲树应用",
            image: UIImage(systemName: "shippingbox.fill"),
            tag: 3)
'''
if 'containerNav.tabBarItem' not in s:
    if a2 not in s:
        sys.stderr.write('FATAL[B1]: tabBarItem 锚点未找到\n')
        sys.exit(2)
    s = s.replace(a2, a2 + tab, 1)
    changes.append('containerNav tabBarItem')

# 锚点 3：viewControllers 数组加入 containerNav（这就是之前失效的关键行）
a3 = '        viewControllers = [appsNavigationController, locationNavigationController, profileNavigationController]'
a3new = '        viewControllers = [appsNavigationController, locationNavigationController, containerNav, profileNavigationController]'
if a3new not in s:
    if a3 not in s:
        sys.stderr.write('FATAL[B1]: viewControllers 锚点未找到\n')
        sys.exit(2)
    s = s.replace(a3, a3new, 1)
    changes.append('viewControllers += containerNav')

# 锚点 4：applyTheme 里同步 tintColor（非致命）
a4 = '        profileNavigationController.navigationBar.tintColor = ShellTheme.accentColor\n'
a4new = a4 + '        containerNav.navigationBar.tintColor = ShellTheme.accentColor\n'
if 'containerNav.navigationBar.tintColor' not in s:
    if a4 in s:
        s = s.replace(a4, a4new, 1)
        changes.append('applyTheme tintColor')

if s != orig:
    open(p, 'w', encoding='utf-8').write(s)
print('  ShellTabBarController.swift: ' + ('；'.join(changes) if changes else '无需改（已幂等）'))
PY
  # 构建期铁证校验：viewControllers 行必须含 containerNav，否则直接失败
  grep -q 'viewControllers = \[appsNavigationController, locationNavigationController, containerNav, profileNavigationController\]' "$SHELL" \
    || { echo "FATAL[B1]: 容器 Tab 未进入 viewControllers，拒绝继续构建" >&2; exit 2; }
  ok "ShellTabBarController.swift: 容器 Tab 已挂载并通过校验"
else
  echo "FATAL[B1]: 缺少 $SHELL，无法挂载容器 Tab" >&2
  exit 2
fi

# B1b. 进程入口前移：把 guest 接管从 didFinishLaunchingWithOptions 移到 main.swift
# ---------------------------------------------------------------------------
# 根因（2026-11-24 真机 .ips 确认）：上一版在 didFinishLaunchingWithOptions 里
# 调 takeOverIfGuestPending，而那时宿主 UIApplicationMain 已创建 UIApplication
# 单例。guest 的 main() 再调一次 UIApplicationMain →
# UIApplicationInstantiateSingleton 断言 "assertion failure: Dispatch queue
# already set" → 点容器 App 闪一下回主界面，永进不去 guest。
#
# 正解：对齐上游 LiveContainer 的 main.m —— 进程唯一入口先判断 guest 待启动
# 状态，有则把进程直接交给 LiveContainerMain（它内部跑 guest 的
# UIApplicationMain，成为整个进程里唯一一次）；没有才启动宿主 openSSS。
# 因此必须移除 @UIApplicationMain（否则与 main.swift 重复入口），并删掉旧版
# 注入在 didFinishLaunching 里的热接管钩子。
APPDELEGATE="$SSS/AltStore/AppDelegate.swift"
MAINENTRY="$SSS/AltStore/main.swift"
if [ -f "$APPDELEGATE" ]; then
  python3 - "$APPDELEGATE" "$MAINENTRY" <<'PY'
import sys
app_path, main_path = sys.argv[1], sys.argv[2]
s = open(app_path, encoding='utf-8').read()
orig = s

# 1) 移除 @UIApplicationMain —— Swift 不允许它与 main.swift 顶层入口共存。
s = s.replace('@UIApplicationMain\nfinal class AppDelegate',
              '// TreeNB: @UIApplicationMain 已移除，进程入口见 main.swift\nfinal class AppDelegate', 1)

# 2) 幂等删除旧版注入在 didFinishLaunching 里的热接管钩子。
old_hook = '''        // TreeNB: guest 冷启动接管。若容器里点过某个 guest，进程在此时把主线权
        // 交给它（LiveContainerMain → invokeAppMain，正常不返回）；否则返回 NO，
        // openSSS 照常启动。必须放在所有 UI/日志初始化之前。
        if LCEngineEntry.takeOverIfGuestPending() {
            return true
        }
'''
s = s.replace(old_hook, '', 1)

if s != orig:
    open(app_path, 'w', encoding='utf-8').write(s)
    print('  AppDelegate.swift: 已移除 @UIApplicationMain 与旧热接管钩子')
else:
    print('  AppDelegate.swift: 入口改动已就位（幂等）')

# 3) 生成 main.swift —— 整个进程唯一入口。
main_src = '''//
//  main.swift
//  TreeNB —— 进程唯一入口
//
//  关键：guest 接管判定必须在 UIApplicationMain 之前。
//  上一版把接管放在 didFinishLaunchingWithOptions，那时宿主 UIApplication 单例
//  已创建，guest 的 main() 再调一次 UIApplicationMain 触发
//  "assertion failure: Dispatch queue already set" → 点容器 App 闪一下回主界面。
//  这里对齐上游 LiveContainer 的 main.m：进程进来先判断，有 guest 就把进程交给
//  LiveContainerMain（内部跑 guest 的 UIApplicationMain，进程里唯一一次），
//  没有才启动宿主 openSSS。
//
import UIKit
import Foundation
import LiveContainerShared

// ★ Widget pending 通道（兼容保留）：若历史上 App Intent 写过 pending，这里消费。
//   主路径已是 Link 深链（openssai://container-launch?bundle-name=X），点击时不会
//   写 pending，因此正常走下面的深链 → router 精确启动。takeOverIfGuestPending
//   内部有 TNBGuestLaunchIntentTS 新鲜度门，残留 selected 不会被误接管。
if let pending = TNBWidgetStore.consumePendingLaunch(), !pending.bundleName.isEmpty {
    let lcDefaults = UserDefaults.standard
    lcDefaults.set(pending.bundleName, forKey: "selected")
    if !pending.container.isEmpty {
        lcDefaults.set(pending.container, forKey: "selectedContainer")
    } else {
        lcDefaults.removeObject(forKey: "selectedContainer")
    }
    lcDefaults.removeObject(forKey: "launchAppUrlScheme")
    lcDefaults.set(false, forKey: "LCOpenSideStore")
    lcDefaults.set(Date().timeIntervalSince1970, forKey: "TNBGuestLaunchIntentTS")
    NSLog("[TreeNB] main.swift: 消费小组件 pending launch -> %@", pending.bundleName)
}

if LCEngineEntry.takeOverIfGuestPending() {
    // guest 已接管进程，正常不会返回到这里。
    exit(0)
}

// 没有待启动 guest（或 guest 启动失败已清理状态）→ 正常启动 openSSS。
// ★ 一次性迁移：老设备把 Anisette 默认值切到"本机关闭 + jk 服务器"。
//   只迁移一次（带标记），不覆盖用户之后手动改过的选择。
let tnDefaults = UserDefaults.standard
if !tnDefaults.bool(forKey: "TNBAnisetteDefaultsMigrated") {
    tnDefaults.set(false, forKey: "useOnDeviceAnisette")
    tnDefaults.set("https://mac-ani.jkcoxson.com", forKey: "menuAnisetteURL")
    tnDefaults.set(true, forKey: "TNBAnisetteDefaultsMigrated")
}
UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)
'''
need_write = False
try:
    existing = open(main_path, encoding='utf-8').read()
except FileNotFoundError:
    need_write = True
else:
    if 'takeOverIfGuestPending' not in existing:
        need_write = True
if need_write:
    open(main_path, 'w', encoding='utf-8').write(main_src)
    print('  main.swift: 已生成进程唯一入口（guest 接管前移）')
else:
    print('  main.swift: 已存在（幂等）')
PY
  # 硬校验：@UIApplicationMain 必须移除（用行首锚点，避免匹配注释）。
  if grep -q '^@UIApplicationMain' "$APPDELEGATE"; then
    echo "FATAL[B1b]: AppDelegate.swift 仍残留 @UIApplicationMain，会与 main.swift 重复入口" >&2
    exit 2
  fi
  [ -f "$MAINENTRY" ] || { echo "FATAL[B1b]: main.swift 未生成" >&2; exit 2; }
  grep -q 'takeOverIfGuestPending' "$MAINENTRY" \
    || { echo "FATAL[B1b]: main.swift 缺少 guest 接管调用" >&2; exit 2; }
  ok "进程入口前移：main.swift 唯一 UIApplicationMain + AppDelegate 去注解，校验通过"
else
  echo "FATAL[B1b]: 缺少 $APPDELEGATE，无法前移入口" >&2
  exit 2
fi

# B1d. Anisette 默认值：本机 Anisette 默认关闭，服务器默认 jk 的 mac-ani.jkcoxson.com
# ---------------------------------------------------------------------------
# 用户诉求：本机 Anisette 开关默认关闭（用远程服务器），服务器默认选中 jkcoxson。
# registerDefaults 只对新装生效；已装设备靠 main.swift 里的一次性迁移补上。
UDALT="$SSS/AltStore/Core/Extensions/UserDefaults+AltStore.swift"
if [ -f "$UDALT" ]; then
  python3 - "$UDALT" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
orig = s
# 1) 本机 Anisette 默认关闭
s = s.replace('#keyPath(UserDefaults.useOnDeviceAnisette): true,',
              '#keyPath(UserDefaults.useOnDeviceAnisette): false,')
# 2) 默认服务器改为 jk 的 mac-ani.jkcoxson.com
s = s.replace('#keyPath(UserDefaults.menuAnisetteURL): AppConstants.Anisette.Servers.defaultServerURL,',
              '#keyPath(UserDefaults.menuAnisetteURL): "https://mac-ani.jkcoxson.com",')
if s != orig:
    open(p, 'w', encoding='utf-8').write(s)
    print('  UserDefaults+AltStore.swift: Anisette 默认值已改（本机关闭/服务器 jk）')
else:
    print('  UserDefaults+AltStore.swift: Anisette 默认值已就位（幂等）')
PY
  grep -q '#keyPath(UserDefaults.useOnDeviceAnisette): false' "$UDALT" \
    || { echo "FATAL[B1d]: 本机 Anisette 默认值未改为 false" >&2; exit 2; }
  ok "Anisette 默认值：本机 Anisette 默认关闭、服务器默认 jkcoxson，校验通过"
else
  warn "未找到 $UDALT，跳过 Anisette 默认值修改"
fi

# B1e. 设置 → 高级设置：加入"屏蔽 iOS 更新"入口（复用 storyboard section 富余 cell[12]）
# ---------------------------------------------------------------------------
SETTINGS="$SSS/AltStore/Settings/SettingsViewController.swift"
if [ -f "$SETTINGS" ]; then
  python3 - "$SETTINGS" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
orig = s
changes = []

# 1) enum 加 case（rawValue 自动 = 12，对应 storyboard section[9] cell[12] q7f-PG-mTr）
a1 = '        case userCustomizations     // row 11 - User Customizations\n'
if 'case osUpdateBlock' not in s:
    if a1 not in s:
        sys.stderr.write('FATAL[B1e]: AdvancedSettingsRow userCustomizations 锚点未找到\n')
        sys.exit(2)
    s = s.replace(a1, a1 + '        case osUpdateBlock          // row 12 - 屏蔽 iOS 更新 (TreeNB)\n', 1)
    changes.append('enum case')

# 2) allCases 追加 .osUpdateBlock
a2 = '''                .backupAndRestore,
                .userCustomizations
            ])'''
n2 = '''                .backupAndRestore,
                .userCustomizations,
                .osUpdateBlock
            ])'''
if '.osUpdateBlock\n            ])' not in s:
    if a2 not in s:
        sys.stderr.write('FATAL[B1e]: allCases append 锚点未找到\n')
        sys.exit(2)
    s = s.replace(a2, n2, 1)
    changes.append('allCases')

# 3) didSelect switch 加分支（在 case .refreshAttempts 前插入）
a3 = '            case .refreshAttempts: break'
n3 = '''            case .osUpdateBlock:
                let osBlockView = TNBOSUpdateBlockerView()
                let osNav = UINavigationController(rootViewController: osBlockView)
                osNav.modalPresentationStyle = .formSheet
                if #available(iOS 15.0, *) {
                    osNav.sheetPresentationController?.detents = [.large()]
                }
                self.present(osNav, animated: true)
                self.tableView.deselectRow(at: indexPath, animated: true)

            case .refreshAttempts: break'''
if 'case .osUpdateBlock:' not in s:
    if a3 not in s:
        sys.stderr.write('FATAL[B1e]: didSelect refreshAttempts 锚点未找到\n')
        sys.exit(2)
    s = s.replace(a3, n3, 1)
    changes.append('didSelect')

# 4) cellForRowAt：把 row 12 的标题改成"屏蔽 iOS 更新"（覆盖 storyboard 原标题）
a4 = '''        let cell = super.tableView(tableView, cellForRowAt: effectiveIndexPath)
        
        if Section.allCases[indexPath.section] == .account {'''
n4 = '''        let cell = super.tableView(tableView, cellForRowAt: effectiveIndexPath)

        // TreeNB: 覆盖富余 cell 的标题为"屏蔽 iOS 更新"
        if Section.allCases[indexPath.section] == .advancedSettings,
           indexPath.row < AdvancedSettingsRow.allCases.count,
           AdvancedSettingsRow.allCases[indexPath.row].rawValue == AdvancedSettingsRow.osUpdateBlock.rawValue {
            cell.textLabel?.text = "屏蔽 iOS 更新"
            cell.detailTextLabel?.text = nil
            cell.imageView?.image = UIImage(systemName: "shield.slash")
            cell.accessoryType = .disclosureIndicator
        }
        
        if Section.allCases[indexPath.section] == .account {'''
if 'row == .osUpdateBlock {' not in s:
    if a4 not in s:
        sys.stderr.write('FATAL[B1e]: cellForRowAt 锚点未找到\n')
        sys.exit(2)
    s = s.replace(a4, n4, 1)
    changes.append('cellForRow')

if s != orig:
    open(p, 'w', encoding='utf-8').write(s)
    print('  SettingsViewController.swift: ' + '；'.join(changes))
else:
    print('  SettingsViewController.swift: 屏蔽更新入口已就位（幂等）')
PY
  grep -q 'case osUpdateBlock' "$SETTINGS" && grep -q 'TNBOSUpdateBlockerView' "$SETTINGS" \
    || { echo "FATAL[B1e]: 屏蔽更新入口注入不完整" >&2; exit 2; }
  ok "设置 → 高级设置：屏蔽 iOS 更新入口已注入并校验"
else
  warn "未找到 $SETTINGS，跳过屏蔽更新入口注入"
fi

# B1f. 「我的」Tab 的「管理」区加入"屏蔽 iOS 更新"入口（用户要的位置）
# B1e 把它藏在 Settings 的高级设置子页里，真机找不到。用户明确说"设置的管理里"，
# 对应 ProfileViewController 的 Section.manage（标题 = 管理/MANAGEMENT），
# 是最显眼、一进"我的"就能看到的位置。ManageRow 是纯代码 enum（非 storyboard），
# 加 case 后 numberOfRows 自动 +1，只需补 cell configure 与 didSelect 两个 switch。
PROFILE="$SSS/AltStore/Shell/ProfileViewController.swift"
if [ -f "$PROFILE" ]; then
  python3 - "$PROFILE" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
orig = s
changes = []

# 1) enum 加 case（rawValue 自动 = 2）
a1 = 'private enum ManageRow: Int, CaseIterable { case appearance, storage }'
n1 = 'private enum ManageRow: Int, CaseIterable { case appearance, storage, osUpdateBlock }'
if 'case appearance, storage, osUpdateBlock' not in s:
    if a1 not in s:
        sys.stderr.write('FATAL[B1f]: ManageRow enum 锚点未找到\n')
        sys.exit(2)
    s = s.replace(a1, n1, 1)
    changes.append('enum case')

# 2) cell configure：在 case .storage 块后加 case .osUpdateBlock
a2 = '''            case .storage:
                cell.configure(
                    iconSystemName: "externaldrive", iconTint: accent,
                    title: NSLocalizedString("Storage & Cleanup", comment: ""),
                    value: storageSizeText)
            case .none:'''
n2 = '''            case .storage:
                cell.configure(
                    iconSystemName: "externaldrive", iconTint: accent,
                    title: NSLocalizedString("Storage & Cleanup", comment: ""),
                    value: storageSizeText)
            case .osUpdateBlock:
                cell.configure(
                    iconSystemName: "shield.slash", iconTint: accent,
                    title: "屏蔽 iOS 更新")
            case .none:'''
if 'case .osUpdateBlock:\n                cell.configure' not in s:
    if a2 not in s:
        sys.stderr.write('FATAL[B1f]: manage cell configure 锚点未找到\n')
        sys.exit(2)
    s = s.replace(a2, n2, 1)
    changes.append('cell configure')

# 3) didSelect：在 manage switch 的 case .storage 后加 case .osUpdateBlock
a3 = '''            case .storage:
                navigationController?.pushViewController(StorageViewController(), animated: true)
            case .none:'''
n3 = '''            case .storage:
                navigationController?.pushViewController(StorageViewController(), animated: true)
            case .osUpdateBlock:
                let osBlockView = TNBOSUpdateBlockerView()
                let osNav = UINavigationController(rootViewController: osBlockView)
                osNav.modalPresentationStyle = .formSheet
                if #available(iOS 15.0, *) {
                    osNav.sheetPresentationController?.detents = [.large()]
                }
                self.present(osNav, animated: true)
            case .none:'''
if 'case .osUpdateBlock:\n                let osBlockView' not in s:
    if a3 not in s:
        sys.stderr.write('FATAL[B1f]: manage didSelect 锚点未找到\n')
        sys.exit(2)
    s = s.replace(a3, n3, 1)
    changes.append('didSelect')

if s != orig:
    open(p, 'w', encoding='utf-8').write(s)
    print('  ProfileViewController.swift: ' + '；'.join(changes))
else:
    print('  ProfileViewController.swift: 管理区屏蔽更新入口已就位（幂等）')
PY
  grep -q 'case appearance, storage, osUpdateBlock' "$PROFILE" \
    && grep -q 'let osBlockView = TNBOSUpdateBlockerView()' "$PROFILE" \
    || { echo "FATAL[B1f]: 管理区屏蔽更新入口注入不完整" >&2; exit 2; }
  ok "我的 → 管理：屏蔽 iOS 更新入口已注入并校验"
else
  warn "未找到 $PROFILE，跳过管理区屏蔽更新入口注入"
fi

# B1g. 品牌归一：关于页 openSSS → 🌲TreeNewBee Ⅱ / TreeNB Ⅱ
# 用户要求：关于里产品名改 TreeNewBee Ⅱ，标题简写 TreeNB Ⅱ，中文用🌲树应用。
# 直接改 Swift 源码字面量（绕过本地化 key），幂等。
ABOUT="$SSS/AltStore/Shell/AboutViewController.swift"
if [ -f "$ABOUT" ]; then
  python3 - "$ABOUT" "$PROFILE" <<'PY'
import sys
about_path, profile_path = sys.argv[1], sys.argv[2]

def patch(path, reps, marker):
    try:
        s = open(path, encoding='utf-8').read()
    except FileNotFoundError:
        return False
    o = s
    for a, b in reps:
        s = s.replace(a, b)
    if s != o:
        open(path, 'w', encoding='utf-8').write(s)
    return marker in s

patch(about_path, [
    ('nameLabel.text = "openSSS"', 'nameLabel.text = "🌲TreeNewBee Ⅱ"'),
    ('title = NSLocalizedString("About openSSS", comment: "")',
     'title = "关于 TreeNB Ⅱ"'),
    ('NSLocalizedString("openSSS is free and open-source software (AGPLv3). It is a fork of SideStore, built on AltStore by Riley Testut and the SideStore contributors.", comment: "")',
     '"🌲树应用（TreeNB Ⅱ）基于 openSSS / LiveContainer 整合，openSSS 遵循 AGPLv3 开源协议。"'),
], '🌲TreeNewBee Ⅱ')

patch(profile_path, [
    ('title: NSLocalizedString("About openSSS", comment: ""),',
     'title: "关于 TreeNB Ⅱ",'),
], '关于 TreeNB Ⅱ')
print('  关于页品牌归一：🌲TreeNewBee Ⅱ / TreeNB Ⅱ 已注入（幂等）')
PY
  grep -q '🌲TreeNewBee Ⅱ' "$ABOUT" \
    || { echo "FATAL[B1g]: 关于页品牌归一失败" >&2; exit 2; }
  ok "关于页品牌归一：🌲TreeNewBee Ⅱ / TreeNB Ⅱ 已校验"
else
  warn "未找到 $ABOUT，跳过关于页品牌归一"
fi

# B1h. 虚拟定位：自 A6 起 IDevice 用带 location_simulation 的自编译产物，
#     定位链路是真实现（DVT 直连 / Mac 助手），不再需要降级提示。
#     幂等清理：若上游/历史构建残留了旧版「暂不可用」文案，还原成原文案。
LOCVIEW="$SSS/AltStore/Shell/LocationSimulationViewController.swift"
if [ -f "$LOCVIEW" ]; then
  python3 - "$LOCVIEW" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
o = s
s = s.replace(
    'ToastView(text: "本机虚拟定位暂不可用（精简版缺少定位驱动）",',
    'ToastView(text: NSLocalizedString("Location simulation started", comment: ""),')
s = s.replace(
    'return "当前为精简单包，内置定位驱动未编译位置模拟功能，本机虚拟定位暂不可用。可配置 Mac 定位助手地址走局域网方案。"',
    'return NSLocalizedString("The simulated location is delivered by the on-device direct connection (Apple\'s DVT developer service) or by the location-helper on your Mac, and applies system-wide. Stop and restore the real location when you are done.", comment: "")')
if s != o:
    open(p, 'w', encoding='utf-8').write(s)
    print('  LocationSimulationViewController.swift: 已还原真实定位文案')
else:
    print('  LocationSimulationViewController.swift: 定位文案正常（无需改）')
PY
  if grep -q '本机虚拟定位暂不可用' "$LOCVIEW"; then
    echo "FATAL[B1h]: 仍残留虚拟定位降级文案" >&2
    exit 2
  fi
  ok "虚拟定位文案已校验（真实定位链路）"
else
  warn "未找到 $LOCVIEW，跳过虚拟定位文案检查"
fi

# B1c. SceneDelegate：把小组件深链接入 TNBDeepLinkRouter（真机 bug 修复）
# ---------------------------------------------------------------------------
# 现象：点小组件里的容器 App，只进 openSSS 界面，不启动对应 guest。
# 根因：TNBDeepLinkRouter.shared.handle(url:) 从未被任何地方调用；上游
# SceneDelegate 两处 URL 入口（冷启动 willConnectTo / 热启动 openURLContexts）
# 都只调 openSSS 的 URLHandler，TreeNB 深链被完全忽略。
# 修法：两处 URLHandler.shared.handle 之前先交给 TNBDeepLinkRouter，处理了就 return。
# router 内部直接调 LCEngineEntry.launchGuestApp（写 selected + 重启进程 →
# main.swift 接管进 guest），不依赖冷启动时尚未注册的 UI 观察者。
SCENEDELEGATE="$SSS/AltStore/SceneDelegate.swift"
if [ -f "$SCENEDELEGATE" ]; then
  python3 - "$SCENEDELEGATE" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
orig = s

ROUTE = '''        if TNBDeepLinkRouter.shared.handle(url: context.url) { return }
'''

# 入口 1：冷启动 willConnectTo —— 只在 urlContexts.first 分支内插入。
cold_old = '''        if let context = connectionOptions.urlContexts.first
        {
            URLHandler.shared.handle(context.url)
        }'''
cold_new = '''        if let context = connectionOptions.urlContexts.first
        {
''' + ROUTE + '''            URLHandler.shared.handle(context.url)
        }'''
if 'TNBDeepLinkRouter.shared.handle' not in s:
    if cold_old not in s:
        sys.stderr.write('FATAL[B1c]: 冷启动 URL 锚点(connectionOptions.urlContexts)未找到\n')
        sys.exit(2)
    s = s.replace(cold_old, cold_new, 1)

# 入口 2：热启动 openURLContexts。
warm_old = '''        guard let context = URLContexts.first else { return }
        debugLog("[SceneDelegate] scene(_:openURLContexts:) called with URL: \\(context.url)")
        URLHandler.shared.handle(context.url)'''
warm_new = '''        guard let context = URLContexts.first else { return }
        debugLog("[SceneDelegate] scene(_:openURLContexts:) called with URL: \\(context.url)")
''' + ROUTE + '''        URLHandler.shared.handle(context.url)'''
if s.count('TNBDeepLinkRouter.shared.handle') < 1:
    # 若上面 cold 已插入则这里只补 warm（用计数区分）
    pass
if warm_old in s and 'TNBDeepLinkRouter.shared.handle' not in warm_old:
    # 只有当 warm 分支还没有 ROUTE 时插入：定位 warm_old 最后一次出现的 handle
    # 用更精确的方式：若整体只有 1 处 ROUTE（cold），才给 warm 加。
    if s.count(ROUTE) == 1:
        s = s.replace(warm_old, warm_new, 1)

if s != orig:
    open(p, 'w', encoding='utf-8').write(s)
    print('  SceneDelegate.swift: 已接入 TNBDeepLinkRouter（冷启动 + 热启动两处）')
else:
    print('  SceneDelegate.swift: 深链路由已存在（幂等）')
PY
  # 硬校验：必须恰好两处接入（冷 + 热）
  cnt=$(grep -c 'TNBDeepLinkRouter.shared.handle' "$SCENEDELEGATE" || true)
  if [ "$cnt" -lt 2 ]; then
    echo "FATAL[B1c]: SceneDelegate 深链路由注入不足（找到 $cnt 处，期望 >=2）" >&2
    exit 2
  fi
  ok "SceneDelegate.swift: 小组件深链已接入（冷/热启动共 $cnt 处），校验通过"
else
  echo "FATAL[B1c]: 缺少 $SCENEDELEGATE，无法接入小组件深链" >&2
  exit 2
fi

# B2. Widget bundle 并入 TreeLaunchWidget
WB="$SSS/AltWidget/AltWidgetBundle.swift"
if [ -f "$WB" ] && ! grep -q "TreeLaunchWidget" "$WB"; then
  python3 - "$WB" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
# 在 var body 的第一个 widget 前插入 TreeLaunchWidget()
s = re.sub(r'(var body:\s*some Widget\s*\{\s*)',
           r'\1        TreeLaunchWidget()\n        \n', s, count=1)
open(p, 'w', encoding='utf-8').write(s)
print('  AltWidgetBundle.swift: 已并入 TreeLaunchWidget()')
PY
else
  warn "AltWidgetBundle.swift 未改（文件缺失或已含 TreeLaunchWidget）"
fi

# B3. 把 TreeNB 新增源码拷贝进上游树（让 xcodegen 能统一编译，避免重复 target 源）
log "C. 挂载 TreeNB 适配源码到上游树"
mkdir -p "$SSS/AltStore/TreeNB/Container" "$SSS/AltStore/TreeNB/Routing" "$SSS/AltWidget/TreeNB"
cp "$ROOT/Sources/Container/"*.swift "$SSS/AltStore/TreeNB/Container/" 2>/dev/null || true
# WidgetSettings.swift 需要 TNBWidgetStore/TNBWidgetSnapshot 等数据模型（定义在
# TreeWidgetBridge.swift）。该文件只 import Foundation/UIKit/Security，无 WidgetKit 依赖，
# 挂进主 App 与 Widget 两个 target 各编一份（不同 module，不冲突）。
cp "$ROOT/Sources/Widget/TreeWidgetBridge.swift" "$SSS/AltStore/TreeNB/Container/" 2>/dev/null || true
cp "$ROOT/Sources/Routing/"*.swift   "$SSS/AltStore/TreeNB/Routing/"  2>/dev/null || true
# SideStore.debugLog 兼容层（上游把它当 module 限定调用，单包后 module 不存在）。
# 注意：不再复制 location_simulation_stubs.c —— IDevice 现已用带 location_simulation
# 的自编译产物（见 build_idevice.sh / A6），再编 C 桩会 duplicate symbol。
cp "$ROOT/Sources/Compat/SideStoreCompat.swift" "$SSS/AltStore/TreeNB/" 2>/dev/null || true
cp "$ROOT/Sources/Widget/"*.swift    "$SSS/AltWidget/TreeNB/"         2>/dev/null || true
# LC 引擎桥接层挂进 LiveContainer 源码树（framework target 从这里编译）
mkdir -p "$LC/LiveContainer/TreeNBBridge/include"
cp "$ROOT/Sources/Bridge/LCEngineEntry.m"      "$LC/LiveContainer/TreeNBBridge/" 2>/dev/null || true
cp "$ROOT/Sources/Bridge/include/"*            "$LC/LiveContainer/TreeNBBridge/include/" 2>/dev/null || true
# Spike 探针也挂进主 App（DEBUG 门禁）
cp "$ROOT/Sources/Spike/"*.swift "$SSS/AltStore/TreeNB/" 2>/dev/null || true
ok "适配源码已挂载（Container/Routing/Widget/Bridge/Spike）"

# ---------------------------------------------------------------------------
# D. 身份归一：bundle id / App Group（报告 §3.6）
# ---------------------------------------------------------------------------
log "D. 身份归一（bundle id / App Group / URL scheme）"
grep -rl "com.kdt.livecontainer.treeWidget" "$LC/TreeWidget" 2>/dev/null | while read -r f; do
  sed -i '' 's/com\.kdt\.livecontainer\.treeWidget/com.openssai.app.treeWidget/g' "$f" 2>/dev/null || \
  sed -i 's/com\.kdt\.livecontainer\.treeWidget/com.openssai.app.treeWidget/g' "$f"
done
ok "Widget Keychain service 已归一为 com.openssai.app.treeWidget"

log "✅ 全部补丁执行完毕。下一步：xcodegen generate && 真机 Spike（docs/启动链改造设计.md §5）"
