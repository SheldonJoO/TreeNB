#!/bin/bash
# TreeNB 无签名 IPA 组装：把 xcarchive 转成可侧载的 IPA 结构
# 单包无跳转方案：openSSS Shell 是主界面，LC 引擎以 framework 内嵌，
#   TreeWidget 作为 appex 内嵌，不再有 openSSS 作为 guest 的 dylibify/包装步骤。
set -euo pipefail

cd "$(dirname "$0")/.."
ARCHIVE_PATH="${ARCHIVE_PATH:-build/TreeNB.xcarchive}"
SCHEME="${SCHEME:-TreeNB}"
STAMP=$(date +%Y%m%d%H%M)
OUT="build/TreeNB-${STAMP}-unsigned.ipa"

echo "==> [1/4] 解出 archive 的 Payload"
rm -rf build/Payload
cp -a "$ARCHIVE_PATH/Products/Applications" build/Payload

APP=$(find build/Payload -maxdepth 1 -name "*.app" -type d | head -1)
[ -n "$APP" ] || { echo "找不到 .app" >&2; exit 1; }
echo "  app=$APP"

echo "==> [1.5/4] 校验 Info.plist 关键键（防 xcodegen properties 覆盖回归）"
BGMODES=$(/usr/libexec/PlistBuddy -c "Print :UIBackgroundModes" "$APP/Info.plist" 2>/dev/null || true)
if ! echo "$BGMODES" | grep -q "location"; then
  echo "致命错误: UIBackgroundModes 缺少 location！上游启动代码调用 setAllowsBackgroundLocationUpdates:，缺此声明会导致 CoreLocation 启动断言秒退。" >&2
  echo "当前 UIBackgroundModes: $BGMODES" >&2
  echo "请在 project.yml 的 info.properties.UIBackgroundModes 补回 location 后重新构建。" >&2
  exit 1
fi
echo "  UIBackgroundModes 含 location，校验通过"

# IPA 文档类型：UIDocumentPicker 按 com.apple.itunes.ipa 过滤，缺声明则选不了 .ipa 文件。
IPA_DECL=$(/usr/libexec/PlistBuddy -c "Print :UTImportedTypeDeclarations" "$APP/Info.plist" 2>/dev/null || true)
if ! echo "$IPA_DECL" | grep -q "com.apple.itunes.ipa"; then
  echo "致命错误: UTImportedTypeDeclarations 缺少 com.apple.itunes.ipa！容器页 UIDocumentPicker 按此 UTI 过滤，缺声明将无法选择 .ipa 文件。" >&2
  echo "请在 project.yml 的 info.properties 补回 UTImportedTypeDeclarations / CFBundleDocumentTypes 的 IPA 声明后重新构建。" >&2
  exit 1
fi
echo "  UTImportedTypeDeclarations 含 com.apple.itunes.ipa，校验通过"

STORYBOARD=$(/usr/libexec/PlistBuddy -c "Print :UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0:UISceneStoryboardFile" "$APP/Info.plist" 2>/dev/null || true)
if [ "$STORYBOARD" != "Main" ]; then
  echo "致命错误: SceneManifest 缺少 UISceneStoryboardFile=Main！openSSS 的 SceneDelegate 不手动创建 window/root，靠 Main.storyboard 自动交接；缺此键启动后全黑屏。" >&2
  echo "当前 UISceneStoryboardFile: '${STORYBOARD}'" >&2
  echo "请在 project.yml 的 info.properties.UIApplicationSceneManifest 补回 UISceneStoryboardFile: Main 后重新构建。" >&2
  exit 1
fi
echo "  SceneManifest 含 UISceneStoryboardFile=Main，校验通过"

DELEGATE=$(/usr/libexec/PlistBuddy -c "Print :UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0:UISceneDelegateClassName" "$APP/Info.plist" 2>/dev/null || true)
DELEGATE="${DELEGATE:-}"
case "${DELEGATE}" in
  *.SceneDelegate)
    printf '  UISceneDelegateClassName=%s, check passed\n' "$DELEGATE"
    ;;
  *)
    printf 'FATAL: UISceneDelegateClassName=[%s] is empty or has no module prefix. Swift class real name is <Module>.SceneDelegate (this app: TreeNB.SceneDelegate). A bare name makes system fail to load scene delegate -> no root window -> black screen.\n' "$DELEGATE" >&2
    printf 'Fix: in project.yml set UISceneDelegateClassName with PRODUCT_MODULE_NAME prefix, then rebuild.\n' >&2
    exit 1
    ;;
