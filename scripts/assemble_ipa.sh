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
# ★ 入口位置硬校验（2026-11-24 真机 .ips 根因）：接管必须在进程 main.swift 里、
#   宿主 UIApplicationMain 之前。若被放回 didFinishLaunchingWithOptions，
#   UIApplication 单例已存在，guest 再起 UIApplicationMain 会断言
#   "Dispatch queue already set" 闪退。同时 AppDelegate 必须移除 @UIApplicationMain
#   否则与 main.swift 顶层入口重复编译。
MAIN_ENTRY="upstream/openSSS/AltStore/main.swift"
if [ ! -f "$MAIN_ENTRY" ]; then
  echo "致命错误: 缺少 $MAIN_ENTRY —— guest 接管没有前移到进程入口。" >&2
  exit 1
fi
if ! grep -q 'takeOverIfGuestPending' "$MAIN_ENTRY"; then
  echo "致命错误: main.swift 未调用 takeOverIfGuestPending，guest 冷启动不会接管。" >&2
  exit 1
fi
if grep -q '^@UIApplicationMain' upstream/openSSS/AltStore/AppDelegate.swift 2>/dev/null; then
  echo "致命错误: AppDelegate.swift 仍带 @UIApplicationMain，与 main.swift 重复入口（编译失败）。" >&2
  exit 1
fi
if grep -q 'LCEngineEntry.takeOverIfGuestPending' upstream/openSSS/AltStore/AppDelegate.swift 2>/dev/null; then
  echo "致命错误: AppDelegate 里仍有热接管调用（didFinishLaunching 太晚，会二次 UIApplicationMain 闪退）。" >&2
  exit 1
fi
echo "  入口前移校验通过（main.swift 唯一入口，AppDelegate 无 @UIApplicationMain）"
if ! grep -q 'setObject:bundleName forKey:@"selected"' "$ENGINE_SRC"; then
  echo "致命错误: launchGuestApp 未写入正确的 selected 键（写成 selectedApp 会导致 guest 永不启动）。" >&2
  exit 1
fi
if ! grep -q 'launchToGuestAppWithClassicMode' "$ENGINE_SRC"; then
  echo "致命错误: launchGuestApp 未委托 LCSharedUtils 重启进程，热调 LiveContainerMain 会闪退。" >&2
  exit 1
fi
if ! grep -q 'ensureHostLaunchOverrides' "$ENGINE_SRC"; then
  echo "致命错误: 缺少宿主 URL scheme / App Group 覆盖注入，重签后 lcAppUrlScheme/lcAppGroupPath 会拿错导致 guest 闪退。" >&2
  exit 1
fi
if ! grep -q 'TNBHostUrlScheme' "$ENGINE_SRC"; then
  echo "致命错误: 未写入 TNBHostUrlScheme 覆盖键。" >&2
  exit 1
fi
if ! grep -q 'TNBHostAppGroupPath' "$ENGINE_SRC"; then
  echo "致命错误: 未写入 TNBHostAppGroupPath 覆盖键。" >&2
  exit 1
fi
# 上游 LCBootstrap 必须已被 patch 成优先读这两个覆盖键，否则写了也没用。
LC_BOOTSTRAP="upstream/TreeNewBee/LiveContainer/LCBootstrap.m"
if [ -f "$LC_BOOTSTRAP" ]; then
  if ! grep -q 'TNBHostUrlScheme' "$LC_BOOTSTRAP" || ! grep -q 'TNBHostAppGroupPath' "$LC_BOOTSTRAP"; then
    echo "致命错误: 上游 LCBootstrap.m 未注入宿主覆盖读取分支，guest 冷启动仍会拿错 scheme/appGroup。" >&2
    echo "请确认 patch_upstream.sh 的 A4c 段已执行。" >&2
    exit 1
  fi
fi
LC_SHARED="upstream/TreeNewBee/LiveContainer/LCSharedUtils.m"
if [ -f "$LC_SHARED" ]; then
  if ! grep -q 'TREENB_MAINBUNDLE_FIX' "$LC_SHARED"; then
    echo "致命错误: LCSharedUtils.m 缺少 mainBundle nil 兜底，宿主冷启动重启会 initWithContentsOfFile:nil 抛异常。" >&2
    echo "请确认 patch_upstream.sh 的 A4d 段已执行。" >&2
    exit 1
  fi
fi
# A4e：上游 LCBootstrap 必须自己会创建 tweakFolder 并修好断链，否则宿主侧
# 万一没跑到，guest 依旧报 TweakLoader.dylib no such file。
if [ -f "$LC_BOOTSTRAP" ]; then
  if ! grep -q 'TREENB_TWEAKS_FIX' "$LC_BOOTSTRAP"; then
    echo "致命错误: 上游 LCBootstrap.m 未注入 Tweaks 目录/软链自愈，guest dlopen TweakLoader.dylib 仍会失败。" >&2
    echo "请确认 patch_upstream.sh 的 A4e 段已执行。" >&2
    exit 1
  fi
