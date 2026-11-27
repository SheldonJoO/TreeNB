#!/usr/bin/env bash
# TreeNB —— 自编译带 location_simulation 的 IDevice.xcframework
#
# 背景：SideStore/idevice 官方 release 的 ios-arm64/libidevice_ffi.a 未编
# location_simulation feature（nm 实测四个定位符号全缺）。上游 openSSS 的
# DeviceGateway/Package.swift 注释明确写了：正确做法是用本地自编译、开了该
# feature 的 xcframework。本脚本在 CI（macos-15-intel / Xcode 16.4）与本地
# 通用地把 SideStore fork 固定到 PIN commit，只编 iOS device arm64 slice，
# 打包成单 slice xcframework 落地到 openSSS 的 local/ 路径（A6 用本地 path
# 引用，不需要 checksum，也不会被 SPM 当成缺失的 binary artifact）。
#
# 体积：只编 ios-arm64 一个 slice（约 17MB .a），远小于官方全平台 213MB zip，
# 且项目 archive 本来就只做 -sdk iphoneos -arch arm64，其余 slice 用不上。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SSS="$ROOT/upstream/openSSS"
SRC="$ROOT/build/idevice-src"
OUT_DIR="$SSS/local/idevice/swift"
PIN="3e55c8486b2057e40c1f74aaaa1155c82341cf76"   # v0.1.68-ss-3e55c84

log()  { printf '\033[1;34m[idevice]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[  ok  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ warn ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ fatal]\033[0m %s\n' "$*" >&2; exit 2; }

# ---- 0. 工具链 ----
export PATH="$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null 2>&1 || die "cargo 缺失：请先安装 Rust（CI 步骤或本地 rustup）"
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild 缺失"

# 幂等：已编出带符号的产物就跳过整段（本地反复 prepare 不重复编译）
LIB_READY="$OUT_DIR/IDevice.xcframework/ios-arm64/libidevice_ffi.a"
if [ -f "$LIB_READY" ] && [ "$(nm -gU "$LIB_READY" 2>/dev/null | grep -c '_location_simulation_new')" -gt 0 ]; then
  ok "IDevice.xcframework 已存在且带 location_simulation 符号，跳过编译"
  exit 0
fi

# iOS target（星号版本号会漂移，只按 target 名判断）
if ! rustup target list --installed 2>/dev/null | grep -q '^aarch64-apple-ios$'; then
  log "安装 Rust target aarch64-apple-ios"
  rustup target add aarch64-apple-ios
fi

# ---- 1. 固定 commit 的源码（codeload tarball，比 git protocol 抗抖动）----
if [ ! -f "$SRC/ffi/Cargo.toml" ]; then
  log "拉取 SideStore/idevice @ ${PIN:0:12}"
  mkdir -p "$SRC"
  curl -fL --retry 4 --retry-delay 2 --max-time 240 \
    "https://codeload.github.com/SideStore/idevice/tar.gz/${PIN}" \
    -o /tmp/tnb_idevice_src.tar.gz
  tar xzf /tmp/tnb_idevice_src.tar.gz -C "$SRC" --strip-components=1
  rm -f /tmp/tnb_idevice_src.tar.gz
fi
grep -q 'location_simulation = \["idevice/location_simulation"\]' "$SRC/ffi/Cargo.toml" \
  || die "源码缺少 location_simulation feature（PIN 漂移？）"

