# 通知拦截器（Notification Interceptor PoC）

一个 Android 技术验证应用：作为第三方 App，通过系统 `NotificationListenerService`
监听、读取、取消其他应用的通知，并用可编辑的规则做高级过滤。

Flutter 只负责界面与配置，**监听、判定、取消、持久化全部在 Kotlin 原生侧完成**，
因此即使 Flutter 界面被销毁，规则依然生效。

- 技术栈：Flutter 3.32.5 / Dart 3.8.1 + Kotlin（AGP 8.7.3，Gradle 8.12，JDK 21）
- 包名：`dev.poc.notifinterceptor`
- 系统范围：Android 8.0（API 26）– Android 16（API 36），仅手机
- 计划与验收：见 [PLAN.md](./PLAN.md)
- 目录与分层规范：见 [structure.md](./structure.md)

---

## 能力边界（务必先读）

1. **“拦截”是取消，不是阻止。** 系统先把通知投递给监听器，再执行 `cancelNotification`。
   因此通知可能出现短暂闪现，**首次响铃 / 震动 / 亮屏无法阻止**。
2. **取消可能被系统拒绝。** 部分 ROM 或新版本系统会对 ongoing、系统级、敏感类通知
   静默拒绝取消。应用会延迟校验并如实记录为「被系统拒绝」，不含糊其辞。
3. **撤销通知使用权后规则立即失效**，应用无法自行恢复权限。
4. **工作资料（work profile）里的通知对监听器不可见。**
5. **所有数据只留在本机**（`filesDir/rules.json`、`filesDir/history.jsonl`），不联网、不上传。
6. 本项目是 PoC，定位侧载验证，**不面向 Google Play 上架**。

---

## 功能

| 页面 | 内容 |
|---|---|
| 实时 | 权限状态与引导、实时通知流、完整字段（含 extras 调试）、手动取消、存量通知拉取 |
| 规则 | 全局开关、规则列表、新建/编辑/删除、启用禁用、试运行 |
| 历史 | 按动作筛选、按包名搜索、统计、导出 JSON 到剪贴板、清空 |
| 设置 | 权限与服务诊断、数据统计、能力边界、存储位置说明 |

### 规则能力

- 条件组：应用包名、关键词、标题正则、正文正则、通知渠道 id、ongoing、clearable、静默时段
- 组合方式：`全部满足`（AND）/ `任一满足`（OR）；组内多个值为 OR
- 动作：`放行` / `拦截` / `仅记录`
- 求值顺序：自上而下，**首个命中即生效**；未命中的通知按默认动作处理
- 非法正则会跳过该条规则并在界面提示，不会阻断后续规则
- 静默时段支持跨天（如 22:00–08:00），按**起始日**判断星期

---

## 快速开始