esac

echo "==> [1.6/4] 校验 IPA 导入链路不是桩实现"
ENGINE_SRC="Sources/Bridge/LCEngineEntry.m"
if grep -q 'TODO(upstream): 调用 LCMachOUtils.unzipIPA' "$ENGINE_SRC"; then
  echo "致命错误: LCEngineEntry.m 的 installIPA 仍是 TODO 桩（只建临时目录不解压），导入 IPA 会静默失败。" >&2
  exit 1
fi
if ! grep -q 'TNBExtractIPAAtPath' "$ENGINE_SRC"; then
  echo "致命错误: LCEngineEntry.m 缺少真实解压实现 TNBExtractIPAAtPath。" >&2
  exit 1
fi
LC_FW_BIN=$(find "$APP/Frameworks" -maxdepth 2 -type f -name LiveContainerShared 2>/dev/null | head -1 || true)
if [ -n "$LC_FW_BIN" ] && ! otool -L "$LC_FW_BIN" | grep -q 'libarchive'; then
  echo "致命错误: LiveContainerShared 未链接 libarchive，IPA 解压会链接失败。" >&2
  exit 1
fi
echo "  IPA 导入链路校验通过（真实解压 + libarchive 已链接）"

echo "==> [1.7/4] 校验容器 bootstrap 不存在 nil 数组崩溃点"
if grep -q '@\[self.bundleRoot, self.groupBundleRoot\]' "$ENGINE_SRC"; then
  echo "致命错误: bootstrapWithError 用数组字面量装 groupBundleRoot，重签后 App Group 为 nil 会瞬间闪退。" >&2
  exit 1
fi
if ! grep -q 'effectiveGroupRoot = groupRoot ?: docs' "$ENGINE_SRC"; then
  echo "致命错误: bootstrapWithError 缺少 App Group nil fallback。" >&2
  exit 1
fi
echo "  bootstrap nil 防护校验通过"

echo "==> [1.8/4] 校验 guest 冷启动接管链路"
if ! grep -q 'takeOverIfGuestPending' "$ENGINE_SRC"; then
  echo "致命错误: LCEngineEntry.m 缺少冷启动接管钩子实现。" >&2
  exit 1
fi
if ! grep -q 'setObject:bundleName forKey:@"selected"' "$ENGINE_SRC"; then
  echo "致命错误: launchGuestApp 未写入正确的 selected 键（写成 selectedApp 会导致 guest 永不启动）。" >&2
  exit 1
fi
if ! grep -q 'launchToGuestAppWithClassicMode' "$ENGINE_SRC"; then
  echo "致命错误: launchGuestApp 未委托 LCSharedUtils 重启进程，热调 LiveContainerMain 会闪退。" >&2
  exit 1
fi
echo "  guest 冷启动接管链路校验通过"

echo "==> [2/4] 移除签名残留（无签名包）"
find "$APP" -type d -name "_CodeSignature" -exec rm -rf {} + 2>/dev/null || true

echo "==> [3/4] ad-hoc 签名主可执行与 appex（ldid，占位 entitlements）"
if command -v ldid >/dev/null 2>&1; then
  EXE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Info.plist")
  if [ -f "config/TreeNB_adhoc.xml" ]; then
    ldid -Sconfig/TreeNB_adhoc.xml "$APP/$EXE"
  else
    ldid -S "$APP/$EXE"
  fi
  find "$APP/PlugIns" -name "*.appex" -type d 2>/dev/null | while read -r appex; do
    AEXE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$appex/Info.plist" 2>/dev/null || true)
    [ -n "$AEXE" ] && ldid -S "$appex/$AEXE" || true
  done
else
  echo "  警告：未安装 ldid，跳过 ad-hoc 签名（CI 镜像通常自带或由 brew 安装）"
fi

echo "==> [4/4] 打包 IPA"
(cd build && zip -qr "$(basename "$OUT")" Payload -x "._*" -x ".DS_Store" -x "__MACOSX")

echo "完成: $OUT"
