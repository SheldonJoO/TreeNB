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

STORYBOARD=$(/usr/libexec/PlistBuddy -c "Print :UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0:UISceneStoryboardFile" "$APP/Info.plist" 2>/dev/null || true)
if [ "$STORYBOARD" != "Main" ]; then
  echo "致命错误: SceneManifest 缺少 UISceneStoryboardFile=Main！openSSS 的 SceneDelegate 不手动创建 window/root，靠 Main.storyboard 自动交接；缺此键启动后全黑屏。" >&2
  echo "当前 UISceneStoryboardFile: '${STORYBOARD}'" >&2
  echo "请在 project.yml 的 info.properties.UIApplicationSceneManifest 补回 UISceneStoryboardFile: Main 后重新构建。" >&2
  exit 1
fi
echo "  SceneManifest 含 UISceneStoryboardFile=Main，校验通过"

DELEGATE=$(/usr/libexec/PlistBuddy -c "Print :UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0:UISceneDelegateClassName" "$APP/Info.plist" 2>/dev/null || true)
case "$DELEGATE" in
  *".SceneDelegate") echo "  UISceneDelegateClassName=$DELEGATE，校验通过" ;;
  *)
    echo "致命错误: UISceneDelegateClassName='$DELEGATE' 是裸名或缺失！Swift 模块化后真实类名是 <Module>.SceneDelegate（本包为 TreeNB.SceneDelegate）；裸名导致系统找不到 delegate 类，scene 加载失败、window 无 root、启动纯黑屏。" >&2
    echo "请在 project.yml 用 UISceneDelegateClassName: \$(PRODUCT_MODULE_NAME).SceneDelegate 后重新构建。" >&2
    exit 1
    ;;
esac

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
