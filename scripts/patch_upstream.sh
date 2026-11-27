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

# 共享路径变量（`set -u` 下必须先定义再用）。历史上散落在各段重复定义，
# B1g5/B1g7 的闪屏补丁位于 B1c 之前，故统一提到顶部，避免 unbound variable。
SCENEDELEGATE="$SSS/AltStore/SceneDelegate.swift"
LAUNCHVC="$SSS/AltStore/LaunchViewController.swift"

log()  { printf '\033[1;34m[patch]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }

[ -d "$SSS/AltStore" ] || { echo "缺少 $SSS，先跑 prepare_dependencies.sh" >&2; exit 1; }
[ -d "$LC/LiveContainer" ] || { echo "缺少 $LC，先跑 prepare_dependencies.sh" >&2; exit 1; }

# ---------------------------------------------------------------------------
# A0. App 图标：用 config/AppIcon（用户提供的电路树图）覆盖上游 openSSS 图标。
# 上游每次都是干净 tarball，所以每轮构建都必须重铺。全套尺寸 + Contents.json
# 一起复制，尺寸清单与 appiconset 一致（20/29/40/50/57/60/72/76/80/87/100/1024/114/120/144/152/167/180）。
# ---------------------------------------------------------------------------
log "A0. 铺 TreeNB App 图标"
ICONSET="$SSS/AltStore/Resources/Icons.xcassets/AppIcon.appiconset"
if [ -d "$ROOT/config/AppIcon" ] && [ -d "$ICONSET" ]; then
  cp "$ROOT/config/AppIcon/"*.png "$ICONSET/"
  ok "App 图标已铺（$(ls "$ROOT/config/AppIcon/"*.png | wc -l | tr -d ' ') 个尺寸）"
else
  echo "FATAL[A0]: 缺少 config/AppIcon 或上游 appiconset，无法铺图标" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# A0.1 AppLogo：关于页 / 启动页/Widget 兜底用的图片资源。
# 上游 AppLogo 是 openSSS 的 "oS" 图标，用户要求换成同一张电路树图。
# ---------------------------------------------------------------------------
log "A0.1 铺 TreeNB AppLogo（关于页 + 启动页）"
APPLOGO="$SSS/AltStore/Resources/Assets.xcassets/AppLogo.imageset"
WIDGET_APPLOGO="$SSS/AltWidget/Assets.xcassets/AppLogo.imageset"
if [ -d "$ROOT/config/AppLogo" ] && [ -d "$APPLOGO" ]; then
  cp "$ROOT/config/AppLogo/"*.png "$APPLOGO/"
  [ -d "$WIDGET_APPLOGO" ] && cp "$ROOT/config/AppLogo/"*.png "$WIDGET_APPLOGO/"
  ok "AppLogo 已铺（$(ls "$ROOT/config/AppLogo/"*.png | wc -l | tr -d ' ') 个尺寸，主 App + Widget）"
else
  echo "FATAL[A0.1]: 缺少 config/AppLogo 或上游 AppLogo.imageset" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# A0.2 版本号按构建时间戳递增。
# 用户约定：短版本 1.0.YYMMDD（如 1.0.261125），构建号 YYYYMMDDHHMM。
# 直接写进 Info.plist，避免依赖 xcodebuild 命令行覆盖（会冲掉 target 级设置）。
# ---------------------------------------------------------------------------
log "A0.2 写入时间戳版本号"
TNB_STAMP=$(TZ=Asia/Shanghai date +%Y%m%d%H%M)
TNB_SHORT="1.0.${TNB_STAMP:2:6}"
python3 - "$ROOT/config/TreeNB-Info.plist" "$ROOT/config/AltWidget-Info.plist" "$ROOT/config/TreeNB.xcconfig" "$ROOT/project.yml" "$TNB_SHORT" "$TNB_STAMP" <<'PY'
import re, sys
short, build = sys.argv[5], sys.argv[6]
for path in sys.argv[1:3]:
    s = open(path, encoding='utf-8').read()
    s = re.sub(r'(<key>CFBundleShortVersionString</key>\s*<string>).*?(</string>)',
               lambda m: m.group(1) + short + m.group(2), s, count=1)
    s = re.sub(r'(<key>CFBundleVersion</key>\s*<string>).*?(</string>)',
               lambda m: m.group(1) + build + m.group(2), s, count=1)
    open(path, 'w', encoding='utf-8').write(s)

# xcodegen 会把 Info.plist 重新写成 $(MARKETING_VERSION) 占位符，
# 所以必须在 xcconfig 里也写死构建设置，archive 时才会真正替换。
xcconfig = sys.argv[3]
s = open(xcconfig, encoding='utf-8').read()
s = re.sub(r'(?m)^MARKETING_VERSION\s*=.*$', '', s)
s = re.sub(r'(?m)^CURRENT_PROJECT_VERSION\s*=.*$', '', s)
s = s.rstrip() + f"\n\n// TreeNB 时间戳版本号（patch_upstream.sh A0.2 每次构建写入）\nMARKETING_VERSION = {short}\nCURRENT_PROJECT_VERSION = {build}\n"
open(xcconfig, 'w', encoding='utf-8').write(s)

# 决定性方案：xcodegen 生成的 pbxproj 里有 target 级 MARKETING_VERSION=1.0，
# 优先级高于 xcconfig，导致 archive 仍写 1.0。直接把字面量写进
# project.yml 的 TreeNB target info.properties，xcodegen 会原样写进生成 plist。
project = sys.argv[4]
s = open(project, encoding='utf-8').read()
# 幂等：先移除上一次注入的行
s = re.sub(r'(?m)^.*TNB_VERSION_STAMP.*\n', '', s)
marker = "  TreeNB:\n"
pos = s.find(marker)
if pos < 0:
    raise SystemExit('FATAL[A0.2]: project.yml 缺少 TreeNB target')
ipos = s.find("    info:\n", pos)
if ipos < 0:
    raise SystemExit('FATAL[A0.2]: TreeNB target 缺少 info 段')
ppos = s.find("      properties:\n", ipos)
if ppos < 0:
    raise SystemExit('FATAL[A0.2]: TreeNB target 缺少 info.properties')
ins = ppos + len("      properties:\n")
injected = (
    f'        CFBundleShortVersionString: "{short}" # TNB_VERSION_STAMP\n'
    f'        CFBundleVersion: "{build}" # TNB_VERSION_STAMP\n'
)
s = s[:ins] + injected + s[ins:]
open(project, 'w', encoding='utf-8').write(s)
PY
ok "版本号已写：$TNB_SHORT ($TNB_STAMP)"

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

# A4f. 上游 LCBootstrap.m 在 iOS 26+ 硬性禁止纯 JIT 模式（两处 @available(iOS 26.0,*)
# 直接 return "JITLess mode is required"）。但 dyld_bypass_validation.m 的
# init_bypassDyldLibValidation() 在 iOS 27 代码里仍在调用，说明 JIT 绕过机制仍在。
# TreeNB 目标设备 iOS 27 + StikDebug 可开 JIT，故放开这两处限制，让有 JIT 时
# 走经典 JIT 路径（checkJITEnabled → init_bypassDyldLibValidation → dlopen guest）。
# 无 JIT 时下面原本的 checkJITEnabled 循环仍会兜底报错，不会静默失败。
if [ -f "$LC/LiveContainer/LCBootstrap.m" ]; then
  python3 - "$LC/LiveContainer/LCBootstrap.m" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
marker = 'TREENB_ALLOW_JIT_IOS26'
if marker in s:
    print('  LCBootstrap.m: iOS26+ JIT 解禁已注入（幂等）')
else:
    block = '''        if(@available(iOS 26.0 ,*))  {
            return @"JITLess mode is required since iOS 26. Please set it up in settings. \\nPlease go to TreeNewBee settings -> tap \\"Import Certificate from openSSS\\" / \\"Import Certificate\\"";
        }
'''
    if block not in s:
        print('  LCBootstrap.m: 未找到 iOS26 限制块（可能上游已改），跳过')
    else:
        repl = '''        // TREENB_ALLOW_JIT_IOS26: 放开上游 iOS26+ 强制 JITLess 限制。
        // 有 JIT（StikDebug）时走经典 JIT 路径；无 JIT 时下方循环仍会兜底报错。
#if 0
''' + block + '''#endif
'''
        n = s.count(block)
        s = s.replace(block, repl)
        open(p, 'w', encoding='utf-8').write(s)
        print('  LCBootstrap.m: 已注释 %d 处 iOS26+ JIT 限制' % n)
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
            title: "树🌲应用",
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
# 用户要求：树应用放第一个 Tab；"应用"改名"侧载"并与树应用交换位置。
# 顺序：[树应用, 定位, 侧载, 我的]。guest 悬浮键退出会重启进程回宿主，
# ShellTabBarController 重建时默认 selectedIndex=0，天然落回树应用页。
a3 = '        viewControllers = [appsNavigationController, locationNavigationController, profileNavigationController]'
a3new = '        viewControllers = [containerNav, locationNavigationController, appsNavigationController, profileNavigationController]'
if a3new not in s:
    if a3 not in s:
        sys.stderr.write('FATAL[B1]: viewControllers 锚点未找到\n')
        sys.exit(2)
    s = s.replace(a3, a3new, 1)
    changes.append('viewControllers: 树应用第一 / 侧载第三')

# 锚点 3b："应用" Tab 改名"侧载"
a_apps_title = '            title: NSLocalizedString("Apps", comment: ""),'
if a_apps_title in s:
    s = s.replace(a_apps_title, '            title: "树🌲侧载",', 1)
    changes.append('Apps Tab → 侧载')

# 锚点 3c：深链切 Tab 的索引随新顺序调整
# importAppDeepLink 原 selectTab(0) 指向"应用"，现"应用"是 index 2；
# openErrorLog 原 selectTab(2) 指向"我的"，现"我的"是 index 3。
s = s.replace('''    @objc private func importAppDeepLink(_ notification: Notification)
    {
        selectTab(0)''', '''    @objc private func importAppDeepLink(_ notification: Notification)
    {
        selectTab(2) // TreeNB: 侧载页现在是 index 2''', 1)
s = s.replace('''    @objc private func openErrorLog(_ notification: Notification)
    {
        selectTab(2)''', '''    @objc private func openErrorLog(_ notification: Notification)
    {
        selectTab(3) // TreeNB: 我的页现在是 index 3''', 1)

# 锚点 3d：guest 退出/深链时显式切回树应用 Tab（index 0）。
# 重启回宿主时默认就是 0，但 iOS state restoration 或深链可能改索引，双保险。
entry_anchor = '''        NotificationCenter.default.addObserver(
            self, selector: #selector(applyAppearance),
            name: ShellTheme.appearanceDidChangeNotification, object: nil)
    }'''
entry_new = '''        NotificationCenter.default.addObserver(
            self, selector: #selector(applyAppearance),
            name: ShellTheme.appearanceDidChangeNotification, object: nil)
        // TreeNB: guest 悬浮键退出后强制回落第一个 Tab（树应用）。
        NotificationCenter.default.addObserver(
            self, selector: #selector(tnbGuestDidExit),
            name: Notification.Name("TNBGuestDidExitNotification"), object: nil)
        // TreeNB: 小组件深链/导入深链时切回树应用 Tab（index 0）。
        TNBDeepLinkRouter.installShellObserver(self, containerTabIndex: 0)
        selectedIndex = 0
    }

    @objc private func tnbGuestDidExit()
    {
        selectedIndex = 0
        for nav in viewControllers ?? [] {
            (nav as? UINavigationController)?.popToRootViewController(animated: false)
        }
    }'''
if 'tnbGuestDidExit' not in s:
    if entry_anchor not in s:
        sys.stderr.write('FATAL[B1]: guest 退出观察器锚点未找到\n')
        sys.exit(2)
    s = s.replace(entry_anchor, entry_new, 1)
    changes.append('guest 退出回落树应用 Tab')

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
  # 构建期铁证校验：viewControllers 必须是新顺序（树应用第一 / 侧载第三），否则直接失败
  grep -q 'viewControllers = \[containerNav, locationNavigationController, appsNavigationController, profileNavigationController\]' "$SHELL" \
    || { echo "FATAL[B1]: Tab 顺序不是树应用第一，拒绝继续构建" >&2; exit 2; }
  grep -q 'title: "树🌲侧载"' "$SHELL" \
    || { echo "FATAL[B1]: 应用 Tab 未改名侧载" >&2; exit 2; }
  grep -q 'tnbGuestDidExit' "$SHELL" \
    || { echo "FATAL[B1]: guest 退出回落观察器未注入" >&2; exit 2; }
  ok "ShellTabBarController.swift: Tab 顺序（树应用第一/侧载第三）+ 退出回落已校验"
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
APPSVC="$SSS/AltStore/Shell/AppsViewController.swift"
if [ -f "$ABOUT" ]; then
  python3 - "$ABOUT" "$PROFILE" "$APPSVC" <<'PY'
import sys
about_path, profile_path, apps_path = sys.argv[1], sys.argv[2], sys.argv[3]

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
    # "我的"页帮助与支持区的"支持 openSSS" → 支持与动力
    ('title: NSLocalizedString("Support openSSS", comment: ""))',
     'title: "支持与动力")'),
    # 过期提醒通知里的 openSSS 品牌
    ('content.title = "openSSS"', 'content.title = "TreeNB Ⅱ"'),
], '关于 TreeNB Ⅱ')

