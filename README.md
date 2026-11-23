# TreeNB 🌲

**TreeNewBee2 · 树应用** —— 把 openSSS 的签名/续签内核、LiveContainer 的多 App 侧载容器、TreeWidget 小组件，整合进**一个 App、一次安装、零跳转**。

## 目标（一句话）

> 打开就是 openSSS 的界面（Apps / 定位 / 容器 / 我的），多 App 容器是里面的一个 Tab，
> 不再有"点一下跳到另一个 App、宿主退到后台"的割裂感。

## 为什么不是一个 `import` 就完事

LiveContainer 不是普通库，它是一台**会接管整车的发动机**：

```
main.c → LiveContainerMain → invokeAppMain()
                              └─ 把进程主线权交给 guest 的 UIApplicationMain
                                 宿主界面退到后台 ← 这就是"跳转"的来源
```

TreeNB 的核心改造：**反转主从关系**

| | TreeNewBee（现状） | TreeNB（目标） |
|---|---|---|
| 主界面 | LiveContainer 的三 Tab | openSSS 的 Shell 四 Tab（含容器） |
| openSSS | guest，被 dylibify 塞进 framework | 本体，直接编译进主 App |
| 容器多开 | 宿主能力 | 内嵌 Tab，guest 仍走进程接管 |
| 跳转 | 点 openSSS Tab 触发 | **无** —— 默认就在 openSSS |
| 打包 | 八步补丁 + mangled name 替换 | 标准 archive，冗余 hack 全删 |

## 工程状态

✅ **代码骨架 + 适配层完成**（2026-11-23）—— 已落地：
- xcodegen 工程定义（4 targets）
- LC 引擎适配桥接（framework 入口 + guest 启停 API）
- 容器 Tab 全套 SwiftUI（导入 / 列表 / 启动 / 返回）
- 深链路由、Widget 并入、自动改造补丁脚本、CI、Spike 探针

⏳ **待真机验证**：LC 引擎作为内嵌 framework 的 swizzle 冲突（Spike 三问，见下）
🔲 **未做**：Xcode 工程本体生成（需 Xcode 16.4）、完整业务代码铺开、多版本回归

## 目录

```
TreeNB/
├── .github/workflows/build.yml      # CI：public repo + macos-15-intel，免费无限
├── project.yml                      # xcodegen 工程定义（4 targets）
├── config/
│   ├── TreeNB.xcconfig              # 全局配置（bundle id / 部署目标 / App Group）
│   ├── TreeNB-Info.plist            # 主 App（含 openssai/sidestore/livecontainer scheme）
│   ├── TreeNB.entitlements          # App Group + Keychain + 128 组兼容
│   ├── AltWidget-Info.plist         # Widget extension（iOS16）
│   └── AltWidgetExtension.entitlements
├── scripts/
│   ├── prepare_dependencies.sh      # 拉上游 → 打补丁 → OpenSSL → 生成工程
│   ├── patch_upstream.sh            # ★ 自动改造：删跳转 / 身份归一 / Widget 并入
│   ├── assemble_ipa.sh              # archive → 无签名 IPA
│   └── sign_ipa.sh                  # release 时用 Secrets 正式签名
├── Sources/
│   ├── Bridge/                      # LC 引擎 C/ObjC 适配层（framework 入口）
│   │   ├── include/LCEngineEntry.h  # guest 启停 / IPA 安装 / 签名 API
│   │   └── LCEngineEntry.m
│   ├── Container/                   # 容器 Tab（SwiftUI）
│   │   ├── ContainerTabViewController.swift  # 接入 openSSS Shell 的第四个 Tab
│   │   ├── ContainerRootView.swift           # 导入/列表/启动界面
│   │   └── ContainerViewModel.swift          # 状态机
│   ├── Routing/TNBDeepLinkRouter.swift       # openssai:// 统一深链分发
│   ├── Widget/                      # TreeWidget 并入（无 @main）
│   │   ├── TreeWidgetBridge.swift   # Keychain/AppGroup 数据桥
│   │   └── TreeLaunchWidget.swift   # Widget 定义
│   └── Spike/EngineSpikeProbe.swift         # 三问验证探针（DEBUG/TNB_SPIKE 门禁）
├── upstream/                        # 上游源码（准备脚本拉取，不入 git）
│   ├── openSSS/                     # AltStore/ SideStore/ Shared/ AltWidget/
│   └── TreeNewBee/                  # LiveContainer/ LiveContainerSwiftUI/
└── docs/
    ├── 启动链改造设计.md             # 无跳转核心技术方案 + 逐文件改造清单
    └── Spike验证指南.md              # ★ 真机三问验证步骤（写代码前的风险闸门）
```

## 构建

**CI（推荐）**：把仓库设为 **public**，push 到 `main` 自动 archive；打 release tag 自动签名出包。
public repo 的 standard runners（含 macOS）免费且无限，不消耗 private 的分钟额度。
`macos-15-intel`（4核/14GB）自带 Xcode 16.4，比 M1（7GB）稳。

**本地**：需要 macOS 15.3+ / Xcode 16.4（本机 MacBookPro12,1 达不到，编译请走 CI）。

```bash
./scripts/prepare_dependencies.sh   # 含 xcodegen generate
xcodebuild archive -project TreeNB.xcodeproj -scheme TreeNB \
  -archivePath build/TreeNB.xcarchive -sdk iphoneos -arch arm64 \
  -configuration Release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
./scripts/assemble_ipa.sh
```

## 落地顺序（别跳步）

1. **Spike 三问**（`docs/Spike验证指南.md`，1–2 周）——验证 LC 引擎内嵌的 swizzle 冲突。
   **三问全绿前，禁止写业务代码。** 失败即转方案 B（appex + XPC）。
2. 容器 Tab 最小闭环（导入 → 安装 → 列表 → 启动 → 返回）
3. Widget 并入 + Keychain/App Group 归一
4. 应用源 / 续签协调 / 数据迁移 / 多版本回归

## 签名密钥（CI Secrets）

| Secret | 用途 |
|---|---|
| `SIGNING_CERT_P12` | 签名证书（base64） |
| `SIGNING_CERT_PASSWORD` | p12 密码 |
| `PROVISIONING_PROFILE` | 描述文件（base64） |

签名步骤**只在 release / 手动勾选时运行**，PR 触碰不到 secrets。

## 许可证

AGPL-3.0（与 openSSS / TreeNewBee 一致）。
