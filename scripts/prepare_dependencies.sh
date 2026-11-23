#!/usr/bin/env bash
# TreeNB 依赖准备（CI 与本地通用）
#   1. 浅克隆/更新两个上游仓库到 upstream/
#   2. 下载 OpenSSL.xcframework（openSSS 签名栈依赖）
#   3. 跑 patch_upstream.sh 做单包改造
#   4. xcodegen generate 生成 TreeNB.xcodeproj
# 幂等：已存在的仓库只 fetch，不重下。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

log() { printf '\033[1;34m[prepare]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[  ok  ]\033[0m %s\n' "$*"; }

clone_or_update() {
  local url="$1" dir="$2"
  if [ -d "$dir/.git" ]; then
    log "更新 $dir ..."
    git -C "$dir" fetch --depth 1 origin 2>/dev/null || warn "fetch 失败，沿用现有"
    git -C "$dir" reset --hard origin/HEAD 2>/dev/null || true
  else
    log "浅克隆 $url → $dir"
    # 用 tarball 优先（比 git protocol 抗网络抖动），失败退回 git clone
    if ! (mkdir -p "$dir" && curl -fL --retry 4 --retry-delay 2 --max-time 180 \
            "https://codeload.github.com/${url#https://github.com/}/tar.gz/refs/heads/main" \
            -o /tmp/$(basename "$dir").tar.gz && \
          tar xzf /tmp/$(basename "$dir").tar.gz -C "$dir" --strip-components=1 && \
          rm -f /tmp/$(basename "$dir").tar.gz); then
      warn "tarball 失败，改 git clone"
      rm -rf "$dir"
      git clone --depth 1 "$url" "$dir"
    fi
  fi
  ok "$(basename "$dir") 就绪 ($(du -sh "$dir" | cut -f1))"
}
warn() { printf '\033[1;33m[ warn ]\033[0m %s\n' "$*"; }

mkdir -p upstream

# 1. 上游源码
clone_or_update https://github.com/SheldonJoO/openSSS.git      "$ROOT/upstream/openSSS"
clone_or_update https://github.com/SheldonJoO/TreeNewBee.git   "$ROOT/upstream/TreeNewBee"

# 2. OpenSSL.xcframework（openSSS 签名栈）
if [ ! -d "Dependencies/OpenSSL.xcframework" ]; then
  log "下载 OpenSSL.xcframework"
  mkdir -p Dependencies
  curl -fL --retry 3 -o /tmp/OpenSSL.xcframework.zip \
    https://github.com/krzyzanowskim/OpenSSL/releases/download/3.6.5000/OpenSSL.xcframework.zip
  unzip -q /tmp/OpenSSL.xcframework.zip -d Dependencies/
  rm -f /tmp/OpenSSL.xcframework.zip
  # Xcode 16.4 不认第三方签名
  find Dependencies/OpenSSL.xcframework -name "_CodeSignature" -type d -exec rm -rf {} + 2>/dev/null || true
  ok "OpenSSL 就绪"
else
  ok "OpenSSL.xcframework 已存在，跳过"
fi

# 3. 结构性改造（删除跳转分支 / 身份归一 / Widget 并入 / 挂载适配源码）
log "执行上游改造补丁"
bash ./scripts/patch_upstream.sh

# 4. 生成工程
if command -v xcodegen >/dev/null 2>&1; then
  log "xcodegen generate"
  xcodegen generate
  ok "TreeNB.xcodeproj 已生成"

  # 4b. 兜底：强制重建 TreeNB scheme 的 ArchiveAction
  # xcodegen 的 archive:{} 在部分版本生成的 ArchiveAction 没有 BuildableEntry，
  # xcodebuild archive 会报 "Scheme is not currently configured for the archive action"。
  # 这里从 BuildAction 段抓 TreeNB.app 的 BuildableReference，重建完整 ArchiveAction。
  python3 - <<'PYEOF'
import glob, os, re, sys
# 优先 shared scheme，兜底 user scheme
schemes = glob.glob('TreeNB.xcodeproj/xcshareddata/xcschemes/TreeNB.xcscheme') + \
          glob.glob('TreeNB.xcodeproj/xcuserdata/*/xcschemes/TreeNB.xcscheme')
if not schemes:
    print('[error] 未找到 TreeNB.xcscheme')
    sys.exit(1)
p = schemes[0]
print('[dbg] scheme path:', p)
s = open(p, encoding='utf-8').read()

# 从任意 BuildableReference 里找主 App 的（含自闭合与成对两种）
refs = re.findall(r'<BuildableReference\b[^>]*?(?:/>|</BuildableReference>)', s, re.S)
print('[dbg] scheme 前 2500 字符:')
print(s[:2500])
app_ref = None
for r in refs:
    bn = re.search(r'BuildableName="([^"]*)"', r)
    if bn and bn.group(1).endswith('.app') and 'Widget' not in bn.group(1):
        app_ref = r
        break
if app_ref is None:
    print('[error] scheme 中找不到任何 .app 的 BuildableReference')
    sys.exit(1)
# 规范化为自闭合标签（去掉可能的 </BuildableReference>）
app_ref = re.sub(r'</BuildableReference>\s*$', '/>', app_ref).strip()

entry = ('         <BuildActionEntry\n'
         '            buildForTesting="YES"\n'
         '            buildForRunning="YES"\n'
         '            buildForProfiling="YES"\n'
         '            buildForArchiving="YES"\n'
         '            buildForAnalyzing="YES">\n'
         f'            {app_ref}\n'
         '         </BuildActionEntry>')
archive = ('   <ArchiveAction\n'
           '      buildConfiguration="Release"\n'
           '      revealArchiveInOrganizer="YES">\n'
           '      <BuildActionEntries>\n'
           f'{entry}\n'
           '      </BuildActionEntries>\n'
           '   </ArchiveAction>\n')

# 移除已有的 ArchiveAction（自闭合或成对），再注入新的
s2 = re.sub(r'\s*<ArchiveAction\b[^>]*?/>', '', s)
s2 = re.sub(r'\s*<ArchiveAction\b.*?</ArchiveAction>', '', s2, flags=re.S)
s2 = s2.replace('</Scheme>', archive + '</Scheme>')
open(p, 'w', encoding='utf-8').write(s2)
# 打印校验信息便于日志核对
bp = re.search(r'BlueprintIdentifier="([^"]*)"', app_ref)
print('[ ok ] ArchiveAction 已重建，指向 TreeNB.app (Blueprint=' + (bp.group(1) if bp else '?') + ')')
PYEOF
else
  warn "本机无 xcodegen —— CI runner 上会安装。本地可手动：brew install xcodegen && xcodegen generate"
fi

ok "全部依赖与补丁就绪"