# 应用页大标题 "openSSS" → "🌲TreeNB Ⅱ"（用户要求全 App 品牌统一）
patch(apps_path, [
    ('navigationItem.title = "openSSS"', 'navigationItem.title = "🌲TreeNB Ⅱ"'),
], '🌲TreeNB Ⅱ')
print('  品牌归一：关于页 / 应用页 / 支持入口 → TreeNB Ⅱ 已注入（幂等）')
PY
  grep -q '🌲TreeNewBee Ⅱ' "$ABOUT" \
    || { echo "FATAL[B1g]: 关于页品牌归一失败" >&2; exit 2; }
  grep -q 'navigationItem.title = "🌲TreeNB Ⅱ"' "$APPSVC" \
    || { echo "FATAL[B1g]: 应用页大标题品牌归一失败" >&2; exit 2; }
  grep -q 'title: "支持与动力"' "$PROFILE" \
    || { echo "FATAL[B1g]: 支持入口文案失败" >&2; exit 2; }
  ok "品牌归一：关于页 / 应用页 / 支持入口 → TreeNB Ⅱ 已校验"
else
  warn "未找到 $ABOUT，跳过关于页品牌归一"
fi

# B1g2. 界面文案品牌归一（本地化 .strings / .storyboard）
# 背景：B1g 只改了 Swift 代码里的字符串字面量，storyboard 与 .strings 里的
#       "欢迎使用 openSSS。" 等文案原样显示（真机登录页截图可见）。
#       upstream 由 prepare_dependencies.sh 每次重拉且被 gitignore，必须在此持久修补。
# 原则：只改「产品自称」的可界面文案；致谢/版权/License 里的 openSSS 一律保留。
AUTH_STRINGS="$SSS/AltStore/zh-Hans.lproj/Authentication.strings"
AUTH_STORY="$SSS/AltStore/Authentication/Authentication.storyboard"
LOCAL_STRINGS="$SSS/AltStore/zh-Hans.lproj/Localizable.strings"
SHELL_AUTH_SWIFT="$SSS/AltStore/Shell/ShellAuthenticationViewController.swift"
if [ -f "$AUTH_STRINGS" ] || [ -f "$AUTH_STORY" ] || [ -f "$LOCAL_STRINGS" ] || [ -f "$SHELL_AUTH_SWIFT" ]; then
  python3 - "$AUTH_STRINGS" "$AUTH_STORY" "$LOCAL_STRINGS" "$SHELL_AUTH_SWIFT" <<'PY'
import sys
auth_strings, auth_story, local_strings, shell_auth_swift = sys.argv[1:5]

# 产品自称 → 🌲树应用。仅限引导/登录/VPN/重签等界面可见文案。
# 注意：不替换致谢、版权、"openSSS Team"、GitHub 链接、"Stand with openSSS" 等。
reps = [
    ('欢迎使用 openSSS。', '欢迎使用 🌲树应用。'),
    ('欢迎使用 openSSS', '欢迎使用 🌲树应用'),
    ('Welcome to openSSS.', 'Welcome to 🌲TreeNB.'),
    ('Welcome to openSSS', 'Welcome to 🌲TreeNB'),
    ('启用 LocalDevVPN，随时随地使用 openSSS。', '启用 LocalDevVPN，随时随地使用 🌲树应用。'),
    ('重签 openSSS', '重签 🌲树应用'),
    ('让 openSSS 在你的设备后台保持运行。', '让 🌲树应用 在你的设备后台保持运行。'),
    ('连接 openSSS VPN 后，应用会在后台自动刷新！', '连接 🌲树应用 VPN 后，应用会在后台自动刷新！'),
    ('直接从 openSSS 浏览并下载应用。', '直接从 🌲树应用 浏览并下载应用。'),
    ('启动 openSSS', '启动 🌲树应用'),
]
changed = []
for path in (auth_strings, auth_story, local_strings, shell_auth_swift):
    try:
        s = open(path, encoding='utf-8').read()
    except FileNotFoundError:
        continue
    o = s
    for a, b in reps:
        s = s.replace(a, b)
    if s != o:
        open(path, 'w', encoding='utf-8').write(s)
        changed.append(path.split('/')[-1])
