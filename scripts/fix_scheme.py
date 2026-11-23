#!/usr/bin/env python3
"""从 xcodegen 生成的 pbxproj 解析主 App target，写出一份完整正确的 xcscheme。

背景：xcodegen 在多 target + scheme/target 同名时生成的 scheme 不可靠
（BuildableReference 为空、wasCreatedForAppExtension=YES、buildFor*=NO），
导致 `xcodebuild archive` 报 "Scheme is not currently configured for the archive action"。
这里不依赖 xcodegen 的 scheme 生成，直接从 pbxproj 提取 target ID 重建标准 scheme。
"""
import os
import re
import sys

PBX = 'TreeNB.xcodeproj/project.pbxproj'
SCHEME_NAME = 'TreeNB-App'
OUT = 'TreeNB.xcodeproj/xcshareddata/xcschemes/' + SCHEME_NAME + '.xcscheme'

if not os.path.exists(PBX):
    print('[error] 找不到 ' + PBX)
    sys.exit(1)

proj = open(PBX, encoding='utf-8').read()

# 解析 PBXNativeTarget:  "24位ID /* Name */ = { ... isa = PBXNativeTarget; ... productType = "xxx"; ... };"
pat = re.compile(
    r'([0-9A-F]{24})\s+/\*\s*([^*]+?)\s*\*/\s*=\s*\{'
    r'(.*?)\n\s*\};',
    re.S,
)
targets = []
for m in pat.finditer(proj):
    body = m.group(3)
    if 'isa = PBXNativeTarget' not in body:
        continue
    pt = re.search(r'productType\s*=\s*"([^"]+)"', body)
    targets.append({
        'id': m.group(1),
        'name': m.group(2).strip(),
        'productType': pt.group(1) if pt else '',
    })

print('[dbg] targets: ' + repr([(t['name'], t['productType']) for t in targets]))

app = next(
    (t for t in targets if t['productType'] == 'com.apple.product-type.application'),
    None,
)
if app is None:
    print('[error] pbxproj 中找不到 application target')
    sys.exit(1)

APP_ID = app['id']
APP_NAME = app['name']
BUILDABLE = APP_NAME + '.app'

# 注意：属性必须写在开标签内（<BuildableReference\n  Key = "Val" ...>），
# 不能写成 <BuildableReference>\n Key = "Val"（那样是文本内容，xcodebuild 会忽略）
REF = (
    '            <BuildableReference\n'
    '               BuildableIdentifier = "primary"\n'
    '               BlueprintIdentifier = "__APP_ID__"\n'
    '               BuildableName = "__BUILDABLE__"\n'
    '               BlueprintName = "__APP_NAME__"\n'
    '               ReferencedContainer = "container:TreeNB.xcodeproj">\n'
    '            </BuildableReference>'
).replace('__APP_ID__', APP_ID).replace('__BUILDABLE__', BUILDABLE).replace('__APP_NAME__', APP_NAME)

BUILD_ENTRY = (
    '         <BuildActionEntry\n'
    '            buildForTesting="YES" buildForRunning="YES"\n'
    '            buildForProfiling="YES" buildForArchiving="YES"\n'
    '            buildForAnalyzing="YES">\n'
    '__REF__\n'
    '         </BuildActionEntry>'
).replace('__REF__', REF)

SCHEME = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<Scheme LastUpgradeVersion="1600" version="1.7">\n'
    '   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">\n'
    '      <BuildActionEntries>\n'
    '__BUILD_ENTRY__\n'
    '      </BuildActionEntries>\n'
    '   </BuildAction>\n'
    '   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn" shouldUseLaunchSchemeArgsEnv="YES">\n'
    '      <Testables/>\n'
    '   </TestAction>\n'
    '   <LaunchAction buildConfiguration="Release" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">\n'
    '      <BuildableProductRunnable runnableDebuggingMode="0">\n'
    '__REF__\n'
    '      </BuildableProductRunnable>\n'
    '   </LaunchAction>\n'
    '   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">\n'
    '      <BuildableProductRunnable runnableDebuggingMode="0">\n'
    '__REF__\n'
    '      </BuildableProductRunnable>\n'
    '   </ProfileAction>\n'
    '   <AnalyzeAction buildConfiguration="Debug"/>\n'
    '   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES">\n'
    '      <BuildActionEntries>\n'
    '__BUILD_ENTRY__\n'
    '      </BuildActionEntries>\n'
    '   </ArchiveAction>\n'
    '</Scheme>\n'
).replace('__BUILD_ENTRY__', BUILD_ENTRY).replace('__REF__', REF)

# XML well-formed 校验
import xml.etree.ElementTree as ET
try:
    root = ET.fromstring(SCHEME)
except ET.ParseError as e:
    print('[error] 生成的 scheme XML 非法: ' + str(e))
    sys.exit(1)
if root.find('ArchiveAction') is None or root.find('BuildAction') is None:
    print('[error] scheme 缺少 ArchiveAction / BuildAction')
    sys.exit(1)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
open(OUT, 'w', encoding='utf-8').write(SCHEME)
print('[ ok ] 已写出标准 scheme: ' + OUT + ' -> ' + APP_NAME + ' (' + APP_ID + ')')
