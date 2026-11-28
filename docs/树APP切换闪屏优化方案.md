# 树 APP 切换闪屏优化方案

更新日期：2026-11-28
状态：草案，仅完成机制分析与实施边界设计，尚未修改启动代码。

## 1. 问题定义

用户看到的现象是：从 TreeNB 点击树 APP，界面先闪一下，随后回到 TreeNB，需要再次进入树 APP 才能打开。

这不是单纯的“过场动画不好看”。当前架构包含一次真实的进程重启；重启前宿主画面、系统启动快照、冷启动接管和 guest 首帧之间的任何竞态，都可能暴露成闪屏或失败回落。

目标按优先级排列：

1. 不失败、不回到错误 App、不要求用户重复点击。
2. 不重复发起重启，不产生可见的宿主中间态。
3. 在不增加新遮罩、不跳过引导页、不引入上下黑边的前提下，弱化不可避免的系统启动差异。

## 2. 当前真实链路

### 2.1 点击到 guest 接管

1. `LCEngineEntry.launchGuestApp` 检查 guest 和容器元数据，写入 `selected`、`selectedContainer`、`launchAppUrlScheme`、`LCOpenSideStore=NO` 和 `TNBGuestLaunchIntentTS`，然后请求重启。
2. 上游 `LCSharedUtils.launchToGuestAppWithClassicMode` 通过 `LSApplicationWorkspace` 重新打开同一个 bundle。
3. 上游在 completion 中执行 `ptrace(PT_DENY_ATTACH)` 和 `raise(SIGKILL)`，当前宿主进程被终止。
4. 新进程进入 `main.swift`，在 `UIApplicationMain` 之前调用 `takeOverIfGuestPending`。
5. 接管函数检查 15 秒新鲜度、guest 元数据和 `LiveContainerMain` 符号，再调用 `lcMain`。
6. guest 成功时接管整个进程且不返回；失败时返回，TreeNB 清理选择状态并启动宿主 UI。

对应源码：

- `Sources/Bridge/LCEngineEntry.m:453`：冷启动接管、15 秒新鲜度、元数据校验和失败回落。
- `Sources/Bridge/LCEngineEntry.m:609`：容器点击入口、选择状态写入和重启请求。
- `scripts/patch_upstream.sh:710`：把接管点前移到 `UIApplicationMain` 之前，避免宿主 UIApplication 单例与 guest 再次初始化冲突。
- `Sources/UI/TNBFlickerGuard.swift:30` 与 `Sources/UI/TreeLaunchOverlay.swift:14`：当前进程内遮罩。

### 2.2 上游重启实现的风险

当前上游实现有三个直接风险：

1. `tries = 2` 的循环没有等待第一次请求完成，会连续发起两次打开同一 bundle 的请求。
2. completion 的 `success` 被忽略，失败也执行 `SIGKILL`。
3. 当前进程被杀死后，新进程是否成功接管完全取决于冷启动状态；失败只能回到宿主。

因此，“先闪一下再回 TreeNB”可能来自重复重启、打开失败仍杀进程、冷启动接管失败或系统快照切换。现有日志能区分其中一部分，但不能把四者混成一个原因。

## 3. 已经排除的错误方向

### 3.1 不能靠加厚 UIWindow 遮罩根治

`TNBFlickerGuard` 和 `TreeLaunchOverlay` 都只存在于当前进程。`SIGKILL` 后其内存和 UIWindow 一起消失，无法覆盖下一次冷启动。

继续增加遮罩时长、层级或淡出动画，只能延长“正在切换”，不能修复失败回落，还违反“禁止闪屏遮罩”的基线。

### 3.2 不能回到 didFinishLaunching 热接管

历史真机崩溃已经证明：宿主 `UIApplicationMain` 创建 UIApplication 单例后，guest 再调用自己的 `UIApplicationMain`，会触发 `Dispatch queue already set`。

任何优化都必须保留 `main.swift` 中、宿主 `UIApplicationMain` 之前的接管点。

### 3.3 不能在失败时假装成功

如果忽略 `LSApplicationWorkspace` 的失败结果继续杀进程，用户会随机回到宿主。必须让失败发生在当前可见宿主中，保留宿主可操作状态，并给出可诊断错误。

### 3.4 不能继续把“请求已发出”当成“guest 已启动”

当前桥接接口的 `BOOL` 返回值只能表示重启请求是否发出，不能证明 guest 已接管。UI 和日志必须区分 `requested`、`relaunching`、`takeover`、`failed`、`consumed`。

## 4. 推荐实施顺序

### 阶段 A：低成本、必须优先做的稳定性修复

#### A1. 单次重启，失败不杀进程

修改上游补丁，而不是在 TreeNB 外层再包一次重试：

- 删除 `tries = 2`，每次用户操作只允许一个 in-flight restart。
- 检查 completion 的 `success` 和 `NSError`。
- 只有系统确认重开成功后才终止当前进程。
- 失败时不清空所有诊断上下文，不杀宿主；恢复桥接状态、清理未消费意图并通知 UI。
- 对 completion 做幂等保护，避免重复回调造成重复退出或重复通知。

需要同步调整桥接 API：从“上游负责在 completion 中杀进程”改为“TreeNB 收到明确结果后决定退出或恢复”。不能只修改上游函数却让 `launchGuestApp` 继续把立即返回的 `YES` 当成最终成功。

#### A2. 启动意图状态机

在现有时间戳基础上增加不可歧义的状态，而不是继续叠加更多独立键：