print('  界面文案品牌归一：' + ('、'.join(changed) if changed else '无需改动'))
PY
  # 校验：登录页大标题必须已是 TreeNB 品牌，且不得残留旧文案。
  # 真机反馈「Welcome to openSSS.」英文源自 ShellAuthenticationViewController 的
  # NSLocalizedString key（.strings 只改 value 无效），故 Swift 源码 key 也必须归一。
  if grep -q '欢迎使用 openSSS。' "$AUTH_STRINGS" 2>/dev/null \
     || grep -q '欢迎使用 openSSS。' "$AUTH_STORY" 2>/dev/null \
     || grep -q 'Welcome to openSSS' "$SHELL_AUTH_SWIFT" 2>/dev/null \
     || grep -q '"Welcome to openSSS' "$LOCAL_STRINGS" 2>/dev/null; then
    echo "FATAL[B1g2]: 登录页仍残留 openSSS 品牌文案" >&2
    exit 2
  fi
  if grep -q 'EI2-V3-zQZ.text" = "欢迎使用 🌲树应用。' "$AUTH_STRINGS" 2>/dev/null \
     || grep -q 'text="欢迎使用 🌲树应用。"' "$AUTH_STORY" 2>/dev/null; then
    ok "界面文案品牌归一：登录页 / 引导页 openSSS → 🌲树应用 已校验（致谢保留上游）"
  else
    warn "界面文案品牌归一：未找到预期的登录页文案，请人工复核"
  fi
fi


# B1g5a（已移除，2026-11-27 11:44）。
#   真机对照：0419 包（本段尚未引入）完全全屏，0828 起每次都会上下各 15.5% 黑边。
#   历史补丁 tnbForceFullScreen 把 SceneDelegate 所有 window/root view 的 frame
#   强行写成 scene.screen.bounds，正是把界面框进非全屏尺寸的可疑来源。
#   整合版恢复 0419 行为：不再注入任何 window/root frame 强制代码。
#   （保留 B1j 防闪退、B1k 仅文案归一、玻璃 v3。）

# B1g5~B1g9（已移除，2026-11-27 12:25）。
#   真机对照：只有 0419（这些遮罩/启动屏补丁尚未引入）是全屏且能正常进主界面。
#   0419 之后新增的 TNBFlickerGuard.cover() 额外 window、品牌 LaunchScreen、
#   TreeLaunchOverlay 启动遮罩，都会往场景里插入非全屏 window/快照层。
#   本整合版回退到 0419 的窗口/启动屏行为，只保留玻璃 v3 与 B1j 防闪退。

# B1g4. 闪屏治本：ShellTheme.applyAppearance(to:) 原本每次都无条件写
#       window.overrideUserInterfaceStyle，即使值没变也会触发整棵视图树的 trait 刷新/重绘，
#       从后台切回前台时肉眼可见「闪一下」。改成只在值真的变化时赋值（幂等短路）。
THEME_SWIFT="$SSS/AltStore/Shell/ShellTheme.swift"
if [ -f "$THEME_SWIFT" ]; then
  python3 - "$THEME_SWIFT" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
o = s
old = '''    static func applyAppearance(to window: UIWindow?)
    {
        switch appearance
        {
        case .system: window?.overrideUserInterfaceStyle = .unspecified
        case .light: window?.overrideUserInterfaceStyle = .light
        case .dark: window?.overrideUserInterfaceStyle = .dark
        }
    }'''
new = '''    static func applyAppearance(to window: UIWindow?)
    {
        guard let window = window else { return }
        let target: UIUserInterfaceStyle
        switch appearance
        {
        case .system: target = .unspecified
        case .light: target = .light
        case .dark: target = .dark
        }
        // Only assign when the value actually changes: writing the same
        // overrideUserInterfaceStyle still forces a full traitCollection
        // rebuild of the window's view tree, which shows up as a visible
        // flash when returning to the foreground (TreeNB anti-flicker).
        if window.overrideUserInterfaceStyle != target {
            window.overrideUserInterfaceStyle = target
        }
    }'''
if old in s:
    s = s.replace(old, new)
if s != o:
    open(p, 'w', encoding='utf-8').write(s)
    print('  ShellTheme.swift: applyAppearance 改为幂等短路（消除切前台重绘闪屏）')
else:
    print('  ShellTheme.swift: applyAppearance 已是幂等版（幂等）')
PY
  grep -q 'Only assign when the value actually changes' "$THEME_SWIFT" \
    || { echo "FATAL[B1g4]: 主题幂等短路注入失败" >&2; exit 2; }
  ok "闪屏治本：主题应用改为幂等，避免无变化的 trait 重绘"
fi

# B1g3. 来源加载提示：上游 Toast 的 detailText 传 nil，用户只看到「部分来源无法加载」
#       却不知道是哪个/为什么。改为显示错误摘要，并把文案改得更可操作（点击查看）。
LAUNCHVC="$SSS/AltStore/LaunchViewController.swift"
if [ -f "$LAUNCHVC" ]; then
  python3 - "$LAUNCHVC" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
o = s
# detailText 用已经算好的 errorDesc（截断，避免 Toast 过长）。
s = s.replace(
    'let toastView = ToastView(text: NSLocalizedString("Some sources were unable to load", comment: ""), detailText: nil)',
    'let shortDetail = String(errorDesc.prefix(80))\n            let toastView = ToastView(text: NSLocalizedString("Some sources were unable to load", comment: ""), detailText: shortDetail)')
if s != o:
    open(p, 'w', encoding='utf-8').write(s)
    print('  LaunchViewController.swift: 来源加载失败 Toast 已补充错误摘要')
else:
    print('  LaunchViewController.swift: 来源 Toast 已是补充版（幂等）')
PY
  grep -q 'detailText: shortDetail' "$LAUNCHVC" \
    || { echo "FATAL[B1g3]: 来源 Toast 补充失败" >&2; exit 2; }
  ok "来源加载提示：已补充错误摘要（点击 Toast 仍可进入来源页）"
fi

# 对应的中文文案：明确告知「点击查看」。
SRC_STRINGS="$SSS/AltStore/zh-Hans.lproj/Localizable.strings"
if [ -f "$SRC_STRINGS" ]; then
  python3 - "$SRC_STRINGS" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
o = s
s = s.replace('"Some sources were unable to load" = "部分来源无法加载";',
              '"Some sources were unable to load" = "部分来源无法加载（点击查看）";')
if s != o:
    open(p, 'w', encoding='utf-8').write(s)
    print('  来源 Toast 文案已补充「点击查看」')
PY
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

# B1i. 定位状态文案修正：connected 只表示 DVT 会话是否存在，不表示设备链路断开。
#      首次进入页面尚未开始模拟时 connected == false，旧代码显示「连接失败」，
#      把「未开始」误报成故障。这里统一改为「未开始」。
if [ -f "$LOCVIEW" ]; then
  python3 - "$LOCVIEW" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = '''        if !status.connected
        {
            return NSLocalizedString("Connection Failed", comment: "")
        }
        return NSLocalizedString("Not Started", comment: "")'''
new = '''        // connected 只表示本地 DVT 定位会话是否存在（未开始 / 已停止时为 false），
        // 不代表设备链路断开；旧文案把空闲状态误报成「连接失败」。
        return NSLocalizedString("Not Started", comment: "")'''
if old in s:
    s = s.replace(old, new)
    open(p, 'w', encoding='utf-8').write(s)
    print('  定位状态文案：空闲不再误报「连接失败」')
elif '旧文案把空闲状态误报成' in s:
    print('  定位状态文案已是新版本（无需改）')
else:
    raise SystemExit('FATAL[B1i]: 未定位到 statusText 的 Connection Failed 分支')
PY
  grep -q '旧文案把空闲状态误报成' "$LOCVIEW" \
    || { echo "FATAL[B1i]: 定位状态文案修正失败" >&2; exit 2; }
  ok "定位空闲状态文案已校验（未开始，不再误报连接失败）"
fi