fi
if ! grep -q 'ensureTweakLoaderSymlink' "$ENGINE_SRC"; then
  echo "致命错误: 宿主缺少 TweakLoader symlink 前置条件保障。" >&2
  exit 1
fi
if ! grep -q 'autoImportBundledCertificateIfNeeded' "$ENGINE_SRC"; then
  echo "致命错误: 宿主缺少内置 p12 证书自动导入。" >&2
  exit 1
fi
echo "  guest 冷启动接管链路校验通过（含宿主 scheme/appGroup 覆盖 + Tweaks 自愈 + 证书自动导入）"

echo "==> [1.9/4] 校验小组件快照写入链路"
if ! grep -rq 'TNBWidgetSnapshotWriter' Sources/Container/WidgetSettings.swift 2>/dev/null; then
  echo "致命错误: 缺少小组件快照写入器，小组件会永远显示空。" >&2
  exit 1
fi
if ! grep -q 'WidgetKit.framework' project.yml; then
  echo "致命错误: 主 App 缺少 WidgetKit.framework 依赖，WidgetCenter 刷新会链接失败。" >&2
  exit 1
fi
echo "  小组件快照写入链路校验通过"

echo "==> [1.10/4] 校验 JIT-less 签名链路"
# 先归位：xcodegen 对 dylib 的 `embed: true` 走 Copy Bundle Resources，产物落在 App
# 根目录；而 LCUtils 运行时 dlopen 的是 @executable_path/Frameworks/ZSign.dylib。
# 把根目录的 ZSign.dylib 移到 Frameworks/，两者路径对齐后再校验。
if [ -f "$APP/ZSign.dylib" ]; then
  mkdir -p "$APP/Frameworks"
  mv -f "$APP/ZSign.dylib" "$APP/Frameworks/ZSign.dylib"
  echo "  已移动 ZSign.dylib → Frameworks/"
elif [ ! -f "$APP/Frameworks/ZSign.dylib" ]; then
  ZS_SRC=$(find "$ARCHIVE_PATH" -name 'ZSign.dylib' -type f 2>/dev/null | head -1)
  if [ -n "$ZS_SRC" ]; then
    mkdir -p "$APP/Frameworks"
    cp -f "$ZS_SRC" "$APP/Frameworks/ZSign.dylib"
    echo "  已从 archive 补拷 ZSign.dylib → Frameworks/"
  fi
fi
# 同理归位 TweakLoader / TestJITLess：xcodegen embed 的 dylib 落在 App 根目录，
# 但上游 invokeAppMain 建的 symlink 目标是 App.app/Frameworks/TweakLoader.dylib。
# 崩溃实证：guest dlopen @loader_path/.../Tweaks/TweakLoader.dylib 失败 → guest 起不来。
for DYLIB in TweakLoader TestJITLess; do
  if [ -f "$APP/$DYLIB.dylib" ]; then
    mkdir -p "$APP/Frameworks"
    mv -f "$APP/$DYLIB.dylib" "$APP/Frameworks/$DYLIB.dylib"
    echo "  已移动 $DYLIB.dylib → Frameworks/"
  elif [ ! -f "$APP/Frameworks/$DYLIB.dylib" ]; then
    DS_SRC=$(find "$ARCHIVE_PATH" -name "$DYLIB.dylib" -type f 2>/dev/null | head -1)
    if [ -n "$DS_SRC" ]; then
      mkdir -p "$APP/Frameworks"
      cp -f "$DS_SRC" "$APP/Frameworks/$DYLIB.dylib"
      echo "  已从 archive 补拷 $DYLIB.dylib → Frameworks/"
    fi
  fi
  if [ ! -f "$APP/Frameworks/$DYLIB.dylib" ]; then
    echo "致命错误: 包内缺少 Frameworks/$DYLIB.dylib！guest 启动 dlopen 会失败（闪回宿主 UI）。请在 project.yml 声明 $DYLIB target 并 embed。" >&2
    exit 1
  fi
done
# CydiaSubstrate.framework 也要在 Frameworks/（TweakLoader 注入 guest 后 dlopen 它）
if [ ! -d "$APP/Frameworks/CydiaSubstrate.framework" ]; then
  echo "致命错误: 包内缺少 Frameworks/CydiaSubstrate.framework！TweakLoader 依赖它。请在 project.yml 用 framework: 依赖 embed。" >&2
  exit 1
fi

