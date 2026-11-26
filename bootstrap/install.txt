#!/bin/sh
# TreeNB 免电脑首次安装引导脚本（siboot 风格，运行在 Open Minis 的 shell 里）
#
# 设计目标：用户只需在 Open Minis 里粘贴一条命令，剩下的都在本地网页里点。
# 本脚本负责：
#   1) 检测环境（iOS 版本、下载工具）
#   2) 从发布站点下载 TreeNB IPA 与引导引擎（同站托管）
#   3) 启动引导引擎 → 在 Minis 浏览器弹出本地网页 → 五步交互
#
# ⚠️ 诚实标注（v1.3.1，Apple ID 登录与签名已接入）：
#   - v1.3.1 在本地网页里接入 Apple ID 密码 / 二次验证输入，用 isideload
#     完成真实登录、开发者证书注册与 IPA 签名。
#   - RPPairing 自配对与安装隧道仍在接入：签名完成后若本机没有 pairing.plist，
#     网页会明确提示尚未安装，不会假装成功。
#   - 引擎按版本标记强制更新，避免手机复用旧版外壳；下载链接带版本参数破缓存。
#   - 全程不依赖 SideInstaller，只借它的"本地网页交互"外形。

set -eu

TNB_BOOTSTRAP_VERSION="1.3.1"

# IPA 地址：优先用第 1 个参数（网页生成的命令会把同站 IPA 绝对地址传进来），
# 其次用环境变量，最后回退到 GitHub Release 兼容地址。
SITE_IPA_URL="${1:-${TNB_IPA_URL:-}}"
IPA_URL="${SITE_IPA_URL:-https://github.com/SheldonJoO/TreeNB/releases/latest/download/TreeNB-unsigned.ipa}"
WORKDIR="${HOME}/.treenb-bootstrap"
# 引擎地址：第 2 个参数（网页同站托管），其次环境变量。引擎是 aarch64 静态 ELF。
SITE_ENGINE_URL="${2:-${TNB_ENGINE_URL:-}}"
# 从 IPA URL 推导同站引擎地址（同域名换文件名），兼容 URL 后的 ?query 参数。
if [ -z "$SITE_ENGINE_URL" ] && [ -n "$SITE_IPA_URL" ]; then
  SITE_ENGINE_URL=$(printf '%s' "$SITE_IPA_URL" | sed 's/TreeNB-unsigned\.ipa/treenb-bootstrap/')
fi
ENGINE_URL="$SITE_ENGINE_URL"

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

# ---- 步骤 3：下载并启动引导引擎 ----
# 关键修复：旧版脚本发现本地已有引擎就跳过下载，导致手机上一直跑旧外壳。
# 现在无条件重新下载到临时文件，校验通过后原子替换，保证每次都是站点最新版。
say "准备引导引擎（强制更新到最新版）…"
ENGINE="$WORKDIR/treenb-bootstrap"
ENGINE_TMP="$WORKDIR/.treenb-bootstrap.new"
if [ -z "$ENGINE_URL" ]; then
  fail "未指定引擎地址（引擎是可选的第 2 个参数 / 同站托管）。"
fi
rm -f "$ENGINE_TMP"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --retry 3 "$ENGINE_URL" -o "$ENGINE_TMP" || ENGINE_MISSING=1
else
  wget -q --tries=3 "$ENGINE_URL" -O "$ENGINE_TMP" || ENGINE_MISSING=1
fi
[ "${ENGINE_MISSING:-0}" = "1" ] && rm -f "$ENGINE_TMP"
[ -s "$ENGINE_TMP" ] || fail "引擎下载失败（空文件），请检查网络后重试。"

# 校验是不是真 ELF（前 4 字节 7f 45 4c 46），避免把 WAF 页面当引擎执行。
MAGIC=$(od -An -tx1 -N4 "$ENGINE_TMP" 2>/dev/null | tr -d ' \n')
[ "$MAGIC" = "7f454c46" ] || { rm -f "$ENGINE_TMP"; fail "下载到的不是有效的 aarch64 引擎文件（magic=$MAGIC）。"; }

# 版本校验：新引擎内嵌 v0.2.0 标记，旧外壳是 v0.1.1。grep 不可用则跳过这一层。
if command -v grep >/dev/null 2>&1; then
  if ! grep -a -q 'v0.2.0' "$ENGINE_TMP" 2>/dev/null; then
    rm -f "$ENGINE_TMP"
    fail "下载到的引擎不是最新版本（缺少 v0.2.0 标记），可能被缓存，请稍后重试。"
  fi
fi

mv -f "$ENGINE_TMP" "$ENGINE"
chmod +x "$ENGINE" || fail "引擎授权失败。"
say "引擎已更新：${ENGINE}（$(wc -c < "$ENGINE" | tr -d ' ') 字节）"

cat <<EOF

[TNB] ──────────────────────────────────────────────
[TNB] TreeNB 引导引擎已在本机启动。
[TNB] 请在 Minis 自带浏览器打开终端打印的 127.0.0.1 地址，
[TNB] 五步流程（连接 → Apple ID → 签名 → 安装 → 交接）会显示在网页里。
[TNB]
[TNB] 当前 v1.3.1：网页内输入 Apple ID 密码（必要时二次验证），
[TNB] 引擎会真实登录、注册证书并对 IPA 签名。
[TNB] 自配对与安装隧道仍在接入：若本机没有配对文件，
[TNB] 网页会明确提示尚未安装，不会假装成功。
[TNB] IPA 已下载到：$IPA
[TNB] ──────────────────────────────────────────────
EOF

say "启动引导引擎（终端会保持在运行，直到你关闭）…"
exec "$ENGINE" install --ipa "$IPA"