# B1j. 启动期强制设备往返 → 延后到用时（修 LocalDevVPN 开着时"打开就闪退"）
# ---------------------------------------------------------------------------
# 真机 .ips（2026-11-27 09:05:36，UUID F92EDE3F… 与 0836 包一致）证据：
#   EXC_BAD_ACCESS / SIGSEGV，fault addr 0xfffffffffffffff0，栈顶 _platform_strlen，
#   崩溃队列 com.apple.root.default-qos（= Task.detached 启动序列），
#   调用帧 1203万~1709万偏移落在 DeviceGatewayAPI(Minimuxer Swift FFI)+Rust 静态库段。
# 机理：AppBootManager.startMinimuxer() 启动期调 fetchUDID(forceLive: true)，
#   强制真实设备往返。LocalDevVPN 开着 → 10.7.0.1/32 路由生效 → minimuxer 进入
#   localVPN 隧道枚举/DVT 握手路径，从 Swift/Rust FFI 读到跨线程的 nil String →
#   strlen(NULL) → 崩。VPN 关着时该路径走 notReachable 被 do/catch 兜住 → 不崩。
# 修法：启动期的这次 UDID 在线校验改成 no-op（配对文件存在即视为已配对）。真实的
#   设备在线校验并未丢失——它推迟到用户首次用定位/签名时，走
#   ensureMinimuxerReady() → isReady(withNetworkCheck) 完整检查。这样启动完全不
#   触发强制设备往返，VPN 常开也能正常打开 App，功能保留。
BOOTMGR="$SSS/SideStore/AppBootManager.swift"
if [ -f "$BOOTMGR" ]; then
  python3 - "$BOOTMGR" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

old = '''        // Validate the pairing by trying to fetch the UDID
        do {
            debugLog("[AppBootManager] startMinimuxer(): Minimuxer fetchUDID() based connection starting...")
            let deviceUDID = try await fetchUDID(forceLive: true)
            debugLog("[AppBootManager] startMinimuxer(): Minimuxer fetchUDID() based connection test SUCCEEDED. UDID: \\(deviceUDID)")
            self.needsPairingPrompt = false
        } catch {'''
new = '''        // TreeNB[B1j]: 启动期不做强制设备往返。LocalDevVPN 开着时，
        // fetchUDID(forceLive:true) 会进入 minimuxer FFI 的 nil String → strlen(NULL)
        // → SIGSEGV（真机 .ips 2026-11-27 09:05 已确认）。
        // 这里整个校验块改成 no-op：配对文件存在即视为已配对。真实的设备在线校验
        // 延后到用户首次用定位/签名时，走 ensureMinimuxerReady() → isReady(withNetworkCheck)。
        do {
            debugLog("[AppBootManager] startMinimuxer(): TreeNB skip boot-time live UDID check (defer to first use)")
            self.needsPairingPrompt = false
        } catch {'''

if old in s:
    s = s.replace(old, new, 1)
    open(p, 'w', encoding='utf-8').write(s)
    print('  AppBootManager.swift: 启动期强制设备校验改为 no-op（在线校验延后到用时）')
elif 'TreeNB[B1j]' in s:
    print('  AppBootManager.swift: B1j 已就位（幂等）')
else:
    raise SystemExit('FATAL[B1j]: 未定位到启动期 fetchUDID(forceLive: true) 锚点')
PY
  grep -q 'TreeNB\[B1j\]' "$BOOTMGR" \
    || { echo "FATAL[B1j]: 启动期设备往返修复未写入" >&2; exit 2; }
  ok "启动期设备往返修复已校验（缓存优先，VPN 常开不触发 FFI 强制往返）"
else
  echo "FATAL[B1j]: 缺少 $BOOTMGR，无法修复启动期设备往返" >&2
  exit 2
fi

# B1n. FFI 野指针防御 —— 修 LocalDevVPN 开启后「能操作几下才闪退」
# ---------------------------------------------------------------------------
# 真机 .ips（2026-11-27 09:05:36，slice_uuid F92EDE3F… 与 0836 包一致）：
#   EXC_BAD_ACCESS / SIGSEGV，KERN_INVALID_ADDRESS at 0xfffffffffffffff0 (-16)，
#   栈顶 libsystem_platform _platform_strlen + 4，
#   崩溃队列 com.apple.root.default-qos（= FFIDispatcher 的 DispatchQueue.global().async）。
# 反汇编 0836 主二进制（UUID 精确匹配）定位：
#   0x100e647cc 是 strlen 包装（mov x19,x0 → bl strlen → add x1,x0,#1），
#   frame2 0x100ed2818 第一条指令就 bl 到它；frame4 起落在 DeviceGatewayAPI Swift 段。
#   → FFI 返回的 C 字符串指针是野指针 -16；Swift `if let` 只能拦 nil，
#     拦不住 -16，String(cString:) 直接 strlen → 崩；随后的 free(ptr) 同样会崩。
# 为什么 B1j 不够（本次真机反馈「不是马上闪退，能操作几下」）：
#   B1j 只 no-op 了 AppBootManager:79 启动期那次 fetchUDID(forceLive:true)。
#   但 MinimuxerImpl.isReady():195 内部自己还会 fetchUDID()，所有运行期操作
#   （我的应用 onAppear / 健康检查 / 连接配置保存 / 后台刷新）经
#   ensureMinimuxerReady → isReady 都会走到；VPN 开着时 utun + 10.7.0.1 前置
#   检查全过才到 :195，VPN 关着则提前 .noVPN 返回 —— 这就是「开 VPN 操作几下
#   才崩、关 VPN 不崩」的原因。
# 修法（治本 / 不动流程 / 不动 UI）：在 IdeviceGateway + LibimobiledeviceGateway
#   注入 tnbSafeCString / tnbSafeUTF8 / tnbFree，对所有 FFI 返回指针先做用户态
#   地址合法性校验（拦 NULL 与 0xFFFFFFFF… 高位垃圾地址），合法指针原样走
#   String(cString:) 与 free()。功能完全保留。
#   ★ 玻璃 v3 与 0419 全屏启动链一行不动。
IDVG="$SSS/Dependencies/minimuxer/DeviceGateway/idevice/IdeviceGateway.swift"
LIBG="$SSS/Dependencies/minimuxer/DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift"
for GW in "$IDVG" "$LIBG"; do
  [ -f "$GW" ] || { echo "FATAL[B1n]: 缺少 $GW" >&2; exit 2; }
done
python3 - "$IDVG" "$LIBG" <<'PYB1N'
import sys, re

helper = r'''

// ===== TreeNB[B1n] FFI 野指针防御（修 LocalDevVPN 延迟闪退）=====
// 真机 .ips: strlen 收到 0xfffffffffffffff0 (-16) → SIGSEGV。
// Rust FFI 跨线程返回的 C 字符串指针可能是野指针；Swift `if let` 只能拦 nil，
// 拦不住 -16。这里统一做用户态地址校验后再交给 String(cString:) / free()。
@inline(__always)
private func tnbPtrOK<T>(_ p: UnsafePointer<T>?) -> Bool {
    guard let p = p else { return false }
    let a = UInt(bitPattern: p)
    guard a > 0x1000 && a < 0x0000_8000_0000_0000 else {
        NSLog("[TreeNB] TNB_FFI_GUARD_V1 rejected invalid C string pointer \(a)")
        return false
    }
    return true
}
@inline(__always)
private func tnbPtrOK<T>(_ p: UnsafeMutablePointer<T>?) -> Bool {
    guard let p = p else { return false }
    let a = UInt(bitPattern: p)
    guard a > 0x1000 && a < 0x0000_8000_0000_0000 else {
        NSLog("[TreeNB] TNB_FFI_GUARD_V1 rejected invalid C string pointer \(a)")
        return false
    }
    return true
}
@inline(__always)
private func tnbSafeCString(_ p: UnsafePointer<CChar>?) -> String {
    guard tnbPtrOK(p) else { return "" }
    return String(cString: p!)
}
@inline(__always)
private func tnbSafeCString(_ p: UnsafeMutablePointer<CChar>?) -> String {
    guard tnbPtrOK(p) else { return "" }
    return String(cString: p!)
}
@inline(__always)
private func tnbSafeCString(_ buf: [CChar]) -> String {
    return buf.withUnsafeBufferPointer { tnbSafeCString($0.baseAddress) }
}
@inline(__always)
private func tnbSafeUTF8(_ p: UnsafePointer<CChar>?) -> String? {
    guard tnbPtrOK(p) else { return nil }
    return String(validatingUTF8: p!)
}
@inline(__always)
private func tnbSafeUTF8(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard tnbPtrOK(p) else { return nil }
    return String(validatingUTF8: p!)
}
@inline(__always)
private func tnbSafeUTF8(_ buf: [CChar]) -> String? {
    return buf.withUnsafeBufferPointer { tnbSafeUTF8($0.baseAddress) }
}
@inline(__always)
private func tnbFree<T>(_ p: UnsafeMutablePointer<T>?) {
    guard let q = p, tnbPtrOK(p) else { return }
    free(UnsafeMutableRawPointer(q))
}
// installation_proxy_get_apps 的 outResult 是 UnsafeMutableRawPointer?，
// 泛型版无法推导 T，必须单独重载（CI 45951137700 编译错误已验证）。
@inline(__always)
private func tnbFree(_ p: UnsafeMutableRawPointer?) {
    guard let q = p else { return }
    let a = UInt(bitPattern: q)
    guard a > 0x1000 && a < 0x0000_8000_0000_0000 else {
        NSLog("[TreeNB] TNB_FFI_GUARD_V1 rejected invalid raw pointer \(a)")
        return
    }
    free(q)
}
// ===== /TreeNB[B1n] =====
'''

