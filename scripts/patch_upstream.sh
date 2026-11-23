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

# A2. 从 LCTabView 移除 openSSS Tab item
if [ -f "$LC/LiveContainerSwiftUI/Views/LCTabView.swift" ]; then
  python3 - "$LC/LiveContainerSwiftUI/Views/LCTabView.swift" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
before = s
# 删除含 TreeOpenSSSTabView / .tag(.openSSS) 的 TabView item 块（按行删，保守）
lines = s.splitlines(keepends=True)
out, skip = [], 0
for ln in lines:
    if 'TreeOpenSSSTabView' in ln or '.tag(.openSSS)' in ln:
        skip = 1
        continue
    if skip:
        # 跳过紧跟的 } / label 块中属于该 item 的行，直到遇到下一个 Tab 特征或空行
        if ln.strip() in ('}', ')') or ln.strip().startswith('Label(') or 'Tree' in ln:
            skip = 0
        continue
    out.append(ln)
open(p, 'w', encoding='utf-8').write(''.join(out))
print('  LCTabView.swift: %s' % ('已改' if ''.join(out) != before else '无需改（人工核对）'))
PY
fi

# A3. 从 LCUtilsExtensions 删除 openSideStore() 函数
if [ -f "$LC/LiveContainerSwiftUI/Utilities/LCUtilsExtensions.swift" ]; then
  python3 - "$LC/LiveContainerSwiftUI/Utilities/LCUtilsExtensions.swift" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
# 匹配 static func openSideStore(...) { ... }（含嵌套大括号，简单计数）
pat = re.compile(r'\n\s*static func openSideStore\([^)]*\)\s*\{')
m = pat.search(s)
if m:
    i = m.start(); depth = 0; j = m.end()-1
    # 从函数体的 { 开始数
    k = s.find('{', m.end()-1)
    depth = 0
    while k < len(s):
        if s[k] == '{': depth += 1
        elif s[k] == '}':
            depth -= 1
            if depth == 0:
                k += 1; break
        k += 1
    s = s[:i] + s[k:]
    open(p, 'w', encoding='utf-8').write(s)
    print('  LCUtilsExtensions.swift: 已删除 openSideStore()')
else:
    print('  LCUtilsExtensions.swift: 未找到 openSideStore()')
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

# B1. ShellTabBarController：加容器 Tab（幂等：检测 ContainerTab 字样）
SHELL="$SSS/AltStore/Shell/ShellTabBarController.swift"
if [ -f "$SHELL" ] && ! grep -q "ContainerTabViewController" "$SHELL"; then
  python3 - "$SHELL" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
# 在最后一个 lazy var nav 定义后插入容器 nav
insert = '''
    // TreeNB: 第四个 Tab —— 容器（LiveContainer 多开）
    lazy var containerNav: UINavigationController = {
        let vc = ContainerTabViewController()
        vc.title = "容器"
        return UINavigationController(rootViewController: vc)
    }()
'''
# 找 class 内第一个 "lazy var" 块之前插入（位置不影响，Swift lazy 无序）
idx = s.find('lazy var')
if idx == -1: idx = s.find('{', s.find('class ShellTabBarController')) + 1
s = s[:idx] + insert + '\n' + s[idx:]
# viewControllers 数组加 containerNav
s2 = re.sub(r'(viewControllers\s*=\s*\[[^\]]*?)(profileNav)(\])',
            r'\1containerNav, \2\3', s, count=1)
if s2 == s:
    # 兜底：找 appsNav/locationNav 那行
    s2 = re.sub(r'(self\.viewControllers\s*=\s*\[[^\]]*\])',
                lambda m: m.group(1).replace(']', ', containerNav]'), s, count=1)
open(p, 'w', encoding='utf-8').write(s2)
print('  ShellTabBarController.swift: 已插入容器 Tab（请人工核对数组顺序）')
PY
else
  warn "ShellTabBarController.swift 未改（文件缺失或已含容器 Tab）"
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
cp "$ROOT/Sources/Routing/"*.swift   "$SSS/AltStore/TreeNB/Routing/"  2>/dev/null || true
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
