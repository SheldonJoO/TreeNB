# 🌲树应用 | TreeNewBee Ⅱ，为完美侧载而生。

**一个 IPA，装完就是完整的侧载环境 —— 签名、续签、多 App 容器、小组件，全在这一个 App 里，零跳转。**

> 把 openSSS 的手机端签名内核、LiveContainer 的多 App 容器、TreeWidget 小组件，揉进同一个 App。
> 首次安装**不需要电脑常驻、不需要 SideInstaller**；免电脑路径需要 Open Minis 与 LocalDevVPN 作为启动环境，打开网页、复制一条命令、登录 Apple ID，装完即用。

[⬇️ 下载 IPA](https://github.com/SheldonJoO/TreeNB/releases/latest) · [📦 免电脑安装](https://TreeNB.idoer.help/) · [💬 反馈 Issue](https://github.com/SheldonJoO/TreeNB/issues)

---

## 🙏🏻 首先，严重感谢各家开源大佬

TreeNB 不是从零开始的。下面这些项目与开发者，奠定了侧载、容器、签名、配对和安卓翻译层的基础（排名不分先后）：

| 项目 | 开发者 / 团队 | TreeNB 中的使用 |
|---|---|---|
| [openSSS](https://github.com/SheldonJoO/openSSS) | **SheldonJoO** | 主壳、签名 / 续签、Anisette 与中文界面基底 |
| [TreeNewBee](https://github.com/SheldonJoO/TreeNewBee) | **SheldonJoO** | LiveContainer 衍生容器实现 |
| [LiveContainer](https://github.com/LiveContainer/LiveContainer) | **LiveContainer project and contributors**，包括 hugeBlack、khanhduytran0 | 多 App 容器、SwiftUI 与多任务实现 |
| [SideStore](https://github.com/SideStore/SideStore) | **SideStore team and contributors** | 手机端签名、续签与 Anisette 生态地基 |
| [AltStore](https://github.com/altstoreio/AltStore) | **Riley Testut** | 上游应用模型、应用源与 AltSign 思路 |
| [Husk](https://github.com/Leviidev/Husk) | **Leviidev** | Husk 安卓翻译层 |
| [SideSign](https://github.com/SideStore/SideSign)、[CodeSignKit](https://github.com/mahee96/CodeSignKit)、[AnisetteKit](https://github.com/mahee96/AnisetteKit)、[RemotePairingKit](https://github.com/mahee96/RemotePairingKit)、[GSACryptoKit](https://github.com/mahee96/GSACryptoKit) | **mahee96** | 签名、证书、Anisette 与远程配对 |
| [minimuxer](https://github.com/jkcoxson/minimuxer)、[em_proxy](https://github.com/jkcoxson/em_proxy)、[idevice](https://github.com/jkcoxson/idevice) | **jkcoxson**；minimuxer Swift 实现亦感谢 mahee96、nythepegasus | 设备通信、隧道、配对与安装 |
| [isideload](https://github.com/nab138/isideload)、[iloader](https://github.com/nab138/iloader) | **nab138** | 免电脑安装引擎与 Apple ID 认证 |
| [ZSign](https://github.com/zhlynn/zsign)、[Feather](https://github.com/claration/feather) | **zhlynn**、**khcrysalis** 及 LiveContainer 修改者 | guest 重签与签名工具链 |
| [ElleKit](https://github.com/tealbathingsuit/ellekit) | **Évelyne Bélanger** | 注入与 hook 基础设施 |
| [ANGLE](https://github.com/google/angle) | **Chromium / WebKit contributors** | Husk 的 OpenGL ES 转换层 |
| [OpenSSL](https://www.openssl.org) | **OpenSSL team**；iOS packaging 感谢 **krzyzanowskim** | 远程配对与加密 |
| [swift-crypto](https://github.com/apple/swift-crypto)、[swift-asn1](https://github.com/apple/swift-asn1) | **Apple** | 密码学与证书解析 |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | **weichsel** | ZIP 解包 |
| [litehook](https://github.com/opa334/litehook) | **opa334**；TreeNB 使用 LiveContainer fork | hook 基础设施 |
| [libdeflate](https://github.com/ebiggers/libdeflate) | **Eric Biggers**；TreeNB 使用 SideStore fork | 压缩与解压 |
| [apple-codesign-quick](https://docs.rs/apple-codesign-quick/0.1.0/) | **Dadoum** | 安装引擎的 Apple 代码签名 |
| [stb_vorbis](http://nothings.org/stb_vorbis/) | **Sean Barrett** | Husk 音频解码 |

也感谢这些让免电脑与 JIT 路径真正可用的外部项目：

- [Open Minis](https://github.com/OpenMinis/OpenMinis) —— **OpenMinis team**
- [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) —— **jkcoxson**
- [StikDebug](https://github.com/StikDebug/StikDebug) —— **StikDebug project / StephenDev0**
- [SideInstaller](https://github.com/FrizzleM/SideInstaller) —— **FrizzleM**（设计思路启发，未引入其代码）

没有这些工作，就没有 TreeNB。

---

## 🔥 为什么是它

市面上的侧载方案，要么电脑常驻，要么先装 A 再装 B，要么切个 App 就跳出去、宿主退到后台。

TreeNB 的解法：

- **单包合一** —— openSSS 做主壳（Apps / 定位 / 树应用 / 我的四个 Tab），LiveContainer 降级成内嵌 framework，容器 Tab 就在 App 里；guest 启动仍可能重开进程，由冷启动入口接管。
- **免电脑首次安装** —— 网页生成一条命令，在「Open Minis」里粘贴，本地网页登录 Apple ID、自配对、签名、安装一条龙。全程不依赖 SideInstaller。
- **签名权留在手机上** —— 免费 Apple ID 就能签，7 天到期后台自动续；anisette 多服务器轮换，证书满/握手失败能自动切换。
- **中文是一等公民** —— 界面第一语言就是中文（`CFBundleDevelopmentRegion = zh-Hans`），不是英文之上的翻译补丁。
- **小组件直达** —— TreeWidget 已并入同一个包，从桌面小组件一键打开容器里的 App，配品牌过渡层遮住中间页面。

---

## ✨ 功能

| 功能 | 说明 |
|---|---|
| 📲 手机端签名 | 免费 Apple ID 直接在手机上签名安装 IPA，不用电脑常驻 |
| 🔄 后台自动续签 | 证书到期前自动刷新，不掉签 |
| 🌲 多 App 容器 | LiveContainer 内嵌为 Tab，导入 / 安装 / 启动 / 返回闭环；支持 Husk 翻译层跑部分安卓 APK/游戏 |
| 📍 虚拟定位 | 设备本地直连（Apple DVT 开发者服务）或 Mac 定位助手，系统级生效 |
| 🧩 小组件 | TreeWidget 并入主包，桌面一键直达容器 App |
| 🌐 Anisette 管理 | 服务器可排序、隐藏、自定义；多服务器轮换，优先用实测可用的节点 |
| 🎨 外观主题 | 跟随系统 / 浅色 / 深色 + 强调色；切前台加快照遮罩，杜绝闪屏 |
| ⏰ 到期提醒 | 证书到期前 24 小时提醒 |

---

## 📦 首次安装（免电脑）

1. 用 iPhone 的 Safari 打开 **[免电脑安装页](https://TreeNB.idoer.help/)**
2. 按页面提示复制那条命令
3. 在 **Open Minis**（一个在 iOS 上跑 aarch64 Linux 的开源终端）里粘贴执行
4. 终端会拉起一个**本地网页** → 在里面登录 Apple ID、过 2FA
5. 按网页指引打开系统「开发者选项」，用 **TreeNB 生成的配对码**完成自配对（方向是：TreeNB 生成码 → 你输入到系统设置里）
6. 网页自动签名并安装 TreeNB，装完打开即用

> 提示：Open Minis 已从 App Store 下架；已安装的用户仍可继续使用上面的流程。
> 免电脑路径需要 Open Minis 与 LocalDevVPN；配对文件与证书留在设备本机，TreeNB 发布站不接收账号凭据。
> 若某个 anisette 服务器登录失败，引擎会自动轮换到下一个；目前实测 `ani.jkcoxson.com` 可用。

---

## 🔨 从源码构建

要求：macOS 26 / Xcode 26（1307 使用 iOS 26 SDK；本机达不到请用 CI）。

```bash
./scripts/prepare_dependencies.sh   # 拉上游 → 打补丁 → xcodegen generate
xcodebuild archive -project TreeNB.xcodeproj -scheme TreeNB-App \
  -archivePath build/TreeNB.xcarchive -sdk iphoneos -arch arm64 \
  -configuration Release OTHER_LDFLAGS='$(inherited) -ld_classic' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
./scripts/assemble_ipa.sh
```

> Scheme 名是 `TreeNB-App`（不是 `TreeNB`）——避免与同名 target 冲突导致空 archive。
> 1307 固定使用 Xcode 26 + `-ld_classic`，不切换到 Xcode 27；构建踩坑见 `docs/CI构建踩坑记录.md`。

### 引擎（bootstrap）自检

免电脑安装用的静态引擎在 `bootstrap-engine/`，锁定 isideload 0.5.2 / idevice 0.1.68，CI 构建前会跑自检：

```bash
cd bootstrap-engine
./check-build.sh              # lock 一致性 + 精确版本 + 编译可行性
./check-build.sh --lock-only  # CI 用，跳过编译
```

### 在线更新服务

- 正式清单：`https://TreeNB.idoer.help/updates/latest.json`
- 1307 安装包：`https://TreeNB.idoer.help/downloads/TreeNB-202611281307-unsigned.ipa`
- 1307 只发布服务端清单和 unsigned IPA，不包含 App 内更新客户端。
- 下一版客户端按 `docs/在线更新服务协议.md` 校验版本、字节数和 SHA256，再使用当前账号既有证书在本机重签安装；服务器不接收 Apple ID、证书或私钥。

---

## 许可证

TreeNB 主项目沿用 openSSS 的 **AGPL-3.0**。Husk 为 **GPL-2.0-or-later**，ElleKit 为 **BSD-3-Clause**，其余第三方组件保留各自许可证、版权头与署名；具体以对应上游 LICENSE 和随包声明为准。