def convert(src, prefix, replacement):
    out, i = [], 0
    while True:
        j = src.find(prefix, i)
        if j < 0:
            out.append(src[i:]); break
        out.append(src[i:j])
        k, depth = j + len(prefix), 1
        while k < len(src) and depth:
            if src[k] == '(': depth += 1
            elif src[k] == ')': depth -= 1
            k += 1
        expr = src[j + len(prefix):k - 1]
        out.append(replacement + '(' + expr + ')')
        i = k
    return ''.join(out)

for path in sys.argv[1:]:
    s = open(path, encoding='utf-8').read()
    if 'TreeNB[B1n]' in s:
        print('  B1n already present:', path.split('/')[-1]); continue
    n_cstr = s.count('String(cString: ')
    n_utf8 = s.count('String(validatingUTF8: ')
    n_free = len(re.findall(r'(?<![A-Za-z0-9_])free\(', s))
    s = convert(s, 'String(cString: ', 'tnbSafeCString')
    s = convert(s, 'String(validatingUTF8: ', 'tnbSafeUTF8')
    s = re.sub(r'(?<![A-Za-z0-9_])free\(', 'tnbFree(', s)
    s = s.rstrip() + '\n' + helper
    open(path, 'w', encoding='utf-8').write(s)
    print('  B1n patched %s: cString=%d validatingUTF8=%d free=%d'
          % (path.split('/')[-1], n_cstr, n_utf8, n_free))
PYB1N
for GW in "$IDVG" "$LIBG"; do
  grep -q 'tnbSafeCString' "$GW" || { echo "FATAL[B1n]: $GW 未注入安全转换" >&2; exit 2; }
  grep -q 'tnbPtrOK' "$GW"      || { echo "FATAL[B1n]: $GW 未注入指针校验" >&2; exit 2; }
  grep -q 'tnbFree' "$GW"       || { echo "FATAL[B1n]: $GW 未注入安全释放" >&2; exit 2; }
done
# helper 自身每个文件含 2 处 String(cString: p!)（那是校验通过后的最终安全转换），
# 两个文件合计允许 4 处；超过即说明有业务调用没被替换。
CSTR_LEFT=$(grep -cE 'String\(cString: ' "$IDVG" "$LIBG" | awk -F: '{s+=$2} END{print s+0}')
[ "$CSTR_LEFT" -le 4 ] || { echo "FATAL[B1n]: 仍有 $CSTR_LEFT 处未保护的 String(cString:)" >&2; exit 2; }
ok "B1n: FFI 野指针防御已注入（String(cString:)/validatingUTF8/free 全量保护）"

# B1o. 品牌全量统一 —— openSSS → 🌲TreeNB（2026-11-27 真机截图反馈）
# ---------------------------------------------------------------------------
# 残留根因（此前只做白名单精确替换，漏改一大片）：
#   ① .strings 是 UTF-8 文本 old-style plist（Xcode 打包时才转 binary plist），
#      B1g2 只替换 8 条精确长句，剩下 106 条 value 里的 openSSS 全部原样；
#   ② DonationViewController.swift:21 的页面标题用的还是
#      NSLocalizedString("Support openSSS") —— B1g 只改了 ProfileViewController
#      的「入口」title，没改「赞助页」自身 title（截图「支持 openSSS」来源）；
#   ③ 系统设置 → 开发者模式里的 "Pair with openSSS" 是 iOS 按 Bonjour TXT
#      "name" 生成的，来自 MinimuxerConstants.defaultHostName（注释明确写了
#      「renaming only affects new pairings」，改名不影响配对文件身份）。
# 原则：只改用户可见的「产品自称」；致谢/版权/链接/数据库名/资源名一律保留
#   （openSSS Team、github.com/SheldonJoO/openSSS、SideStore、AltStore、
#     AppConstants.Database.name、openSSS.conf 资源名均不动）。
# 特别注意：只改 .strings 的 **value**，key 保持不变 —— 改 key 会让
#   NSLocalizedString 找不到词条而直接把英文 key 显示出来（历史踩坑）。
python3 - "$SSS" <<'PYB1O'
import sys, re, glob, os
root = sys.argv[1]

PROTECT = {
    'openSSS.conf': '\x01',
    'openSSS Team': '\x02',
    'github.com/SheldonJoO/openSSS': '\x03',
    'SideStore': '\x04',
    'AltStore': '\x05',
}
KEY_OVERRIDE = {
    'Support openSSS': '支持与动力',      # 用户明确指定
    'About openSSS': '关于 🌲TreeNB',
    'Open openSSS': '打开 🌲TreeNB',
    'openSSS': '🌲TreeNB',                # 通知标题 / 二维码页小字
}
line_re = re.compile(r'^(\s*"((?:[^"\\]|\\.)*)"\s*=\s*")((?:[^"\\]|\\.)*)("\s*;.*)$', re.M)

def brand(key, val):
    v = val
    for k, t in PROTECT.items():
        v = v.replace(k, t)
    v = v.replace('openSSS', '🌲TreeNB')
    for k, t in PROTECT.items():
        v = v.replace(t, k)
    return KEY_OVERRIDE.get(key, v)

changed_files, changed_vals = 0, 0
for p in glob.glob(root + '/**/*.strings', recursive=True):
    try:
        s = open(p, encoding='utf-8').read()
    except (UnicodeDecodeError, FileNotFoundError):
        continue
    hits = [m for m in line_re.finditer(s) if 'openSSS' in m.group(3) or m.group(2) in KEY_OVERRIDE]
    if not hits:
        continue
    s2 = line_re.sub(lambda m: m.group(1) + brand(m.group(2), m.group(3)) + m.group(4), s)
    if s2 != s:
        open(p, 'w', encoding='utf-8').write(s2)
        changed_files += 1
        changed_vals += len(hits)
print('  B1o strings: %d files, %d values rebranded' % (changed_files, changed_vals))

# Swift 侧：页面标题 / 主题预览 / 启动屏兜底 / 配对广播名
reps = [
    (root + '/AltStore/Shell/DonationViewController.swift',
     'title = NSLocalizedString("Support openSSS", comment: "")',
     'title = "支持与动力"'),
    (root + '/SideStore/Views/Settings/Advanced/UserCustomizations/ThemePickerView.swift',
     'Text("openSSS")', 'Text("🌲TreeNB")'),
    (root + '/SideStore/Views/SplashView.swift',
     '?? "openSSS"', '?? "🌲TreeNB"'),
    (root + '/Dependencies/minimuxer/Common/MinimuxerConstants.swift',
     'public static let defaultHostName = "openSSS"',
     'public static let defaultHostName = "TreeNB"'),
    (root + '/SideStore/Core/Certificates/CodeSignValidator.swift',
     'machineName.starts(with: "openSSS")',
     '(machineName.starts(with: "openSSS") || machineName.starts(with: "TreeNB"))'),
]
for p, a, b in reps:
    try:
        s = open(p, encoding='utf-8').read()
    except FileNotFoundError:
        print('  WARN missing', p); continue
    if b in s:
        print('  B1o already:', os.path.basename(p)); continue
    if a not in s:
        print('  WARN anchor not found:', os.path.basename(p), repr(a)); continue
    open(p, 'w', encoding='utf-8').write(s.replace(a, b, 1))
    print('  B1o patched:', os.path.basename(p))
PYB1O
LSTR="$SSS/AltStore/zh-Hans.lproj/Localizable.strings"
grep -q '"Support openSSS" = "支持与动力"' "$LSTR" \
  || { echo "FATAL[B1o]: 支持入口文案未归一" >&2; exit 2; }
if grep -q '"支持 openSSS"' "$LSTR"; then
  echo "FATAL[B1o]: 仍残留 支持 openSSS" >&2; exit 2
fi
grep -q 'title = "支持与动力"' "$SSS/AltStore/Shell/DonationViewController.swift" \
  || { echo "FATAL[B1o]: 赞助页标题未归一" >&2; exit 2; }
grep -q 'defaultHostName = "TreeNB"' "$SSS/Dependencies/minimuxer/Common/MinimuxerConstants.swift" \
  || { echo "FATAL[B1o]: 配对广播名未归一" >&2; exit 2; }