# ---- 1b. B1z: 修 AFC MakeDir 路径上的 realloc 堆损坏 ----
# 真机 21:45 .ips（build 202611272119）符号化：
#   IdeviceGateway.syncsendIpaAfc → afc_make_directory → _realloc →
#   ___BUG_IN_CLIENT_OF_LIBMALLOC_POINTER_BEING_FREED_WAS_NOT_ALLOCATED → SIGABRT。
# AfcPacket::serialize 用 Vec::new() 逐段 extend，MakeDir 的 40B 头 + 路径
# 必然触发一次 realloc；改成精确容量预分配，绕开这条崩溃路径。
python3 - "$SRC/idevice/src/services/afc/packet.rs" <<'PYB1Z'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'TreeNB[B1z]' not in s:
    old = '''    pub fn serialize(&self) -> Vec<u8> {
        let mut res = Vec::new();

        res.extend_from_slice(&self.header.serialize());
        res.extend_from_slice(&self.header_payload);
        res.extend_from_slice(&self.payload);

        res
    }'''
    new = '''    pub fn serialize(&self) -> Vec<u8> {
        // TreeNB[B1z]: 精确容量预分配，避免 AFC MakeDir 路径上的 realloc 崩溃。
        let capacity = AfcPacketHeader::LEN as usize
            + self.header_payload.len()
            + self.payload.len();
        let mut res = Vec::with_capacity(capacity);
        res.extend_from_slice(&self.header.serialize());
        res.extend_from_slice(&self.header_payload);
        res.extend_from_slice(&self.payload);
        res
    }'''
    if old not in s:
        raise SystemExit('FATAL[B1z]: AfcPacket::serialize 锚点缺失')
    open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
    print('  B1z patched: AfcPacket::serialize prealloc')
PYB1Z
grep -q 'TreeNB\[B1z\]' "$SRC/idevice/src/services/afc/packet.rs" \
  || die "B1z 补丁未写入 $SRC/idevice/src/services/afc/packet.rs"

# ---- 2. 只编 iOS device arm64，default features + location_simulation ----
# default 已含 dvt / tunnel_tcp_stack / remote_pairing（IdeviceGateway.swift 需要的
# tunnel_create_rppairing_with_options 在其中），所以只需追加 obfuscate + location_simulation。
# IPHONEOS_DEPLOYMENT_TARGET 对齐 App 的 15.0（justfile 上游用 17.0，15.0 更兼容）。
log "cargo build --release --target aarch64-apple-ios (+location_simulation)"
cd "$SRC/ffi"
BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk iphoneos --show-sdk-path)" \
IPHONEOS_DEPLOYMENT_TARGET=15.0 \
  cargo build --release --target aarch64-apple-ios \
  --features "obfuscate location_simulation"

# ---- 3. header（build.rs 用 cbindgen 生成到 ffi/idevice.h，含 plist.h）----
cd "$SRC"
[ -f ffi/idevice.h ] || die "cbindgen 未生成 ffi/idevice.h"
cp ffi/idevice.h swift/include/idevice.h

# ---- 3b. 去掉调试符号，压缩体积 ----
# Rust release 默认带 DWARF（本机实测 388 个 debug_info 段）。静态库只在链接期
# 需要外部符号（strip -S 保留），调试信息对运行/链接无用。实测 18.18MB → 13.83MB
# （省 4.3MB / 24%），五个关键符号全部保留；第 5 步会重新硬校验。
RAW_LIB="target/aarch64-apple-ios/release/libidevice_ffi.a"
log "strip -S 去除 IDevice 调试符号（体积优化）"
strip -S "$RAW_LIB"

# ---- 4. 打包单 slice xcframework ----
rm -rf "$SRC/swift/IDevice.xcframework"
log "xcodebuild -create-xcframework (ios-arm64 only)"
xcodebuild -create-xcframework \
  -library "$RAW_LIB" \
  -headers swift/include \
  -output swift/IDevice.xcframework

# ---- 5. 符号硬校验（少一个都直接失败，绝不静默回退到假桩）----
LIB="$SRC/swift/IDevice.xcframework/ios-arm64/libidevice_ffi.a"
[ -f "$LIB" ] || die "xcframework 缺 ios-arm64 slice"
for sym in location_simulation_new location_simulation_set \
           location_simulation_clear location_simulation_free \
           tunnel_create_rppairing_with_options; do
  [ "$(nm -gU "$LIB" 2>/dev/null | grep -c "_${sym}$")" -gt 0 ] \
    || die "编译产物缺符号 _${sym}（location_simulation feature 未生效？）"
done
ok "五个关键符号全部就位（4×location_simulation + tunnel_create_rppairing_with_options）"

# ---- 6. 落地到 openSSS/local/（A6 的 path 指向这里）----
mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/IDevice.xcframework"
cp -R "$SRC/swift/IDevice.xcframework" "$OUT_DIR/"
ok "IDevice.xcframework 就绪 → $OUT_DIR/IDevice.xcframework ($(du -sh "$OUT_DIR/IDevice.xcframework" | cut -f1))"
