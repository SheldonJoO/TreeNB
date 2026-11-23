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

  # 4b. 兜底：确保 scheme 含 ArchiveAction
  # xcodegen 不同版本对空 archive:{} 的处理不一致，早期版本可能不生成
  # ArchiveAction，导致 xcodebuild archive 直接报 "not configured for archive"。
  # 这里校验并在缺失时注入一个指向主 App 的 ArchiveAction。
  python3 - <<'PYEOF'
import glob, os, re, sys
schemes = glob.glob('TreeNB.xcodeproj/xcshareddata/xcschemes/*.xcscheme') + \
          glob.glob('TreeNB.xcodeproj/xcuserdata/*/xcschemes/*.xcscheme')
target = [p for p in schemes if os.path.basename(p) == 'TreeNB.xcscheme']
if not target:
    print('[warn] 未找到 TreeNB.xcscheme，跳过 ArchiveAction 校验')
    sys.exit(0)
p = target[0]
s = open(p, encoding='utf-8').read()
if '<ArchiveAction' in s:
    print('[ ok ] TreeNB.xcscheme 已含 ArchiveAction')
    sys.exit(0)
# 找一个 application target 的 BuildableReference 块
m = re.search(r'<BuildableReference[^>]*BuildableName="TreeNB\.app"[^>]*/>', s)
if not m:
    m = re.search(r'<BuildableReference\b[^>]*/>', s)
if not m:
    print('[warn] 无 BuildableReference，无法注入 ArchiveAction')
    sys.exit(0)
ref = m.group(0)
# 提取 BlueprintIdentifier / BuildableName / BlueprintName
def attr(a):
    x = re.search(a + r'="([^"]*)"', ref)
    return x.group(1) if x else ''
entry = (f'      <BuildableEntry '
         f'BuildableIdentifier="primary" '
         f'BlueprintIdentifier="{attr("BlueprintIdentifier")}" '
         f'BuildableName="{attr("BuildableName")}" '
         f'BlueprintName="{attr("BlueprintName")}" '
         f'ReferencedContainer="container:TreeNB.xcodeproj"/>')
archive = ('   <ArchiveAction\n'
           '      buildConfiguration="Release"\n'
           '      revealArchiveInOrganizer="YES">\n'
           '      <BuildActionEntries>\n'
           f'{entry}\n'
           '      </BuildActionEntries>\n'
           '   </ArchiveAction>\n')
s = s.replace('</Scheme>', archive + '</Scheme>')
open(p, 'w', encoding='utf-8').write(s)
print('[ ok ] 已为 TreeNB.xcscheme 注入 ArchiveAction（兜底）')
PYEOF
else
  warn "本机无 xcodegen —— CI runner 上会安装。本地可手动：brew install xcodegen && xcodegen generate"
fi

ok "全部依赖与补丁就绪"