ok "B1o: 品牌全量统一已校验（.strings value / 赞助页 / 配对广播名）"

# B1p. 冻结用户已验收通过的 UI / 启动链基线（2026-11-27 用户要求「固定下」）
# ---------------------------------------------------------------------------
# 真机确认：全屏（无上下黑边）+ 0828 同款玻璃 v3 均正常。此后任何改动只要
# 破坏其中任一项，patch 阶段立即 FATAL，不再流出坏包。
# 历史上把界面搞坏的四种写法，逐条禁止重新出现：
#   ① tnbForceFullScreen（SceneDelegate 遍历 window 强改 frame）
#   ② B1k fullscreen（LaunchViewController.viewDidAppear 强改 view/window.frame）
#   ③ if false && !hasCompletedOnboarding（跳过引导页 → 新装卡「正在启动」）
#   ④ TNBFlickerGuard / TreeLaunchOverlay 闪屏遮罩（额外 window 层）
GLASS="$ROOT/Sources/Container/GlassChrome.swift"
LOGVC_FREEZE="$SSS/AltStore/LaunchViewController.swift"
grep -q 'TNB_GLASS_APPEARANCE_V2 installed (v3 liquid glass)' "$GLASS" \
  || { echo "FATAL[B1p]: 玻璃 v3 基线被改动" >&2; exit 2; }
grep -q 'TreeNB\[B1j\]' "$BOOTMGR" \
  || { echo "FATAL[B1p]: B1j VPN 防闪退丢失" >&2; exit 2; }
if grep -q 'tnbForceFullScreen' "$SCENEDELEGATE"; then
  echo "FATAL[B1p]: SceneDelegate frame 强制代码重新出现（会破坏全屏）" >&2; exit 2
fi
if grep -q 'TNBFlickerGuard.cover()' "$SCENEDELEGATE"; then
  echo "FATAL[B1p]: 闪屏遮罩重新出现（会破坏全屏）" >&2; exit 2
fi
if grep -q 'B1k\] fullscreen' "$LOGVC_FREEZE"; then
  echo "FATAL[B1p]: viewDidAppear frame 兜底重新出现（会破坏全屏）" >&2; exit 2
fi
if grep -q 'if false && !UserDefaults.standard.hasCompletedOnboarding' "$LOGVC_FREEZE"; then
  echo "FATAL[B1p]: 跳过引导页重新出现（新装会卡「正在启动」）" >&2; exit 2
fi
ok "B1p: 全屏 + 玻璃 v3 + B1j + 0419 启动链已冻结校验"

# B1r. 顶栏二级菜单基线（2026-11-27 用户截图反馈：标题被挤成 Tree...）
# ---------------------------------------------------------------------------
# 顶栏只保留一个左侧布局切换图标；星标/魔法棒/钥匙/安装全部收进右侧
# ellipsis.circle 菜单。禁止改回 ToolbarItemGroup 多按钮直排。
TOOLBAR="$ROOT/Sources/Container/ContainerRootView.swift"
grep -q 'ellipsis.circle' "$TOOLBAR" \
  || { echo "FATAL[B1r]: 顶栏二级菜单基线丢失" >&2; exit 2; }
if grep -q 'ToolbarItemGroup(placement: .navigationBarLeading)' "$TOOLBAR"; then
  echo "FATAL[B1r]: 左侧多按钮直排重新出现（会挤掉标题）" >&2
  exit 2
fi
ok "B1r: 顶栏二级菜单已冻结校验（左侧单图标 + 右侧 ⋯）"

# B1q. VPN 路由下 live UDID 查询规避（修 LocalDevVPN 路由下点定位必闪）
# ---------------------------------------------------------------------------
# 真机 .ips（2026-11-27 15:02:43 / 15:07:19，build 202611271439）经 Xcode 26
# dSYM 精确符号化，两份日志栈完全一致：
#   _platform_strlen → core::ffi::CStr::from_ptr → plist_new_string →
#   lockdownd_get_value → IdeviceGateway.syncGetLockdownValue(key:) →
#   IdeviceGateway.fetchUDID() → withFFIDispatch（com.apple.root.default-qos）。
# 也就是说闪退并非 DeveloperModeStatus，而是 **fetchUDID("UniqueDeviceID")**
# 在 LocalDevVPN 的 10.7.0.1/32 路由下进入 lockdownd FFI，C 字符串收到野指针
# -16 → strlen → SIGSEGV。B1n 只保护 Swift 侧 String(cString:)，保护不到
# Rust/C 内部的 CStr::from_ptr，所以 1439 包仍闪。
# 修法（两处，均不动定位会话本身）：
#   ① MinimuxerImpl.isReady() 里的 fetchUDID() 只用于 verbose 日志；VPN 已连
#      时直接跳过这次设备往返，用占位字符串写日志。
#   ② MinimuxerWrapper.fetchUDID(forceLive:) 在 VPN 已连时优先返回 Keychain
#      缓存；无缓存则抛出可恢复错误而不是进 FFI。
# 配对/定位/签名的真实设备操作仍走原路径，只是不再做这次致命的 UDID 在线校验。
MINIMUX_IMPL="$SSS/Dependencies/minimuxer/Sources/MinimuxerImpl.swift"
MINIMUX_WRAP="$SSS/SideStore/Core/DeviceApi/MinimuxerWrapper.swift"
for F in "$MINIMUX_IMPL" "$MINIMUX_WRAP"; do
  [ -f "$F" ] || { echo "FATAL[B1q]: 缺少 $F" >&2; exit 2; }
done
python3 - "$MINIMUX_IMPL" "$MINIMUX_WRAP" <<'PYB1Q'
import sys
impl_path, wrap_path = sys.argv[1:]

# ① isReady() 里的 UDID 只进 verboseLog，VPN 下跳过设备往返。
s = open(impl_path, encoding='utf-8').read()
old_ready = '''        let deviceUDID: String
        do {
            deviceUDID = try await fetchUDID()
        } catch {
            return .failure(error)
        }
'''
new_ready = '''        let deviceUDID: String
        // TreeNB[B1q]: VPN(utun/10.7.0.1) 下 fetchUDID 会进入 lockdownd FFI，
        // CStr::from_ptr 收到野指针 -16 → strlen → SIGSEGV（真机两次 .ips 已
        // dSYM 符号化确认）。这里的值只用于下面的 verboseLog，VPN 下用占位符。
        if self.network.isUTunAvailable {
            deviceUDID = "localVPN (live UDID check skipped by TreeNB[B1q])"
        } else {
            do {
                deviceUDID = try await fetchUDID()
            } catch {
                return .failure(error)
            }
        }
'''
if 'TreeNB[B1q]' in s:
    print('  B1q already present: MinimuxerImpl.swift')
else:
    if old_ready not in s:
        raise SystemExit('FATAL[B1q]: 未找到 isReady 的 fetchUDID 锚点')
    s = s.replace(old_ready, new_ready, 1)
    open(impl_path, 'w', encoding='utf-8').write(s)
    print('  B1q patched: MinimuxerImpl.swift')

# ② 强制在线 UDID 查询：VPN 下改走 Keychain 缓存，无缓存则抛出可恢复错误。
s = open(wrap_path, encoding='utf-8').read()
old_cache = '''    if !forceLive, let cachedUDID = Keychain.shared.deviceUDID, !cachedUDID.isEmpty {
        debugLog("[openSSS] fetchUDID() returning cached UDID from Keychain: \\(cachedUDID)")
        return cachedUDID
    }
'''
new_cache = '''    // TreeNB[B1q]: LocalDevVPN 已连时，live UDID 查询会进 lockdownd FFI 并
    // 因 C 字符串野指针 -16 直接 SIGSEGV。VPN 下即使 forceLive 也只认缓存；
    // 没有缓存就抛可恢复错误，绝不让进程走进 FFI。
    let vpnRouteActive = Minimuxer.shared.network.isUTunAvailable
    if (vpnRouteActive || !forceLive), let cachedUDID = Keychain.shared.deviceUDID, !cachedUDID.isEmpty {
        debugLog("[openSSS] fetchUDID() returning cached UDID from Keychain: \\(cachedUDID)")
        return cachedUDID
    }
    if vpnRouteActive {
        throw OperationError.unknownUDID(reason: "LocalDevVPN route active; live UDID check skipped by TreeNB[B1q]")
    }
'''
if 'TreeNB[B1q]' in s:
    print('  B1q already present: MinimuxerWrapper.swift')
else:
    if old_cache not in s:
        raise SystemExit('FATAL[B1q]: 未找到 fetchUDID 缓存锚点')
    s = s.replace(old_cache, new_cache, 1)
    open(wrap_path, 'w', encoding='utf-8').write(s)
    print('  B1q patched: MinimuxerWrapper.swift')
