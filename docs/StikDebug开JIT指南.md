# TreeNB 用 StikDebug 开 JIT 指南（iOS 27）

## 为什么改走这条路

guest 启动报 `code signature invalid`（uKit / AirTrackpad 都一样），根因是
JIT-less 签名链路的 team 匹配问题，而你这边 team 反复变化、证书管理很痛苦。

上游 LiveContainer 在 iOS 26+ 硬性禁止纯 JIT 模式（LCBootstrap.m 两处
`@available(iOS 26.0,*) → return "JITLess mode is required"`），所以 iOS 27
设备一直被逼着走证书。TreeNB 已 patch 放开这两处限制，配合 StikDebug 开 JIT
后，guest 直接用经典 JIT 路径（`checkJITEnabled → init_bypassDyldLibValidation
→ dlopen`），**不再需要 p12 / team / 重签**。

前提：`get-task-allow` entitlement 已在 TreeNB 签名配置里（config/TreeNB.entitlements
+ TreeNB_adhoc.xml），侧载工具重签会保留，StikDebug 可附加。

---

## 第 1 步：装必要 App

1. **LocalDevVPN**（App Store 直接装）：建立本机调试隧道
   - 打开 → 点 Connect → 允许 VPN 配置 → 等状态变 **Connected**

2. **StikDebug**（官方 GitHub Release 的 IPA，用 TreeNB / 侧载工具签名安装）：
   - 下载：`https://github.com/StikDebug/StikDebug/releases/latest`
   - 最新版本 3.2.2（3.2.0+ 才支持 iOS 27 设备端配对）
   - 装完去 设置 → 通用 → VPN与设备管理 → 信任开发者证书

> 只有 iOS 27 能纯手机端配对。iOS 26 及以下需要电脑用 iloader 放配对文件。

---

## 第 2 步：设备端生成配对文件（iOS 27，不用电脑）

1. 确认 **开发者模式已开**：设置 → 隐私与安全性 → 开发者模式
2. 确认 **LocalDevVPN 已 Connected**、Wi-Fi 开、手机解锁
3. 打开 **StikDebug** → Settings → **Pair a Device** → **Pair iPhone or iPad**
4. 系统弹出配对请求时按提示完成（可能要去开发者模式里输配对码）
5. 成功后 StikDebug 自动保存配对信息

> 注意：改过/重置过锁屏密码会让旧配对文件失效，必须重新配对。

---

## 第 3 步：给 TreeNB 开 JIT（关键）

1. 打开 **LocalDevVPN**，确认 Connected
2. 打开 **StikDebug** → Apps / Enable JIT 列表
3. 找到 **TreeNB**（宿主 App，bundle id `com.openssai.app`）选中
4. 按提示完成 JIT 激活，等调试连接建立

> 有些 App 在 iOS 26+ 需要专属脚本。先查官方支持列表：
> `https://github.com/StikDebug/StikDebug/blob/main/SUPPORTED_APPS.md`
> TreeNB 是 LiveContainer fork，若列表里没有，仍可尝试通用 JIT（带
> get-task-allow 的侧载 App 通常能附加）。

---

## 第 4 步：用无证书 + JIT 版包

**必须用不带 p12 的 JIT 版包**（当前带证书的包会走 JITLess 分支，不检测 JIT）。

覆盖安装 JIT 版包后：
1. **先移除已导入的证书**：进树应用容器页 → 钥匙图标 → 移除证书
   （App Group 里残留的 LCCertificatePassword 会让上游继续走 JITLess）
2. 按第 3 步给 TreeNB 开 JIT
3. 回到「树🌲侧载」点 üMoKit / AirTrackpad 启动 guest

---

## 常见坑

| 现象 | 原因 / 解决 |
|---|---|
| StikDebug 连不上 / heartbeat 错 | LocalDevVPN 没连、Wi-Fi 关、手机锁屏、配对文件失效 |
| ServiceNotFound | 开发者模式卡住：关掉开发者模式→重启→重开，一气呵成 |
| 目标 App 不在 JIT 列表 | 签名不含 get-task-allow，或 iOS 26+ 需要专属脚本 |
| guest 仍报 code signature invalid | 证书没移除干净（LCCertificatePassword 还在），或 JIT 没真正开启 |
| 配对突然失效 | 改过锁屏密码，重新 Pair a Device |

---

## 验证是否成功

进 guest 后能正常显示界面（不再弹「容器错误」dlopen 失败），即 JIT 路径生效。
若仍失败，把容器页完整错误截图发回，重点看错误是
`JIT was not enabled` 还是 `code signature invalid`，两者指向不同环节。
