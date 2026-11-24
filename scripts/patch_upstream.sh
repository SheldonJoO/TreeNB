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

# A6. minimuxer/DeviceGateway 的 IDevice.xcframework 指向构建机本地目录（不进 git），
#     CI 上 SPM 会报 "does not contain a binary artifact"。切到上游注释里保留的
#     官方 release URL + checksum（同一份二进制，仅来源不同）。
DG_PKG="$SSS/Dependencies/minimuxer/DeviceGateway/Package.swift"
if [ -f "$DG_PKG" ]; then
  python3 - "$DG_PKG" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
needle = 'path: "../../../local/idevice/swift/IDevice.xcframework"'
replacement = ('url: "https://github.com/SideStore/idevice/releases/download/'
               'v0.1.68-ss-3e55c84/idevice-xcframework-v0.1.68-ss-3e55c84.zip#DeviceGateway",\n'
               '        checksum: "445702d53942597deb4cdec2c4122d16a3f4ac124ce26cd75b68dab3dad92416"')
if needle in s:
    s = s.replace(needle, replacement, 1)
    open(p, 'w', encoding='utf-8').write(s)
    print('  DeviceGateway/Package.swift: IDevice 已改从 release URL 获取')
else:
    print('  DeviceGateway/Package.swift: 无需改（已切换或上游已变）')
PY
else
  warn "DeviceGateway/Package.swift 缺失，跳过 IDevice 修复"
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
            title: "容器",
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

# B1b. AppDelegate：注入 guest 冷启动接管钩子（容器里点 App 的真实启动入口）
# 原理：上游 LC 启动 guest 是「写 selected 键 → 重启进程 → 冷启动时 main 调
# LiveContainerMain 接管」。TreeNB 主入口是 openSSS 的 @UIApplicationMain，
# 没有这个冷启动钩子，导致此前热调 LiveContainerMain 直接闪退。
# 这里在 didFinishLaunchingWithOptions 最顶部调用 LCEngineEntry.takeOverIfGuestPending()：
# 有 guest 待启动就把进程交给它（不返回），没有就返回 NO 让 openSSS 正常起。
APPDELEGATE="$SSS/AltStore/AppDelegate.swift"
if [ -f "$APPDELEGATE" ]; then
  python3 - "$APPDELEGATE" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
orig = s

# 锚点：didFinishLaunchingWithOptions 的函数头 + 左大括号
anchor = '''    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    {
'''
hook = '''    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    {
        // TreeNB: guest 冷启动接管。若容器里点过某个 guest，进程在此时把主线权
        // 交给它（LiveContainerMain → invokeAppMain，正常不返回）；否则返回 NO，
        // openSSS 照常启动。必须放在所有 UI/日志初始化之前。
        if LCEngineEntry.takeOverIfGuestPending() {
            return true
        }
'''
if 'takeOverIfGuestPending' not in s:
    if anchor not in s:
        sys.stderr.write('FATAL[B1b]: didFinishLaunchingWithOptions 锚点未找到，上游 AppDelegate 结构已变\n')
        sys.exit(2)
    s = s.replace(anchor, hook, 1)

# 确保 import LiveContainerShared（modulemap 已让 Swift 可见）
if 'LCEngineEntry.takeOverIfGuestPending' in s and 'import LiveContainerShared' not in s:
    # 插到第一个 import 之后
    lines = s.splitlines(keepends=True)
    for i, ln in enumerate(lines):
        if ln.startswith('import '):
            lines.insert(i + 1, 'import LiveContainerShared\n')
            break
    s = ''.join(lines)

if s != orig:
    open(p, 'w', encoding='utf-8').write(s)
    print('  AppDelegate.swift: 已注入 guest 冷启动接管钩子')
else:
    print('  AppDelegate.swift: 冷启动钩子已存在（幂等）')
PY
  grep -q 'takeOverIfGuestPending' "$APPDELEGATE" \
    || { echo "FATAL[B1b]: 冷启动钩子未注入 AppDelegate，拒绝继续构建" >&2; exit 2; }
  ok "AppDelegate.swift: guest 冷启动接管钩子已挂载并通过校验"
else
  echo "FATAL[B1b]: 缺少 $APPDELEGATE，无法注入冷启动钩子" >&2
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
# SideStore.debugLog 兼容层 + IDevice 定位模拟符号补齐桩
# SideStore.debugLog：上游把它当 module 限定调用，单包后 module 不存在。
# location_simulation_*：官方 release IDevice.xcframework 没编这个功能，缺符号。
cp "$ROOT/Sources/Compat/"*.swift    "$SSS/AltStore/TreeNB/"          2>/dev/null || true
cp "$ROOT/Sources/Compat/"*.c        "$SSS/AltStore/TreeNB/"          2>/dev/null || true
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