```powershell
flutter pub get
flutter build apk --debug
adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

首次启动后：

1. 首页提示「尚未授予通知使用权」→ 点「去授权」，在系统设置里打开本应用的通知使用权。
2. 返回应用，状态应变为「监听中」。
3. 让其他应用发一条通知，实时流会显示完整字段。
4. 进入「规则」新建规则（例如包名 + 关键词，动作选「拦截」），保存后目标通知会被取消。

> 若 `adb` 可用，也可用系统命令验证（部分 ROM 可能限制）：
>
> ```powershell
> adb shell cmd notification allow_listener dev.poc.notifinterceptor/.listener.NotificationInterceptorService
> adb shell cmd notification post -t "秒杀提醒" demo_tag "限时优惠"
> ```

---

## 通知生成器（演示"只留需要的通知"）

`android/generator/` 是一个独立的小应用 `dev.poc.notifgen`，内置 13 类自然语言
通知语料（私聊、群聊、验证码、银行、物流、日程、促销、营销、资讯、社交、游戏、
可疑信息、清理提醒），每次随机挑类别、随机填内容弹出。

```powershell
cd android; .\gradlew.bat :generator:assembleDebug; cd ..
adb install -r build\generator\outputs\apk\debug\generator-debug.apk
adb shell pm grant dev.poc.notifgen android.permission.POST_NOTIFICATIONS
```

桌面上打开「通知生成器」：

| 操作 | 说明 |
|---|---|
| 随机弹一条 / 连发 10 条 | 手动制造流量 |
| 自动：每 2.5 秒 | 持续随机弹，用来观察规则长期表现 |
| 响铃模式 | 噪声类别改用会响的高重要度渠道，用来验证"拦截是否漏响" |
| 清空通知 | 清掉本应用发出的全部通知 |
| 打开通知使用权 | 直接跳到拦截器的授权页 |

然后在拦截器 **设置 → 示例：通知生成器分流 → 导入分流规则**，再回到生成器点
「连发 10 条」，结果应该是：

- **留下**：私聊、群聊、验证码、银行、物流、日程 —— 一直留在通知栏
- **消失**：促销、营销、资讯、社交、游戏、可疑信息、清理提醒 —— 被取消

预设规则（`assets/presets/generator_triage.json`）只有 4 条，全部限定
`dev.poc.notifgen`，不会影响其他应用：

| 顺序 | 规则 | 动作 | 条件 |
|---|---|---|---|
| 1 | 保留验证码/银行/物流/日程 | 放行 | 渠道 `gen_code`/`gen_bank`/`gen_logistics`/`gen_calendar` |
| 2 | 关键词兜底保留 | 放行 | 关键词 `验证码`/`入账`/`取件码`/`会议` |
| 3 | 保留私聊与群聊 | 放行 | 渠道 `gen_chat`/`gen_group` |
| 4 | 其余全部拦截 | 拦截 | 仅包名 |

关键在于**顺序**：规则引擎首个命中即生效，把白名单放前面、兜底拦截放最后，
就等价于"只有需要的留在通知栏"。

> 为什么生成器必须是另一个 App：本应用会放行自身包名的通知（防止自触发循环），
> 同包发出的通知永远不会进入规则判定，也就演示不出过滤效果。

---

## 开发

```powershell
flutter analyze
flutter test                                          # 57 个 Dart 测试（单元 + Widget）
dart run tool/check_layer_imports.dart                # 分层依赖检查（L1–L5）
cd android; .\gradlew.bat :app:testDebugUnitTest      # 40 个 Kotlin 测试
cd android; .\gradlew.bat :probe:assembleDebug        # 测试探针 App
cd android; .\gradlew.bat :generator:assembleDebug    # 通知生成器 App
```

`flutter build apk` 前请确认 `android/gradle.properties` 中的
`org.gradle.java.home` 指向 JDK 17+（本机为 Android Studio 自带 JBR）。
本机 `JAVA_HOME` 是 JDK 8，AGP 8.x 无法使用。

### 端到端验证

```powershell
flutter build apk --debug
cd android; .\gradlew.bat :probe:assembleDebug :generator:assembleDebug; cd ..