PYB1Q
for F in "$MINIMUX_IMPL" "$MINIMUX_WRAP"; do
  grep -q 'TreeNB\[B1q\]' "$F" \
    || { echo "FATAL[B1q]: $F 未写入 VPN 防护" >&2; exit 2; }
done
ok "B1q: live UDID 查询在 VPN 路由下已改为缓存/占位，杜绝 lockdownd FFI 野指针"

# B1s. 定位页 DeveloperModeStatus 查询 VPN 下跳过（修 1620 包点定位必闪）
# ---------------------------------------------------------------------------
# 真机 .ips（2026-11-27 18:34:34，build 202611271620，UUID 88219666-2392-3715-
# 97b0-60b9c3268757）用 UUID 完全匹配的 dSYM 精确符号化：
#   _platform_strlen → core::ffi::CStr::from_ptr → plist_new_string →
#   lockdownd_get_value → IdeviceGateway.syncIsDeveloperModeEnabled() →
#   IdeviceGateway.isDeveloperModeEnabled() → withFFIDispatch。
# 上次 B1q 用的是 UUID 不匹配的诊断 dSYM（5AA54F4D vs 崩溃日志 a4e2b4ff），
# 误判成 fetchUDID，只堵了 UDID 那条 lockdownd 查询，这条 DeveloperModeStatus
# 没堵，于是 1620 包点定位仍闪。
# 0419 完美基线是纯 Container 壳 + location_simulation_stubs.c，定位页根本
# 不进 IdeviceGateway 的 lockdownd FFI，所以不闪。
# 修法（不动定位会话本身）：VPN(utun/10.7.0.1) 已连时，isDeveloperModeEnabled()
# 直接返回安全值 true（假定已开启），setLocation catch 里的二次查询同样跳过。
# 只影响这个纯展示用的开发者模式状态；虚拟定位(DVT)、配对、签名全走原路径。
LOCSVC="$SSS/AltStore/Shell/LocationSimulationService.swift"
if [ -f "$LOCSVC" ]; then
  python3 - "$LOCSVC" <<'PYB1S'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

old_dev = '''    /// Reads Developer Mode from the device (lockdown DeveloperModeStatus).
    func isDeveloperModeEnabled() async throws -> Bool
    {
        do
        {
            return try await gateway.isDeveloperModeEnabled()
        }
        catch
        {
            throw Self.mapError(error)
        }
    }
'''
new_dev = '''    /// Reads Developer Mode from the device (lockdown DeveloperModeStatus).
    func isDeveloperModeEnabled() async throws -> Bool
    {
        // TreeNB[B1s]: VPN(utun / 10.7.0.1/32) 下 DeveloperModeStatus 的
        // lockdownd_get_value 会进 Rust CStr::from_ptr 野指针 -16 → SIGSEGV
        // （真机 .ips 2026-11-27 18:34，UUID 匹配的 dSYM 已确认）。
        // VPN 下假定开发者模式已开启，不进设备 FFI；定位会话本身不动。
        if tnbLocationVPNRouteActive() { return true }
        do
        {
            return try await gateway.isDeveloperModeEnabled()
        }
        catch
        {
            throw Self.mapError(error)
        }
    }
'''

old_catch = '''            if let developerMode = try? await gateway.isDeveloperModeEnabled(), !developerMode
'''
new_catch = '''            // TreeNB[B1s]: VPN 下跳过 DeveloperModeStatus 查询，避免 FFI 野指针闪退。
            if !tnbLocationVPNRouteActive(),
               let developerMode = try? await gateway.isDeveloperModeEnabled(), !developerMode
'''

helper = '''
// TreeNB[B1s] VPN 路由检测：LocalDevVPN 连上后系统多出 utun 接口。
// 仅用于跳过定位页纯展示用的 DeveloperModeStatus 查询，不改变定位会话。
@inline(__always)
private func tnbLocationVPNRouteActive() -> Bool {
    Minimuxer.shared.network.isUTunAvailable
}
// ===== /TreeNB[B1s] =====
'''

if 'TreeNB[B1s]' in s:
    print('  B1s already present:', p.split('/')[-1])
else:
    if old_dev not in s:
        raise SystemExit('FATAL[B1s]: 未找到 isDeveloperModeEnabled 锚点')
    if old_catch not in s:
        raise SystemExit('FATAL[B1s]: 未找到 setLocation catch 锚点')
    s = s.replace(old_dev, new_dev, 1)
    s = s.replace(old_catch, new_catch, 1)
    idx = s.rfind('\n#endif')
    if idx < 0:
        raise SystemExit('FATAL[B1s]: 未找到文件末尾 #endif')
    s = s[:idx] + '\n' + helper + s[idx:]
    open(p, 'w', encoding='utf-8').write(s)
    print('  B1s patched: LocationSimulationService.swift')
PYB1S
  grep -q 'TreeNB\[B1s\]' "$LOCSVC" \
    || { echo "FATAL[B1s]: 定位 DeveloperModeStatus VPN 防护未写入" >&2; exit 2; }
  ok "B1s: 定位页 DeveloperModeStatus 查询在 VPN 下已跳过"
else
  echo "FATAL[B1s]: 缺少 $LOCSVC，无法修复定位闪退" >&2
  exit 2
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
# Husk 翻译层 UI / 数据层（APK 列表 + 游戏运行视图）挂进主 App source 树。
# 这些文件 import HuskyEngine（独立 framework），由 project.yml 的 HuskyEngine target 提供。
cp "$ROOT/Sources/Container/HuskyAPKStore.swift"  "$SSS/AltStore/TreeNB/Container/" 2>/dev/null || true
cp "$ROOT/Sources/Container/HuskyAPKView.swift"   "$SSS/AltStore/TreeNB/Container/" 2>/dev/null || true
cp "$ROOT/Sources/Container/HuskyGameView.swift"  "$SSS/AltStore/TreeNB/Container/" 2>/dev/null || true
# SideStore.debugLog 兼容层（上游把它当 module 限定调用，单包后 module 不存在）。
# 注意：不再复制 location_simulation_stubs.c —— IDevice 现已用带 location_simulation
# 的自编译产物（见 build_idevice.sh / A6），再编 C 桩会 duplicate symbol。
cp "$ROOT/Sources/Compat/SideStoreCompat.swift" "$SSS/AltStore/TreeNB/" 2>/dev/null || true
# 闪屏抑制遮罩（需在 sceneWillEnterForeground 可见，挂到主 App 源码树根）
cp "$ROOT/Sources/UI/TNBFlickerGuard.swift" "$SSS/AltStore/TreeNB/" 2>/dev/null || true
cp "$ROOT/Sources/Widget/"*.swift    "$SSS/AltWidget/TreeNB/"         2>/dev/null || true
# LC 引擎桥接层挂进 LiveContainer 源码树（framework target 从这里编译）
mkdir -p "$LC/LiveContainer/TreeNBBridge/include"
cp "$ROOT/Sources/Bridge/LCEngineEntry.m"      "$LC/LiveContainer/TreeNBBridge/" 2>/dev/null || true
cp "$ROOT/Sources/Bridge/include/"*            "$LC/LiveContainer/TreeNBBridge/include/" 2>/dev/null || true
# Spike 探针也挂进主 App（DEBUG 门禁）
cp "$ROOT/Sources/Spike/"*.swift "$SSS/AltStore/TreeNB/" 2>/dev/null || true
ok "适配源码已挂载（Container/Routing/Widget/Bridge/Spike/HuskyUI）"

# ---------------------------------------------------------------------------
# C2. 安卓 APK 入口（在「树🌲应用」Tab 的加号里）
# ---------------------------------------------------------------------------
# 入口现已直接写在 Sources/Container/ContainerRootView.swift（经 C1 源码挂载进主 target）：
# 容器页右上角加号 → confirmationDialog「安装 IPA / 安装安卓 APK」→ 弹出 HuskyAPKView。
# 之前误挂在开放侧载页 AppsViewController（=「树🌲侧载」Tab），已移除——APK 属于容器/应用页，
# 与用户心智一致。此处不再 patch 上游任何文件，仅做存在性校验。
log "校验安卓 APK 入口（树🌲应用 Tab 加号）"
grep -q 'showAPK' "$ROOT/Sources/Container/ContainerRootView.swift" \
  || { echo "FATAL[Husky]: ContainerRootView 缺少 showAPK 状态，APK 入口丢失" >&2; exit 3; }
grep -q '安装安卓 APK' "$ROOT/Sources/Container/ContainerRootView.swift" \
  || { echo "FATAL[Husky]: ContainerRootView 缺少 APK 菜单项" >&2; exit 3; }
