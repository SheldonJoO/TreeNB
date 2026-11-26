#!/bin/sh
# TreeNB 免电脑首次安装引导脚本（siboot 风格，运行在 Open Minis 的 shell 里）
#
# 设计目标：用户只需在 Open Minis 里粘贴一条命令，剩下的全自动。
# 本脚本负责：
#   1) 检测环境（iOS 版本、下载工具）
#   2) 从发布站点下载 TreeNB 无签名 IPA（同站托管，不依赖 GitHub Release）
#   3) 调用签名安装引擎（siboot 兼容接口）完成配对 + 签名 + 安装
#
# ⚠️ 诚实标注（第一版现状）：
#   - 步骤 1、2 在本机 shell 里可独立完成，逻辑已写好。
#   - 步骤 3 的"签名安装引擎"是本项目的自研攻坚点：需要实现与 siboot 等价的
#     RPPairing 自配对 + anisette 签名 + 本机安装。在引擎就绪前，本脚本会
#     明确提示"引擎未部署"，不会假装安装成功。
#   - 不要把它当作已验证的成品；它是一份可执行的集成框架 + 接口约定。

set -eu

TNB_BOOTSTRAP_VERSION="1.1"

# IPA 地址：优先用第 1 个参数（网页生成的命令会把同站 IPA 绝对地址传进来），
# 其次用环境变量，最后回退到 GitHub Release 兼容地址。
SITE_IPA_URL="${1:-${TNB_IPA_URL:-}}"
IPA_URL="${SITE_IPA_URL:-https://github.com/SheldonJoO/TreeNB/releases/latest/download/TreeNB-unsigned.ipa}"
WORKDIR="${HOME}/.treenb-bootstrap"
ENGINE_URL="${TNB_ENGINE_URL:-https://github.com/SheldonJoO/TreeNB/releases/latest/download/tnb-bootstrap-aarch64}"

say() { printf '\n[TNB] %s\n' "$*"; }
fail() { printf '\n[TNB] 错误：%s\n' "$*" >&2; exit 1; }

say "TreeNB 免电脑安装引导 v${TNB_BOOTSTRAP_VERSION}"

# ---- 步骤 1：环境检测 ----
say "检查运行环境…"
command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 \
  || fail "找不到下载工具（wget / curl）。"

# iOS 版本：siboot 那条纯免电脑路径要求 iOS 27+
if [ -f /System/Library/CoreServices/SystemVersion.plist ]; then
  IOS_VER=$(grep -A1 ProductVersion /System/Library/CoreServices/SystemVersion.plist \
    | tail -1 | sed -E 's/.*<string>([0-9]+).*/\1/' 2>/dev/null || echo "?")
  say "检测到 iOS 主版本：${IOS_VER}"
else
  IOS_VER="?"
  say "无法读取系统版本，继续尝试。"
fi

mkdir -p "$WORKDIR"

# ---- 步骤 2：下载 TreeNB IPA ----
say "下载 TreeNB 安装包…"
IPA="$WORKDIR/TreeNB-unsigned.ipa"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --retry 3 "$IPA_URL" -o "$IPA" || fail "IPA 下载失败，请检查网络或发布源。"
else
  wget -q --tries=3 "$IPA_URL" -O "$IPA" || fail "IPA 下载失败，请检查网络或发布源。"
fi
[ -s "$IPA" ] || fail "下载到的 IPA 是空文件。"
say "IPA 已下载：${IPA}（$(wc -c < "$IPA" | tr -d ' ') 字节）"

# ---- 步骤 3：签名安装引擎 ----
say "准备签名安装引擎…"
ENGINE="$WORKDIR/tnb-bootstrap"
if [ -x "$ENGINE" ]; then
  say "本机已有引擎，跳过下载。"
else
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 "$ENGINE_URL" -o "$ENGINE" 2>/dev/null \
      || ENGINE_MISSING=1
  else
    wget -q --tries=3 "$ENGINE_URL" -O "$ENGINE" 2>/dev/null \
      || ENGINE_MISSING=1
  fi
fi

if [ "${ENGINE_MISSING:-0}" = "1" ] || [ ! -x "$ENGINE" ]; then
  rm -f "$ENGINE"
  cat <<EOF

[TNB] ──────────────────────────────────────────────
[TNB] 签名安装引擎尚未部署（这是第一版的已知缺口）。
[TNB] IPA 已下载到本机：$IPA
[TNB]
[TNB] 当前状态：下载链路已验证可用，配对+签名+安装引擎待集成。
[TNB] 引擎需要实现：RPPairing 自配对 → anisette 签名 → 本机安装。
[TNB] 这需要一个用 iOS 27 开发者模式能力的原生组件，正在开发中。
[TNB] ──────────────────────────────────────────────
EOF
  exit 0
fi

say "启动签名安装（首次会要求你在设置里确认配对）…"
"$ENGINE" install --ipa "$IPA"
say "安装流程已结束，请回桌面查看 TreeNB。"
