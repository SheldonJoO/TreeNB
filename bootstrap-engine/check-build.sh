#!/usr/bin/env bash
# TreeNB bootstrap engine 自检脚本
# 检查三件事：Cargo.lock 与 Cargo.toml 是否一致、关键依赖是否发生版本漂移、
# 以及当前代码能否在目标平台编译通过（捕捉 isideload API 变更导致的构建失败）。
#
# 用法：
#   ./check-build.sh              # 完整检查（含编译检查）
#   ./check-build.sh --lock-only  # 只检查 lock 一致性 + 版本漂移（CI 用，构建步骤会做完整编译）
set -euo pipefail
cd "$(dirname "$0")"

PASS="[OK]"
FAIL="[FAIL]"
LOCK_ONLY=0
[[ "${1:-}" == "--lock-only" ]] && LOCK_ONLY=1

die() { echo "$FAIL $*" >&2; exit 1; }

echo "==> [1/4] Cargo.lock 存在性"
[[ -f Cargo.lock ]] || die "Cargo.lock 缺失，请恢复后重试"
echo "    $PASS"

echo "==> [2/4] Cargo.toml 使用精确版本锁定"
expect_iso=$(grep '^isideload = ' Cargo.toml | sed -n 's/.*version = "=\([^"]*\)".*/\1/p')
expect_idev=$(grep '^idevice = ' Cargo.toml | sed -n 's/.*version = "=\([^"]*\)".*/\1/p')
[[ -n "$expect_iso" && -n "$expect_idev" ]] || \
  die "依赖未使用精确版本锁定（=x.y.z），请恢复 Cargo.toml 的 '=0.5.2' / '=0.1.68'"
echo "    $PASS  Cargo.toml: isideload=$expect_iso idevice=$expect_idev"

echo "==> [3/4] --locked 解析一致性 + 版本漂移检查"
meta=$(mktemp)
trap 'rm -f "$meta"' EXIT
cargo metadata --locked --format-version 1 >"$meta" 2>/dev/null || \
  die "cargo metadata --locked 失败：Cargo.lock 与 Cargo.toml 不一致（lock 未更新或版本约束冲突）"

actual=$(python3 - "$meta" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
d = {p["name"]: p["version"] for p in m["packages"]}
print(d.get("isideload", "?"), d.get("idevice", "?"))
PY
)
read -r actual_iso actual_idev <<<"$actual"

[[ "$actual_iso" == "$expect_iso" ]] || \
  die "isideload 版本漂移：Cargo.toml 期望 $expect_iso，实际解析 $actual_iso（是否执行过 cargo update？）"
[[ "$actual_idev" == "$expect_idev" ]] || \
  die "idevice 版本漂移：Cargo.toml 期望 $expect_idev，实际解析 $actual_idev"
echo "    $PASS  实际解析: isideload=$actual_iso idevice=$actual_idev"

if [[ "$LOCK_ONLY" == 1 ]]; then
  echo "==> [4/4] 编译检查 —— 跳过（--lock-only，CI 的 cross build 会做完整编译）"
  echo ""
  echo "$PASS 全部检查通过（lock 一致性 + 版本锁定）"
  exit 0
fi

echo "==> [4/4] 编译检查 (cargo check --locked，主机 target)"
# 用主机 target 即可捕捉 isideload API 变更（API 与平台无关）。
# 真正的 aarch64 musl 静态链接由 CI 的 cross build 负责（本地通常无 musl-gcc）。
check_log=$(mktemp)
if cargo check --locked >"$check_log" 2>&1; then
  echo "    $PASS"
else
  cat "$check_log" >&2
  die "编译检查失败 —— 通常是 isideload 0.5.2 的 API 与当前代码不兼容，请检查上方错误"
fi
rm -f "$check_log"

echo ""
echo "$PASS 全部检查通过（lock 一致性 + 版本锁定 + 编译可行性）"
