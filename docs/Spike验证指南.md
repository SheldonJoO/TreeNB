# TreeNB Spike 验证指南（真机三问 · 零 Xcode 依赖）

> **在写任何业务代码前，必须先过这三关。** 这是整个方案最大的风险闸门。
> 核心风险：LiveContainer 的 `invokeAppMain` 天生假设"我是主 executable"。
> 当它被降级为 openSSS 内嵌 framework 时，全局 swizzle（`UIApplication` / `NSBundle.mainBundle`）
> 是否会跟宿主打架，纸上谈兵没用，必须真机验证。
>
> **好消息：这一步完全不需要你这台 Mac 装 Xcode 16.4。** 出包在 CI，验证在真机 + App 内自检页。

## 你要做的只有三步（不用碰 Xcode）

1. **CI 打个 Spike 包**：GitHub 仓库 → Actions → `TreeNB Build` → `Run workflow` →
   勾选 **Spike 自检包** → 运行。Runner 用 `macos-15-intel`，自带 Xcode 16.4。
2. **下载 artifact** `TreeNB-spike`，得到一个**未签名 IPA**。
3. **装到真机**：用你顺手的任意工具签名安装——爱思助手 / Sideloadly / AltStore 均可
   （免费 Apple ID 就行，7 天有效足够验证）。这些工具自带签名逻辑，**不依赖 Xcode 16.4**。

安装完打开 App → 进「容器」Tab → 右上角 🧪 自检，三问结果**直接以红绿勾显示在屏幕上**，
不用连电脑、不用开控制台、不用看日志。还可以「复制报告文本」贴给我分析。

---

## 三问（面板上的判定标准）

### Q1 — 主壳能起来吗

App 打开后 Shell 显示 **4 个 Tab**：Apps / 定位 / 容器 / 我的。
- ✅ 面板 Q1 绿勾（Tab 数 = 4）
- ❌ 红勾或闪退 → **停**，检查 `patch_upstream.sh` 的 Shell 注入步骤

### Q2 — 引擎能内嵌吗

引擎 framework 是否正确链入、`LiveContainerMain` 符号能否解析、`bootstrap` 是否成功。
- ✅ 面板 Q2 绿勾（`dlsym=✅, bootstrap=✅`）
- ❌ `dlsym` 失败 → LC framework 没链进来，检查 `project.yml` 的 embed/link
- ❌ `bootstrap` 失败 → 检查 entitlements 的 App Group 是否含 `group.openssai.app`

### Q3 — guest 能往返吗（最关键）

先通过容器 Tab 导入一个最小 guest IPA，然后在自检页输入它的 `.app` 目录名，点「启动 guest 测往返」：
1. guest 全屏运行（进程主线权交给 guest）
2. 点悬浮返回键 → 回到 TreeNB 容器 Tab，**不是杀进程重启**
3. 面板追加「Q3 guest 返回 ✅ 往返闭环成立」

- ✅ 三问全绿 → 方案 A 成立，铺开业务代码
- ❌ guest 卡死 / swizzle 冲突 / 无法返回 → **立即止损**转方案 B（appex + XPC，见可行性报告 §方案B）
- ❌ 只是返回不稳 → 查 `LCEngineEntry.restoreAfterGuestExit` 通知是否发出

## 判定记录（复制报告文本贴给我即可）

面板的「复制报告文本」会生成如下格式，直接贴给我：

```
===== TreeNB Spike 自检报告 =====
时间: ...
✅ Q1 主壳能起来: Tab 数 = 4
✅ Q2 引擎能内嵌: LiveContainerMain=✅, bootstrap=✅
✅ Q3 guest 启动: 已交给 guest
✅ Q3 guest 返回: 往返闭环成立
结论: 全部通过，可写业务代码
```

**三问全绿之前，禁止写 Container 高级功能 / Widget 增强 / 应用源对接代码。**

---

## 附：深入了解（可选）

如果想看原始日志（排错时用），Mac 自带的「控制台」App → 选你的真机 → 过滤 `TNB-SPIKE`，
能看到探针的原始 `print` 输出。**这一步用系统控制台就行，跟 Xcode 版本无关。**

技术细节与改造清单见 `启动链改造设计.md` §5。