ZSIGN_DYLIB="$APP/Frameworks/ZSign.dylib"
if [ ! -f "$ZSIGN_DYLIB" ]; then
  echo "致命错误: 包内缺少 Frameworks/ZSign.dylib！无 JIT 环境 guest 无法签名/启动。请在 project.yml 声明 ZSign target 并 embed。" >&2
  exit 1
fi
if ! strings "$ZSIGN_DYLIB" | grep -q 'ZSigner'; then
  echo "致命错误: ZSign.dylib 未导出 ZSigner 类，签名会失败。" >&2
  exit 1
fi
if ! otool -L "$ZSIGN_DYLIB" | grep -q 'OpenSSL.framework/OpenSSL'; then
  echo "致命错误: ZSign.dylib 未链接 OpenSSL.framework。" >&2
  exit 1
fi
if ! grep -q 'LCCertificateData' "$ENGINE_SRC"; then
  echo "致命错误: LCEngineEntry.m 缺少 JIT-less 证书导入实现（LCCertificateData）。" >&2
  exit 1
fi
if [ ! -f "Sources/Container/JITLessCertificateView.swift" ]; then
  echo "致命错误: 缺少 JIT-less 证书管理界面。" >&2
  exit 1
fi

# 2026-11-24 启动闪退事故防回归：ZSign 绝不能被静态链接进主可执行文件。
# xcodegen 对 `- target: ZSign` 默认 link: true，会把编译机的
# DYLIB_INSTALL_NAME_BASE=/usr/local/lib 写进主程序 LC_LOAD_DYLIB，
# 真机 dyld 找不到该绝对路径 → SIGABRT，界面全黑，且发生在任何 UI 之前。
MAIN_EXE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Info.plist")
BAD_DYLIB=$(otool -L "$APP/$MAIN_EXE" 2>/dev/null | grep -E '/(usr/local|home/|Users/|opt/homebrew)' || true)
if [ -n "$BAD_DYLIB" ]; then
  echo "致命错误: 主可执行文件静态链接了编译机绝对路径的动态库，真机启动必闪退：" >&2
  echo "$BAD_DYLIB" >&2
  echo "修复：project.yml 主 App 对 ZSign 依赖必须 link: false，且 ZSign 设 DYLIB_INSTALL_NAME_BASE: '@rpath'。" >&2
  exit 1
fi
if otool -L "$APP/$MAIN_EXE" 2>/dev/null | grep -q 'ZSign.dylib'; then
  echo "致命错误: 主可执行文件仍链接 ZSign.dylib（应为运行时 dlopen，不进 LC_LOAD_DYLIB）。" >&2
  exit 1
fi
# ZSign 自身 install name 也必须是 @rpath，否则被任何 target 链接都会带绝对路径。
ZSIGN_ID=$(otool -D "$ZSIGN_DYLIB" 2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
case "$ZSIGN_ID" in
  @rpath/ZSign.dylib) ;;
  *)
    echo "致命错误: ZSign.dylib install name=[$ZSIGN_ID]，应为 @rpath/ZSign.dylib。" >&2
    exit 1
    ;;
esac
# 主 App runpath 必须包含 @executable_path/Frameworks，dlopen 才能解析 @rpath/OpenSSL。
if ! otool -l "$APP/$MAIN_EXE" 2>/dev/null | grep -A2 'LC_RPATH' | grep -q '@executable_path/Frameworks'; then
  echo "致命错误: 主可执行文件缺少 LC_RPATH=@executable_path/Frameworks，ZSign/OpenSSL 无法加载。" >&2
  exit 1
fi
echo "  dyld 链路校验通过（无绝对路径链接 + ZSign @rpath + runpath 完整）"

# 无密码 p12 必须能导入：hasJITLessCertificate 不得要求 pass.length>0，
# 且导入时空密码要存成 @""（非 nil），否则上游 certificatePassword 为 nil → JIT 检查失败。
if grep -q 'return data.length > 0 && pass.length > 0' "$ENGINE_SRC"; then
  echo "致命错误: hasJITLessCertificate 仍要求密码非空，无密码 p12 会被误判为导入失败。" >&2
  exit 1
fi
if ! grep -q 'password ?: @""' "$ENGINE_SRC"; then
  echo "致命错误: 导入证书时未把空密码存成 @\"\"，上游会把它当 nil 触发 JIT 检查。" >&2
  exit 1
fi
if ! grep -q 'TNBLastGuestLaunchError' "$ENGINE_SRC"; then
  echo "致命错误: guest 启动失败原因未透传到 UI，会退化为「点 App 无提示回落主界面」。" >&2
  exit 1
fi
echo "  JIT-less 签名链路校验通过（ZSign.dylib + 证书导入 + 无密码支持 + 错误透传 + UI 均在）"

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