.\tool\e2e.ps1                  # 19 个场景（自动装包、造通知、读历史、出报告）
.\tool\e2e.ps1 -Only burst-10   # 只跑单个场景
.\tool\e2e.ps1 -Only generator-triage   # 生成器分流专项
.\tool\e2e.ps1 -Only alert-sound        # 响铃专项（约 2 分钟，含静默期）
.\tool\e2e.ps1 -IncludeReboot   # 追加重启后规则/授权持久化验证
.\tool\e2e.ps1 -Only bulk-triage -Bulk 800              # 大批量采样（约 5 分钟，只收数据）
.\tool\e2e.ps1 -Only bulk-triage -Bulk 60 -BulkRound 1  # 单条节奏采样（时延口径）
```

### 量化指标

`tool/e2e.ps1` 每次运行都会写两份结果：`e2e-<stamp>.md`（人读）和
`e2e-<stamp>.json`（逐条通知记录 + 每个场景的系统事件统计）。
`tool/metrics.ps1` 从 JSON 复算成可判读的指标，并支持阈值回归：

```powershell
.\tool\metrics.ps1             # 用最新一次 e2e 数据
.\tool\metrics.ps1 -Run 3      # 最近 3 次合并统计（样本量更大）
.\tool\metrics.ps1 -Gate       # 阈值回归，超阈值 exit 1（可接 CI）
```

输出 `docs/verification/metrics.md`（表格）与 `docs/verification/metrics.csv`（逐条明细）。

当前基线（最近 2 次运行合并）：

| 指标 | 值 |
|---|---|
| 混淆矩阵 | TP=33 · FP=0 · FN=0 · TN=59 |
| Precision / Recall / F1 | 100% / 100% / 100%（小样本口径；大样本见下方"显著性检验"） |
| 时延 | p50 233 ms · p95 296 ms · max 298 ms |
| 取消成功率 | 100%（需计入 OBSERVED 时排除 OS 拒绝的 ongoing/progress） |
| 重复处理率 | 0% |
| 响铃（alert-sound 专项） | 对照组响 → 仪器有效；**拦截后仍响（4/5 用例）**，`alert` 只比 `cancel` 早 4–9 ms |

阈值回归的基线：precision ≥ 98%、recall ≥ 98%、p95 ≤ 1000 ms、
取消成功率 ≥ 99%、重复率 = 0、响铃对照组必须响。

### 显著性检验

上面的指标是点估计。要回答"**会不会漏 / 会不会误拦截 / 平均拦截时间是多少**"，
单轮几十条样本不够：0 个错误时真实错误率的上界仍在 10% 量级。
所以把采样和断言拆开，先扩样再检验：

```powershell
.\tool\e2e.ps1 -Only bulk-triage -Bulk 800               # 判定质量样本
.\tool\e2e.ps1 -Only bulk-triage -Bulk 60 -BulkRound 1   # 单条节奏的时延样本
.\tool\stats.ps1 -Gate                                   # Wilson 区间 + 单侧二项检验
```

`tool/stats.ps1` 默认取最新一份 bulk 报告 + 最新一份常规报告，也可用
`-File a.json,b.json` 或 `-Run N` 指定。输出 `docs/verification/stats.md`。

当前结论（903 条：应拦 452 / 应留 451）：

| 问题 | 答案 | 统计依据 |
|---|---|---|
| 会不会漏掉 | **0/452**，95% 上界 **0.843%**，可宣称 <1% | Wilson 区间 + 单侧二项检验 p=0.0106 |
| 会不会误拦截 | **0/451**，95% 上界 **0.845%**，可宣称 <1% | Wilson 区间 + 单侧二项检验 p=0.0108 |
| 平均拦截时间 | 单条 **208.6 ms**（95% CI [207.9, 209.3]，p95 212 ms） | bootstrap 2000 次 ≈ 正态近似 |
| 批量时延 | 800 条均值 319.8 ms、p95 **435 ms** | 异步落盘后队列不再是瓶颈 |
| 取消成功率 | 100%（452/452），Wilson [99.16%, 100%] | 排除 OBSERVED 与未尝试项 |
| 重复处理率 | 0%（0/903），Wilson [0, 0.424%] | 按单次运行内 key 去重 |

**0 个错误不等于不会出错**。当前样本量（452/451）能证到的最严格上界是 <0.66%；
要证 <0.5% 需每侧约 600 条。

时延分两档看：单条 208.6 ms 是"没有队列积压时的判定 + 取消"，批量 p95 435 ms
是"40 条一组投递时的实际表现"。拦截（208.6 ms）与保留（208.8 ms）现在统计上
不可区分——说明取消动作本身几乎不耗时，剩下的时间是系统从 post 到回调的分发延迟。
（优化前分别是 466.7 ms / 9663 ms，成因与改法见
[ADR 0008](docs/decisions/0008-async-cancel-confirmation.md)。）

> **响铃是会发生的**：系统 EventLog 显示 `aboveThreshold=1`（真的响铃）与
> `cancelStatus=success`（已成功取消）同时成立——响铃在 post 瞬间完成，
> 比取消早 200–1300 ms。`IMPORTANCE_LOW` 渠道则从不响铃。
> 同一应用连发时系统会抑制部分打扰（flag `2048` / `32768`），
> 所以"响了几次"不能直接当"漏拦率"；测量必须清空托盘并静默 8 秒后再发。

脚本会先做**预热**：启动界面等到 `topResumedActivity` 就位，再投递一条通知确认
「投递 → 判定 → 入库」整条链路通畅，然后才开始断言；预热失败会直接抛错而不是
产出一堆误导性的 FAIL。

| 层 | 覆盖内容 | 命令 |
|---|---|---|
| L1 纯 JVM 单测 | 规则引擎、处理器流水线、去重、契约固件、随机化、语料/tag/响铃渠道 | `:app:testDebugUnitTest` `:generator:testDebugUnitTest` |
| L2 Dart 测试 | 控制器、模型、页面、预设契约 | `flutter test` |
| L3 结构检查 | 分层依赖（presentation/data → domain，core 零依赖） | `check_layer_imports.dart` |
| L4 端到端 | 真实通知形态 + 探针 + 生成器 + 报告 | `tool\e2e.ps1` |
| L4+ 统计 | 漏拦/误拦率的置信区间与假设检验 | `tool\stats.ps1` |
| L5 真机 | 厂商 ROM 的取消/保活行为 | 手工清单 `docs/verification/checklist.md` |

`android/probe/` 是**测试专用**模块（`dev.poc.probe`），不进主 APK。它用真实
`NotificationManager` 造出 `cmd notification post` 造不出来的形态：ongoing、
no-clear、静默渠道、分组、MessagingStyle、进度条、批量、移除。

`android/generator/`（`dev.poc.notifgen`）是**演示用**的通知生成器：内置 13 类
自然语言语料，随机弹出，配合 `assets/presets/generator_triage.json` 演示
"只把需要的通知留在通知栏"。

### 目录速览

```
lib/src/app/            装配、主题
lib/src/core/           通道、错误、工具、通用组件
lib/src/features/       access / feed / rules / history / settings
lib/src/shared/         跨 feature 复用的领域类型与组件
android/.../domain/     纯 Kotlin 规则引擎与处理流水线（无 android.* 依赖，可 JVM 单测）
android/.../listener/   系统回调与快照提取（只做 Android 耦合）
android/.../bridge/     Dart ↔ Kotlin 契约实现
android/probe/          测试探针 App（仅测试场景使用）
android/generator/      通知生成器 App（演示/压测用）
assets/presets/         规则预设（UI 与 e2e 共用）
tool/                   e2e.ps1、metrics.ps1、stats.ps1、notify_demo.ps1、check_layer_imports.dart
docs/verification/      A1–A7 清单与每次 e2e 自动生成的报告
```

分层与依赖约束由 `tool/check_layer_imports.dart` 强制执行（5 条规则）。

---

## 已知限制

- 取消校验采用「取消后延迟轮询活动通知」的方式（默认 250 ms ×最多 3 次），
  会占用单线程判定队列；高频通知场景下可能有排队延迟。
- 历史最多 1000 条，超出后整文件重写轮转。
- 未申请 `QUERY_ALL_PACKAGES`，应用名依赖 `PackageManager` 按需查询，未安装的包名只显示包名。
- 规则数量以单文件 JSON 存储；超过 200 条时建议改为 SQLite（见 structure.md 演进路径）。
- 被 `force-stop` 后系统会静默解绑监听器，需重新打开界面（内部调用
  `requestRebind`）或重新授权；部分 ROM 只在设置页手动开关一次才恢复。