| 状态 | 含义 | 允许迁移 |
|---|---|---|
| `requested` | 已校验 guest，准备请求重启 | `relaunching` / `failed` |
| `relaunching` | 系统已确认重开请求 | `takeover` / `failed` |
| `takeover` | 新进程正在接管 | `consumed` / `failed` |
| `consumed` | guest 已接管或已明确退出 | 终止 |
| `failed` | 当前进程仍存活，需恢复宿主 | 终止或由用户重试 |

建议字段：

- `intentID`：UUID，防止旧 completion 修改新操作。
- `bundleID`、`containerID`、`source`、`classicMode`。
- `requestedAt`、`state`、`attempt`。
- `lastErrorCode`、`lastErrorStage`：只存可枚举错误和脱敏阶段。

写入必须完整、同步，再发起重启。冷启动只消费与当前 `intentID` 匹配的 `relaunching` 或 `takeover` 意图；过期、缺字段、状态不符时按失败处理，不能误开上次 App。

#### A3. 冷启动路径减负

`ensureHostLaunchOverrides` 当前还会安装 TweakLoader 软链并尝试自动导入内置证书。冷启动接管应只做 guest 必需的 URL scheme、App Group 和运行前置条件。

首次导入、后台重签、数据迁移和列表刷新不得阻塞 `UIApplicationMain` 之前的接管路径。它们应移到明确的后台或宿主启动分支，避免系统启动画面停留过久后被用户感知为闪回。

#### A4. 统一失败出口

失败时只做三件事：

1. 保留或写入 `TNBLastGuestLaunchError`。
2. 清理本次未消费意图，不能清除其他账号或 guest 数据。
3. 恢复宿主交互并展示现有错误排查入口。

禁止失败后再次自动请求重启，避免无限循环和连续闪屏。

### 阶段 B：可观测性与真机归因

在真机修复前，先收集一次完整证据链。每阶段只记录时间、状态和错误枚举，不记录凭据。

| 事件 | 必记字段 |
|---|---|
| `launch.requested` | intentID、bundleID、containerID、source、classicMode |
| `launch.workspace_result` | intentID、success、errorCode、耗时 |
| `launch.process_exit` | intentID、state、退出阶段 |
| `launch.cold_begin` | intentID、bundleID、age、设备/系统版本 |
| `launch.metadata_result` | intentID、是否找到 LCAppInfo/LCDataUUID |
| `launch.symbol_result` | intentID、是否找到 LiveContainerMain |
| `launch.lc_returned` | intentID、返回值、上游 error 枚举 |
| `launch.recovered` | intentID、失败阶段、是否保留宿主 |

验收时用同一设备连续执行至少 20 次容器点击、20 次小组件冷启动和 10 次 guest 返回后再切换。出现一次回宿主也要保留完整日志，不能只统计成功次数。

### 阶段 C：视觉弱化，不作为修复替代

只有在阶段 A 稳定后，才处理系统启动快照与 guest 首帧的差异：

- 保持现有品牌 LaunchScreen 与 guest 首帧的底色、深浅色和安全区一致。
- 不在重启前额外渲染宿主二级页面、弹窗或半透明过渡。
- 不增加新的 UIWindow 遮罩，不延长现有遮罩来隐藏失败。
- 避免启动过程中切换全局主题；guest 首帧应直接使用最终状态。
- 如果系统仍强制显示宿主快照，应记录为平台限制，不通过跳过引导页或黑屏规避。

### 阶段 D：架构研究，不纳入当前修复

长期目标是评估 guest 独立进程 / appex + XPC，避免杀死宿主。但当前 LiveContainer 依赖进程级 UIApplication、NSBundle swizzle 和 JIT 状态，不能直接假设拆进程可行。

启动该研究前必须先做 Spike：JIT 获取、返回键、数据容器、崩溃隔离、后台生命周期和 iOS 15 兼容。未通过 Spike 前不重写主启动链。

## 5. 真机验收标准

### 5.1 功能正确

- 容器内连续切换不同 guest，全部进入用户点击的目标。
- 小组件冷启动进入目标 guest，不误开上次 guest。
- guest 启动失败时停留在 TreeNB，错误入口可操作。
- 返回主壳后再启动，不出现旧 intent 或旧 completion 干扰。
- 同一时刻快速点击两个 guest，只允许最后一个有效请求或明确拒绝后一个，不能并发重启。

### 5.2 体验正确

- 不出现宿主列表、弹窗或错误页面的可见中间帧。
- 不出现上下黑边、缩小的圆角窗口或主题白闪。
- 不跳过引导页，不新增遮罩，不用更长等待冒充优化。
- 无法消除的系统启动画面差异必须稳定、一致，并且不能导致失败。

### 5.3 诊断正确

- 每次失败都能定位到 workspace、冷启动入口、元数据、符号或 guest 接管阶段。
- 日志不含密码、Token、p12、私钥、完整配对文件或 anisette 数据。
- 连续压力测试后无重复 intent、无悬挂 `relaunching`、无重复 completion 副作用。

## 6. 回滚与风险

- 阶段 A 涉及上游补丁和进程生命周期，必须独立提交、独立 CI、独立真机验收。
- 如果新状态机导致冷启动无法接管，立即回退到当前 15 秒时间戳方案，但保留单次重启和失败不杀进程的修复。
- 不把阶段 C 的视觉调整与阶段 A 的生命周期修复混在一个构建里，否则无法判断回归来源。
- 1307 保持当前已发行状态；本文方案进入下一版实施，不把草案写成已修复。
