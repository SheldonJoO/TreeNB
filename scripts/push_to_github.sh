#!/usr/bin/env bash
# 把 TreeNB 推到 GitHub（一次性）。用法：
#   ./scripts/push_to_github.sh <你的GitHub用户名>
# 例：
#   ./scripts/push_to_github.sh SheldonJoO
#
# 前提：先在网页建一个 PUBLIC 空仓库，名字固定 TreeNB（不要勾选初始化 README）。
#   建仓地址：https://github.com/new
# 推送时 GitHub 会弹窗要凭证：用户名填 GitHub 账号，密码填 Personal Access Token
#   （不是登录密码）。生成 PAT：GitHub 头像 → Settings → Developer settings →
#   Personal access tokens → Tokens (classic) → Generate new token，勾 repo 权限。
set -euo pipefail

USERNAME="${1:-}"
if [ -z "$USERNAME" ]; then
  echo "用法: $0 <GitHub用户名>" >&2
  exit 1
fi

REPO="https://github.com/${USERNAME}/TreeNB.git"
cd "$(dirname "$0")/.."

echo "==> 目标仓库: $REPO"
echo "==> 确认你已在 https://github.com/new 建好 public 空仓库 TreeNB"
read -r -p "建好了吗？回车继续 / Ctrl-C 取消... "

if git remote get-url origin >/dev/null 2>&1; then
  echo "==> origin 已存在，更新为 $REPO"
  git remote set-url origin "$REPO"
else
  git remote add origin "$REPO"
fi

echo "==> 推送 main"
git push -u origin main

echo "==> 完成！"
echo "下一步：打开 $REPO/actions/workflows/build.yml"
echo "点 Run workflow → 勾选 Spike 自检包 → 运行"
