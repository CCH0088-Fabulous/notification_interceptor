# 验收记录

对应 [PLAN.md](../../PLAN.md) 第 5.1 节的 A1–A7。需要设备/ROM 的项记录实测结果。

## 环境

| 项 | 值 |
|---|---|
| 设备 | Android Studio 模拟器 `Medium_Phone`（Android 16 / API 36 / google_apis_playstore / x86_64） |
| 应用 | `dev.poc.notifinterceptor` debug 构建，`flutter build apk --debug` |
| 授权方式 | `adb shell settings put secure enabled_notification_listeners <component>`（Play 镜像上 `cmd notification allow_listener` 无效） |
| 造通知 | `adb shell cmd notification post -t 秒杀 <tag> 限时优惠` |
| 观测 | `adb logcat -s NotifInterceptor`、`dumpsys notification --noredact`、`run-as ... cat files/history.jsonl` |

## 自动化状态

| 命令 | 结果 |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test` | 57 passed（单元 + Widget） |
| `gradlew :app:testDebugUnitTest` | 49 passed（含取消确认 8 项 + 异步落盘 2 项） |
| `gradlew :generator:testDebugUnitTest` | 6 passed（语料可复现 + tag 契约 + 响铃渠道选择） |
| `dart run tool/check_layer_imports.dart` | 5 条规则通过 |
| `tool/e2e.ps1` | PASS 11 · FAIL 0 · OBSERVED 8（19 个场景，报告见 `docs/verification/reports/`） |
| `tool/e2e.ps1 -Bulk 800` | 采样 800 条（`uniqueTags=800`、`zeroRounds=0`），只收数据不断言 |
| `tool/metrics.ps1 -Gate` | 通过（precision/recall 100%、p95 296 ms、取消成功率 100%、重复率 0、响铃对照组有效） |
| `tool/stats.ps1 -Gate` | 通过（903 条：漏拦 0/452、误拦 0/451，双侧均可宣称 <1%） |

## 量化基线（`docs/verification/metrics.md`）

| 指标 | 值 | 说明 |
|---|---|---|
| 混淆矩阵 | TP=33 · FP=0 · FN=0 · TN=59 | 最近 2 次运行合并（`metrics.ps1` 口径） |
| Precision / Recall | 100% / 100% | 小样本口径；显著性检验见 `stats.md`（903 条，双侧 <1%） |
| 时延 | p50 233 ms · p95 296 ms · max 298 ms | ADR 0008 后；改前 p50 1967 ms、p95 5216 ms |
| 取消成功率 | 100%（54/54） | ongoing/progress 的 `rejected` 属 OBSERVED，不计入 |
| 重复处理率 | 0% | 去重生效 |
| 响铃（alert-sound） | 对照组 2/2 响 · **拦截后仍响 8/10** | 见下方"响铃"小节 |

## A1–A7 结果

| 编号 | 验收项 | 证据 | 结果 |
|---|---|---|---|
| A1 | 授权后服务连接，实时流显示全字段 | 未启动界面时系统已绑定服务进程；`history.jsonl` 记录包含 title/text/bigText/textLines/subText/category/channelId/groupKey/ongoing/clearable/priority/progress 与 extras；e2e 预热在无 UI 时即可入库 | **通过** |
| A2 | 规则命中后通知被取消并记录 | e2e `intercept-basic` / `intercept-silent-channel` / `intercept-messaging`：`action=intercept cancel=success present=False`（延迟 0.4–0.5 s）；`allow-non-matching` 反证规则未命中时不取消 | **通过** |
| A3 | 界面销毁后规则仍生效 | e2e `ui-closed`：`am force-stop` → 重启界面 → BACK → 造通知仍 `intercept`。注意 force-stop 会让系统静默解绑，脚本先做就绪探测再断言 | **通过** |
| A4 | 首条命中、非法正则、静默时段 | `RuleEngineTest` 16 项 + `RuleEngineStressTest` 4 项（500 轮随机化）+ `rule_validation_test.dart` | **通过** |
| A5 | 重启后规则与历史保留 | `tool/e2e.ps1 -IncludeReboot` → `reboot-persistence`；`adb reboot` 后监听授权、`rules.json`、history 均保留 | **通过** |
| A6 | ongoing / 系统级 / 敏感通知取消结果被记录 | 探针 App `dev.poc.probe` 合成 ongoing / no-clear / progress 通知：API 36 上 **ongoing 与 progress 取消被系统拒绝（`rejected` 且通知仍在）**，no-clear 可正常取消（`success`）。三态如实落库并被 e2e 记录 | **通过（API 36）** |
| A7 | 无自触发循环、无 ANR/闪退、历史轮转 | 自身包名放行有单测；e2e `burst-10` 10 条通知 `entries=10 unique=10 duplicates=0`（去重生效）；整轮 logcat 无 `FATAL`/`ANR` | **通过** |

## 实测发现

1. **API 36 Play 镜像不支持 `cmd notification allow_listener`**：命令无报错但不生效，
   必须用 `settings put secure enabled_notification_listeners` 或手工授权。
   已沉淀到 `tool/notify_demo.ps1`。
2. **`cmd notification post` 的参数在 PowerShell → adb → shell 多层传递时会按空格拆开**：
   `-t "A3 前台测试"` 实际变成 `-t A3` + tag=`前台测试`。测试时标题/正文避免空格。
3. **`cmd notification post` 会额外产生一条 group summary**（id=0、title/text 为 null）。
   关键词规则不会命中它，属于预期行为；仅按包名匹配的规则会同时命中汇总通知。
4. **规则缓存按文件 mtime 失效**：最初实现只在进程内缓存，外部改写 `rules.json` 不生效；
   已改为比较 `lastModified()`，现可在不重启进程的情况下通过 adb 调整规则。
   对应场景 `rules-hot-reload`。
5. **系统会对已存在的通知重复回调 `onNotificationPosted`**（ranking 变化、重新绑定、
   分组重排）。未去重时 `burst-10` 实测 `processed=20/10`，引入
   `NotificationDeduplicator` 后稳定为 `entries=10 unique=10 duplicates=0`。
6. **MessagingStyle 通知的标题会被系统改写成 conversation title**。探针未调用
   `setConversationTitle()` 时标题变成 "Probe"，按标题关键词匹配会漏命中——
   这类"规则明明对却没命中"的假故障，只有真实形态通知才能暴露。
7. **取消判定不能只看一次 250 ms 后的查询**：设备繁忙时移除会滞后，
   普通通知被误判成 `rejected`。现已改为最多 3 次轮询（任一次消失即 `success`），
   ongoing/progress 在同样轮询下仍稳定 `rejected`，结论更可信。
8. **`force-stop` 后系统解绑监听器且不会自动重绑**，即使 `enabled_notification_listeners`
   仍包含本应用、`dumpsys` 里仍有 `ServiceRecord`。打开界面调用
   `NotificationListenerService.requestRebind()` 可恢复；极端情况下需重启设备。
   e2e 因此把"就绪"定义为**功能性判据**（真的收到一条通知并入库），而不是查绑定状态。
9. **Debug 构建在这台模拟器上冷启动超过 40 秒**（`am start -W` 报 `Status: timeout`），
   装包后立刻断言会把启动耗时误判成功能故障。脚本改为等 `topResumedActivity`
   （API 36 的字段名，老版本是 `mResumedActivity`）再做预热。
10. **撤销授权不会立刻解绑**：把本应用从 `enabled_notification_listeners` 移除后，
    系统仍保持已建立的绑定（`dumpsys notification` 里依旧是 live listener），
    拦截会继续生效，直到进程被回收或用户手工在设置页关闭。因此
    `permission-revoked` 场景记 OBSERVED 而非 PASS：这条**不能**用
    "现在还能不能拦截"来判断，只能以 `NotificationAccess.isGranted()`
    （UI 上的授权状态）为准。
11. **系统自动分组的聚合通知会继承渠道 id**：生成器发出 24 条后历史里多出 2 条
    聚合条目，它们的 `channelId` 是 `gen_code` / `gen_spam`，但 tag 形如
    `0|dev.poc.notifgen|g:Aggregate_AlertingSection`、id 为 0/1。
    端到端脚本必须按 tag 前缀（`gen_`）过滤，否则会把"系统汇总"误判成
    "多处理了几条 / 白名单漏了"。

## 生成器分流实测（`generator-triage`）

| 项 | 结果 |
|---|---|
| 随机生成 | 24 条（13 类语料加权随机，`seed=42` 可复现） |
| 应保留（白名单渠道/关键词） | 14 条（某次运行 9 条，取决于抽到的类别） |
| 实际留在通知栏 | 与应保留集合完全一致，`missing=0` |
| 非白名单残留 | `intruders=0` |
| 拦截结果 | `cancelFailed=0`（全部 `cancelStatus=success`） |
| 持久性 | 8 秒后再次探测，集合不变（`unstable=0`） |

结论：用「先白名单、后兜底拦截」的 4 条规则即可让生成器的噪声通知不落到通知栏，
而验证码/银行/物流/日程/私聊/群聊保持常驻。

## 响铃实测（系统 EventLog，受控协议见 ADR 0006）

2026-10-18 复测（ADR 0008 时延优化**之后**，报告 `e2e-20261018-194608`）：

| 用例 | 入队 | 实际打扰 | 被拦截 | 结论 |
|---|---|---|---|---|
| 放行 + DEFAULT（对照组） | 1 | 1 | 0 | 仪器有效（不响则整轮测量无效） |
| **拦截 + DEFAULT** | 1 | **1** | 1 | **取消成功也会响**：`cancelStatus=success` 与 `aboveThreshold=1` 同时成立 |
| 拦截 + `IMPORTANCE_LOW` 渠道 | 1 | 0 | 1 | 低重要度渠道天生不响 |
| 拦截 + 3 条间隔 8 s | 3 | 2 | 3 | 仍然响；系统还抑制了其中 1 条（flag 32768） |
| 拦截 + 5 条连发 | 5 | 1 | 5 | 其余被合并抑制（flag 2048 / 32768） |
| 生成器噪声类别 + 响铃模式 | 3 | 2 | 3 | 真实语料同样漏响 |

### 时序证据：我们只比系统响铃晚 4–9 ms

从 `logcat -b events` 抽出同一个 key 的 `notification_alert` 与 `notification_canceled`
时间戳（2026-10-18 19:46 采样）：

| key | 系统是否响铃 | alert → cancel |
|---|---|---|
| `gen_game_888` | 是（`aboveThreshold=1`） | **9 ms** |
| `gen_chat_889` | 否（`aboveThreshold=0`） | 4 ms |
| `gen_marketing_890` | 是（`aboveThreshold=1`） | 5 ms |

直读原始日志可以看出先后顺序：

```
11:34:47.554  notification_enqueue  ← 应用 post
11:34:47.757  notification_alert    ← 系统播放提示音（+203 ms）
11:34:47.764  notification_canceled ← 我们取消（+210 ms，晚 7 ms）
```

**系统先响铃（757），再把通知派发给监听器（~762）。** 我们的反应窗口只有
最后那几毫秒，而取消通知不会中断已经播放的声音。

这条时序把"响铃还在不在"从"我们够不够快"变成了一个物理约束：
即使取消延迟降到 0，`alert` 也已经发生在更早的时刻。ADR 0008 把取消从 466 ms
压到 208 ms（等于系统分发下限），**响铃结果完全不变**——6 个用例前后一模一样。

由此确认三件事：

1. **"长久留下"的通知照常响铃**：放行等于不干预，与不装本应用完全一致。
2. **被拦截的通知也已经响过**：系统在派发回调之前就已播放提示音。
   这是平台时序，不是实现缺陷，也无法通过优化取消速度解决（已实测证伪）。
   要真正静音只有三条路：把渠道重要度降为 `IMPORTANCE_LOW`（需能改**他人**渠道，
   普通第三方 App 无此权限）、申请勿扰访问权限后开 DND（粒度是全局/应用级，
   无法按单条通知），或依赖厂商白名单。
3. **"响了几次"不能当"漏拦率"**：系统会对同一应用的连续通知做打扰抑制
   （`2048` 合并抑制 / `32768` 其他抑制）。

测量协议的四条硬约束（缺一条结论就不成立）：

- 每个用例前 `CLEAR` 清空托盘——否则新通知并入已有分组会被判为"更新"而不打扰；
- 清空后**静默 ≥8 秒**再发——实测 900 ms 时单条用例得到 `alerted=0`，
  8 s 时稳定 `alerted=1`（4/4）；这是系统抑制窗口，不是你我的行为；
- 必须有"放行 + DEFAULT"对照组——不响就说明设备静音/勿扰，整轮作废；
- 只断言**单条**用例的响铃，多条只记 OBSERVED。

`dumpsys audio` 的 focus 日志是有界缓冲（实测 25 条后停更），只能旁证，不能当计数器；
可听性还需同时记录音量（实测 5/7）与 `zenMode=0`。

## 显著性检验（`docs/verification/stats.md`，协议见 ADR 0007）

单次 e2e 只有几十条样本，0 错误时真实错误率上界仍在 10% 量级，不足以支撑
"不会漏 / 不会误拦"这种说法。所以把**采样**和**断言**拆开，先扩样再检验。

采样口径：`tool/e2e.ps1 -Only bulk-triage -Bulk 800`（判定质量，40 条/轮）
+ `-Bulk 60 -BulkRound 1`（时延，单条节奏）+ 一轮常规 e2e（覆盖非生成器场景）。

| 项 | 结果 |
|---|---|
| 样本量 | 903 条（应拦 452 / 应留 451），采集率 100%（860/860 生成器通知） |
| 去重 | `uniqueTags=800`、`uniqueTags=60`，无重复 tag |
| 漏拦 | **0/452**，Wilson 95% [0, 0.843%]，二项检验 p=0.0106 → **可宣称 <1%** |
| 误拦 | **0/451**，Wilson 95% [0, 0.845%]，二项检验 p=0.0108 → **可宣称 <1%** |
| 当前样本量能证到的最严格上界 | **<0.66%**（受较小一侧 451 限制） |
| 平均拦截时间（单条，对外口径） | **208.6 ms**，95% CI [207.9, 209.3]，n=33，p95 212 ms |
| 并发批（±2000 ms） | 均值 319.8 ms、p95 **435 ms**，n=836；ADR 0008 后已不再是瓶颈 |
| 取消成功率 | 100%（452/452），Wilson [99.157%, 100%] |
| 重复处理率 | 0%（0/903），Wilson [0, 0.424%] |

三个结论与对应的统计事实：

1. **不会漏**：452 条应拦样本 0 次漏，95% 上界 0.843%。要证 <0.5% 需每侧 ≈600 条。
2. **不会误拦**：451 条应留样本 0 次误拦，95% 上界 0.845%。
3. **平均拦截时间 208.6 ms**：批量 40 条/组时 p95 435 ms。两者都可测、可复算。

方法学要点（否则数字会被过度解读）：

- 0 个错误 ≠ 不会出错，只能给上界；上界随样本量收紧，`3/n` 是最容易记的形态。
- 用 Wilson 区间而非正态近似：极端比例下正态近似会越界。
- 用单侧二项检验而非双侧：要证的是"低于阈值"，不是"不等于阈值"。
- OBSERVED 场景（ongoing/progress 被系统拒绝）不进判定质量，否则会凭空制造漏拦。
- ground truth 由采样脚本按"渠道 + 关键词"独立推导，与规则引擎解耦——能发现实现缺陷，
  发现不了"规则本身写错了"。

## 时延拆解（实测，2026-10-18）

"平均拦截 310 ms"这个数字被追问过是否可优化，所以做了一次**插桩实测**：在
`onNotificationPosted` 回调处与工作线程开始处各取一次时间戳，把端到端时延拆成三段。
插桩代码已回滚，数据保存在 `docs/verification/reports/diagnostics/`。

同一台模拟器、同一套规则、单条节奏（每轮 1 条），24 条样本：

| 段 | 含义 | 拦截路径 | 保留路径 |
|---|---|---|---|
| dispatch | `sbn.postTime` → 我们收到回调 | ~210 ms | ~205 ms |
| snapshot + 队列 | 建快照 + 单线程队列等待（空闲时≈0） | ~0.5 ms | ~0.5 ms |
| process | 判定 + 取消 + 校验 + 落盘 | ~378 ms | ~173 ms |

对外的 `latencyMs`（`entry.timestamp - postTime`，其中 `timestamp` 在取消与校验之后取）
只覆盖前三段的一部分，实测等于：

| 构成 | 实测 | 占 466 ms | 性质 |
|---|---|---|---|
| 系统分发（post → 回调） | ~210 ms | 45% | **不可消除**，由 system_server 调度决定 |
| 取消后校验 `Thread.sleep(250)` | 250 ms | 54% | **完全可消除**，是自设常量 |
| 规则判定 + `cancelNotification` IPC | ~7 ms | 1% | 基本不可压缩 |

证据不是估算：同一次运行里，拦截路径 466.7 ms（n=25）、保留路径 212.9 ms（n=40），
**差值 253.8 ms 与写死的 250 ms 吻合到 4 ms**。两条路径唯一的差别就是"取消 + 校验"。

另外一段不计入 `latencyMs` 但会阻塞工作线程：**历史文件写入 ~115 ms/条**。
批量场景 p95 达 9.6 s 主要是它和 250 ms 等待在单线程队列里叠加的结果
（40 条 × ~275 ms/条）。

### 优化后复测（ADR 0008 已实施）

取消确认改为 `onNotificationRemoved` 回调驱动，历史落盘移到独立 IO 线程
（`AsyncHistorySink`）。同一台模拟器、同一套规则复测：

| 指标 | 优化前 | 优化后 | 变化 |
|---|---|---|---|
| 单条 · 拦截 | 466.7 ms | **208.6 ms**（n=33，95% CI [207.9, 209.3]） | **-55%** |
| 单条 · 保留 | 212.9 ms | 208.8 ms（n=34） | — |
| 批量 800 条均值 | 5219 ms | **319.8 ms** | **-94%** |
| 批量 p95 | 9663 ms | **435 ms** | **-95%** |
| 批量 p99 | 10552 ms | **481 ms** | **-95%** |
| 取消成功率 | 100% | 100%（452/452） | 不变 |
| 判定质量 | 漏 0/451 · 误 0/452 | 漏 0/452 · 误 0/451 | 不变 |

拦截路径（208.6 ms）与保留路径（208.8 ms）现在**统计上不可区分**，
说明"取消通知"本身几乎不耗时，剩下的 208 ms 全是系统分发，属于平台下限。

回归确认：`observe-ongoing` / `observe-progress` 仍在 ~1.5 s 后正确记为 `rejected`，
`observe-noclear` 仍为 `success`；全量 e2e 复测 PASS 11 / FAIL 0 / OBSERVED 8，与优化前一致。

## 待补（真机阶段）

| 项 | 说明 |
|---|---|
| ongoing / 媒体 / 系统级通知取消 | 需要能发出此类通知的应用；记录是否 `cancelStatus=rejected` |
| 取消闪现时延 | 录屏或用 `screenrecord` 逐帧确认 |
| 更大样本的界 | 每侧 ≥600 条可把上界压到 <0.5%；本轮为 451/452 条（<0.66%） |
| OEM 保活 | 小米 / 华为 / OPPO / vivo 自启动白名单差异 |
| 通知分组与更新 | 同 key 二次 post、group summary 行为 |
| 历史 1000 条轮转 | 批量造 1001 条后检查文件行数与首条时间 |