grep -q 'HuskyAPKView()' "$ROOT/Sources/Container/ContainerRootView.swift" \
  || { echo "FATAL[Husky]: ContainerRootView 未挂载 HuskyAPKView" >&2; exit 3; }
ok "安卓 APK 入口已在树🌲应用 Tab 加号（已校验）"

# ---------------------------------------------------------------------------
# D. 身份归一：bundle id / App Group（报告 §3.6）
# ---------------------------------------------------------------------------
log "D. 身份归一（bundle id / App Group / URL scheme）"
grep -rl "com.kdt.livecontainer.treeWidget" "$LC/TreeWidget" 2>/dev/null | while read -r f; do
  sed -i '' 's/com\.kdt\.livecontainer\.treeWidget/com.openssai.app.treeWidget/g' "$f" 2>/dev/null || \
  sed -i 's/com\.kdt\.livecontainer\.treeWidget/com.openssai.app.treeWidget/g' "$f"
done
ok "Widget Keychain service 已归一为 com.openssai.app.treeWidget"

# ---------------------------------------------------------------------------
# E1. 全 App 液态玻璃（导航栏 + Tab 栏）
# ---------------------------------------------------------------------------
# 只改控件层，符合 HIG——玻璃不进内容层。
# v1 用 swizzling 往 bar 里插自定义 UIVisualEffectView，真机穿模（blur 盖住
# 大标题/内容）且 appearance 被清空后没有玻璃。v2 改用系统
# UIBarAppearance.backgroundEffect = .systemUltraThinMaterial：由 UINavigationBar /
# UITabBar 自己管理背景 blur，层级正确，iOS13~27 都有真实动态毛玻璃。
# 用 marker 幂等，锚点精确匹配，找不到直接 FATAL（不静默失败）。
log "E1. 全 App 玻璃拟态（导航栏 + Tab 栏）"
SHELL_GLASS="$SSS/AltStore/Shell/ShellTabBarController.swift"
if [ -f "$SHELL_GLASS" ]; then
  python3 - "$SHELL_GLASS" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
orig = s
changes = []

# 1) 导航栏：系统 appearance 自带毛玻璃背景，标题/按钮层级不受影响
a_nav = '''        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = ShellTheme.background
        appearance.shadowColor = .clear
'''
b_nav = '''        // TREENB_GLASS_THEME_V2: 用系统 backgroundEffect 生成毛玻璃背景；
        // 不再手动插 UIVisualEffectView（v1 会穿模盖住大标题与内容）。
        let appearance = GlassChrome.makeNavigationAppearance()
'''
if 'TREENB_GLASS_THEME_V2' not in s:
    if a_nav not in s:
        sys.stderr.write('FATAL[Glass]: 导航栏背景锚点未找到，上游结构已变\n')
        sys.exit(2)
    s = s.replace(a_nav, b_nav, 1)
    changes.append('导航栏玻璃')

    # 2) Tab 栏：在 viewDidLoad 的 tabBar.tintColor 后注入系统毛玻璃 appearance
    a_tab = '''        tabBar.tintColor = ShellTheme.accentColor

        NotificationCenter.default.addObserver(
'''
    b_tab = '''        tabBar.tintColor = ShellTheme.accentColor

        // TREENB_GLASS_THEME_V2: 系统 backgroundEffect 毛玻璃，层级正确不穿模。
        tabBar.standardAppearance = GlassChrome.makeTabBarAppearance()
        if #available(iOS 15.0, *) {
            tabBar.scrollEdgeAppearance = tabBar.standardAppearance
        }
        tabBar.isTranslucent = true

        NotificationCenter.default.addObserver(
'''
    if a_tab not in s:
        sys.stderr.write('FATAL[Glass]: Tab 栏 tintColor 锚点未找到\n')
        sys.exit(3)
    s = s.replace(a_tab, b_tab, 1)
    changes.append('Tab 栏玻璃')

    open(p, 'w', encoding='utf-8').write(s)
    print('  ShellTabBarController.swift: ' + '；'.join(changes))
else:
    print('  ShellTabBarController.swift: 已含 TREENB_GLASS_THEME_V2，跳过')
PY
  # 硬校验：v2 marker 必须落地，且不透明背景/手动插子视图必须已移除
  grep -q 'TREENB_GLASS_THEME_V2' "$SHELL_GLASS" \
    || { echo "FATAL[Glass]: v2 玻璃主题 marker 未注入" >&2; exit 4; }
  grep -q 'GlassChrome.makeNavigationAppearance()' "$SHELL_GLASS" \
    || { echo "FATAL[Glass]: 导航栏未使用 GlassChrome v2 appearance" >&2; exit 4; }
  if grep -q 'appearance.configureWithOpaqueBackground()' "$SHELL_GLASS"; then
    echo "FATAL[Glass]: 导航栏仍为不透明背景，玻璃化失败" >&2; exit 5
  fi
  ok "全 App 玻璃主题已注入（导航栏 + Tab 栏）"
else
  warn "ShellTabBarController.swift 未找到，跳过玻璃主题"
fi

# E1.2 进程入口安装玻璃 swizzler（覆盖模态导航控制器等所有 bar）。
log "E1.2 进程入口安装 GlassChrome"
MAIN_GLASS="$SSS/AltStore/main.swift"
if [ -f "$MAIN_GLASS" ]; then
  python3 - "$MAIN_GLASS" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'GlassChrome.install()' not in s:
    anchor = 'UIApplicationMain(\n'
    if anchor not in s:
        sys.stderr.write('FATAL[Glass]: main.swift 缺少 UIApplicationMain 锚点\n')
        sys.exit(6)
    s = s.replace(anchor, 'GlassChrome.install()\n\n' + anchor, 1)
    open(p, 'w', encoding='utf-8').write(s)
    print('  main.swift: 已注入 GlassChrome.install()')
else:
    print('  main.swift: GlassChrome.install() 已存在')
PY
  grep -q 'GlassChrome.install()' "$MAIN_GLASS" \
    || { echo "FATAL[Glass]: GlassChrome.install() 未注入 main.swift" >&2; exit 7; }
  ok "GlassChrome 已挂到进程入口"
else
  echo "FATAL[Glass]: 缺少 $MAIN_GLASS" >&2
  exit 8
fi


# B1k（仅保留文案归一）。2026-11-27 12:25 修正。
# ---------------------------------------------------------------------------
# 真机反馈：覆盖更新后进 OnboardingView 看到 Welcome to openSSS。
# 根因：OnboardingView.swift 的 NSLocalizedString key 从未被品牌补丁覆盖（只改了 .strings value）。
# 修法：OnboardingView.swift 全部 openSSS key → 🌲TreeNB。
#
# 【已撤销】原 B1k ①「跳过引导页」：把 `if !hasCompletedOnboarding` 改成 `if false && ...`
#   会导致新装包 finishLaunching() 命中 `if !hasCompletedOnboarding { ... return }` 早退，
#   永远不调用 transitionToMainInterface() → 卡在 SplashView「正在启动…」。
#   0419 的引导页在全屏窗口下按钮可点，回退到 0419 行为即可，不再跳过。
# 【已撤销】原 B1k ③「frame 全屏兜底」：恢复 0419 窗口行为。
LOGVC="$SSS/AltStore/LaunchViewController.swift"
ONBOARD="$SSS/SideStore/Views/Onboarding/OnboardingView.swift"

# ② OnboardingView.swift 文案归一（key 本身必须改，改 .strings value 无效）。
if [ -f "$ONBOARD" ]; then
  python3 - "$ONBOARD" <<'PY4'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
reps=[
 ('Welcome to openSSS','Welcome to 🌲TreeNB'),
 ('connects openSSS to','connects 🌲TreeNB to'),
 ('openSSS uses a pairing file','🌲TreeNB uses a pairing file'),
 ('openSSS communicates with','🌲TreeNB communicates with'),
 ('openSSS requires an Apple ID','🌲TreeNB requires an Apple ID'),
 ('openSSS setup is complete','🌲TreeNB setup is complete'),
 ('You can enter openSSS,','You can enter 🌲TreeNB,'),
 ('Open openSSS','Open 🌲TreeNB'),
]
for a,b in reps: s=s.replace(a,b)
open(p,'w',encoding='utf-8').write(s)
print('  OnboardingView.swift: 8 处 openSSS → 🌲TreeNB（B1k）')
PY4
  if grep -q 'openSSS' "$ONBOARD"; then
    echo "FATAL[B1k]: OnboardingView.swift 仍残留 openSSS" >&2; exit 12
  fi
  ok "B1k: OnboardingView 文案已全部归一"
else
  warn "B1k: 未找到 $ONBOARD，跳过文案归一"
fi

log "✅ 全部补丁执行完毕。下一步：xcodegen generate && 真机 Spike（docs/启动链改造设计.md §5）"
