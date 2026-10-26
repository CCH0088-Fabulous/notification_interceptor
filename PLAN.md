# 通知拦截器技术验证 — 实施计划

| 项目 | 内容 |
|---|---|
| 文档版本 | v1.0 |
| 编写日期 | 2026-10-17 |
| 项目代号 | Notification Interceptor PoC |
| 包名 | `dev.poc.notifinterceptor` |
| 技术栈 | Flutter 3.32.5 / Dart 3.8.1 + Kotlin（Android 原生服务） |
| 目标平台 | Android 8.0（API 26）– Android 16（API 36），仅手机 |
| 状态 | 规划完成，待开工 |

---

## 1. 项目定位

一个**技术验证（PoC）软件**：作为第三方 App，通过 Android `NotificationListenerService` 监听、读取、取消（即"拦截"）其他 App 发出的通知，并验证基于规则的高级过滤能力是否可行、边界在哪里。

### 1.1 范围内（In Scope）

- 通知使用权（Notification Access）的申请引导、授权状态检测、服务重连。
- 读取通知**全字段**：包名、应用名、key/id、时间、标题、正文、大文本、多行文本、子文本、ticker、category、channel、group、ongoing、clearable、priority、progress、原始 extras。
- 实时展示通知流（发出 / 更新 / 移除）。
- 规则引擎：包名、关键词、正则、渠道、ongoing/clearable、静默时段，多规则按序首条命中。
- 动作：`allow`（放行）、`intercept`（取消）、`log_only`（只记录不拦截）。
- 命中后调用 `cancelNotification(key)` 实际取消通知。
- 本地历史（环形保留）+ 检索 + 导出。
- 规则试运行（拿一条历史/现有通知预判命中结果）。
- 边界实测：取消时延、闪现、ongoing/敏感通知能否取消、界面销毁后是否仍生效。

### 1.2 范围外（Out of Scope）

- 上架 Google Play（通知使用权属于敏感能力，PoC 定位为侧载）。
- 多设备同步、云端、账号体系。
- 修改通知内容、伪造通知、代理回复（`RemoteInput` 回复另议）。
- iOS / 桌面端。
- 免 ROOT 之外的系统级加固绕过。
- 通知到达前的"预拦截"（Android 不提供此能力，见 1.3）。

### 1.3 能力边界（必须写进 README，避免误期待）

1. **"拦截"= 通知已发出后被取消**。系统会先投递、再回调监听器，因此可能存在短暂闪现，且**首次响铃/震动/亮屏无法阻止**。
2. Dart 层无法继承 `NotificationListenerService`，该服务必须是 Kotlin 类。
3. 部分 ROM / 新版本系统对 `ongoing`、系统级、部分敏感类通知的取消可能无效（静默失败）。
4. 用户手动撤销通知使用权后，规则全部失效；App 无法自我恢复权限。
5. 工作资料（work profile）中的通知对监听器不可见。

---

## 2. 可行性结论

**可行，但必须采用混合架构。**

- `NotificationListenerService` 是 Android Framework 组件，只能在 Java/Kotlin 中继承。Dart 没有对应绑定。
- 因此：**Kotlin 负责服务、判定、取消、持久化；Dart 只负责 UI 与配置**。
- 规则引擎放在原生侧，原因：Flutter Activity 被划掉后 Dart 引擎可能已销毁，但系统仍会绑定监听服务；判定逻辑必须在没有 Flutter 的情况下自足。
- Dart 侧通过 `evaluate` 复用同一份引擎做试运行，**不允许在 Dart 重写一套匹配逻辑**，否则双份实现必然漂移。

---

## 3. 架构设计

```mermaid
flowchart LR
  A[第三方 App] --> B[Android NotificationManager]
  B --> C[NotificationListenerService<br/>Kotlin]
  C --> D[NotificationSnapshotFactory<br/>字段提取]
  D --> E[RuleEngine<br/>首条命中判定]
  E -->|intercept| F[cancelNotification key]
  E -->|allow / log_only| G[HistoryRepository<br/>JSONL 环形保留]
  F --> G
  G --> H[InterceptorBridge<br/>MethodChannel + EventChannel]
  H --> I[Flutter UI<br/>实时流 / 规则 / 历史]
  I -->|saveRules / evaluate| H
```

### 3.1 线程模型

| 环节 | 线程 | 说明 |
|---|---|---|
| `onNotificationPosted` 回调 | 主线程 | 只做快照提取，禁止 IO 与重计算 |
| 规则判定 + 取消 | 单线程 `Executor` | 串行保证规则读取一致性 |
| 历史落盘 | 同一 Executor（IO 部分） | 追加写，超限轮转 |
| `EventChannel` 推送 | 主线程 `Handler` | SDK 要求 sink 在主线程调用 |

### 3.2 服务声明

```xml
<service
    android:name=".listener.NotificationInterceptorService"
    android:exported="false"
    android:label="@string/service_name"
    android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE">
    <intent-filter>
        <action android:name="android.service.notification.NotificationListenerService" />
    </intent-filter>
</service>
```

要点：

- `exported=false`（Android 12+ 必须显式声明）。
- 不声明 `default_filter_types` / `disabled_filter_types`，先看全量，由规则过滤。
- `onListenerConnected()` 后用 `getActiveNotifications()` 补一次存量快照。
- `onListenerDisconnected()` 后按退避策略 `requestRebind()`。
- **自身包名直接放行**，防止自通知形成循环。
- 相同 `key` 的重复 post 视为"更新"，用于去重与统计。

### 3.3 通知快照模型（原生 JSON，Dart 侧镜像）

```json
{
  "key": "0|dev.poc.demo|1|null|10001",
  "id": 1,
  "packageName": "dev.poc.demo",
  "appLabel": "Demo",
  "postTime": 1760000000000,
  "title": "标题",
  "text": "正文",
  "bigText": "长文本",
  "textLines": ["行1", "行2"],
  "subText": null,
  "tickerText": null,
  "category": "msg",
  "channelId": "marketing",
  "channelName": "营销",
  "groupKey": null,
  "isGroupSummary": false,
  "isOngoing": false,
  "isClearable": true,
  "priority": 0,
  "progress": -1,
  "extras": {}
}
```

`extras` 仅用于调试页展示，**不参与规则匹配**（类型不稳定）。

### 3.4 规则模型

```json
{
  "schemaVersion": 1,
  "globalEnabled": true,
  "defaultAction": "allow",
  "rules": [
    {
      "id": "r1",
      "name": "屏蔽电商营销",
      "enabled": true,
      "action": "intercept",
      "match": {
        "mode": "all",
        "packages": ["com.example.shop"],
        "keywordsAny": ["秒杀", "红包"],
        "titleRegex": "优惠|限时",
        "channelIds": ["marketing"],
        "isOngoing": false,
        "isClearable": true,
        "quietHours": { "from": "22:00", "to": "08:00", "days": [1, 2, 3, 4, 5, 6, 7] }
      }
    }
  ]
}
```

匹配语义（**必须由单测固化**）：

1. 规则按数组顺序求值，**首个命中即返回**，后续规则不再求值。
2. `mode = all`：各条件组之间 AND；组内数组元素之间 OR。
3. 未填写（缺省/空数组/null）的条件组不参与匹配。
4. `isOngoing` / `isClearable` 仅在字段非 null 时参与。
5. `quietHours` 支持跨天（`22:00 → 08:00`），`days` 使用 `1=周一 … 7=周日`，以**区间起始日**判定。
6. 正则非法 → 该规则标记 `invalid`，跳过且不阻断后续规则；UI 显示错误。
7. `globalEnabled=false` 或服务未连接 → 一律 `allow`。
8. 自身包名 → 一律 `allow`，且不写历史。

### 3.5 通道 API（单文件定义，禁止散落字符串）

| 通道 | 类型 | 方法 / 事件 | 说明 |
|---|---|---|---|
| `dev.poc.notifinterceptor/bridge` | MethodChannel | `getStatus` | 权限是否授予、服务是否连接、系统版本 |
| | | `openAccessSettings` | 跳转系统"通知使用权"设置页 |
| | | `requestRebind` | 手动重连服务 |
| | | `getRules` / `saveRules` | 规则读写（整包覆盖，原子写） |
| | | `evaluateSample` | 传入快照或历史 id，返回命中规则与动作 |
| | | `getHistory` | 分页 + 按包名/动作/时间过滤 |
| | | `clearHistory` | 清空 |
| | | `getActiveNotifications` | 当前活动通知 |
| | | `cancel` | 手动取消指定 key |
| | | `getSeenPackages` | 出现过的包名（避免申请 `QUERY_ALL_PACKAGES`） |
| | | `exportHistory` | 返回 JSON 字符串，由 Dart 写文件/分享 |
| `dev.poc.notifinterceptor/events` | EventChannel | `posted` / `removed` / `statusChanged` | `{type, record, decision, matchedRuleId}` |

约定：

- 所有方法返回 `Map<String, dynamic>`；失败返回 `errorCode` + `message`，Dart 侧映射为类型化异常。
- 通道名、方法名集中定义在 `core/channel/interceptor_channel.dart`，Dart 业务代码不得出现裸字符串。
- `EventChannel` 断流后需在 Dart 侧重订阅，原生侧需容错 sink 为空。

### 3.6 持久化

| 数据 | 位置 | 策略 |
|---|---|---|
| 规则与设置 | `filesDir/rules.json` | 先写临时文件再 rename，保证原子性；损坏时回退默认值并保留 `.bak` |
| 历史 | `filesDir/history.jsonl` | 追加写；启动时载入内存环形缓冲；超过 **1000** 条截断轮转 |
| 导出 | 用户选择目录 | 由 Dart 侧写出，原生只提供 JSON 字符串 |

不使用数据库：PoC 数据量小，JSONL 便于 adb 抓取比对，减少依赖与构建风险。

---

## 4. 里程碑

| 阶段 | 交付内容 | 验收标准 |
|---|---|---|
| **M0 骨架** | `flutter create --platforms=android --org dev.poc`；`gradle.properties` 固定 `org.gradle.java.home=D:\\Android_Studio\\jbr`；`minSdk 26`、`compileSdk/targetSdk 35`；`.gitignore`、`README.md` 骨架 | `flutter build apk --debug` 成功；APK 可安装启动 |
| **M1 监听打通** | 服务 + Manifest + 授权检测/跳转 + EventChannel + 实时流页 | A1：授权后自动连接，UI 实时显示外部通知全字段；撤销授权后状态正确回落 |
| **M2 拦截打通** | 命中 → `cancelNotification`；自身包名排除；手动取消；历史记录 | A2、A7：目标通知消失并落库；无自触发循环、无 ANR |
| **M3 规则引擎** | 原生 `RuleEngine` + 规则编辑页 + 试运行 + JUnit 单测 | A3、A4：关闭界面后仍生效；首条命中语义与非法正则容错全部通过 |
| **M4 高级过滤** | 正则/渠道/ongoing/静默时段/去重/统计直方图/规则导入导出 | 组合规则实测通过；导入导出可往返一致 |
| **M5 验证与文档** | 单测补全、模拟器脚本、验收清单、README（含能力边界） | A1–A7 全绿；文档可复现整套验证 |
| **M6（可选）** | 前台服务保活、快捷开关、通知摘要仪表盘 | 按需，不阻塞主验收 |

> 每个里程碑结束时必须可构建、可运行、可演示；不留"半截代码"。

---

## 5. 验证方案

### 5.1 验收项（A 系列，供 structure.md 与测试用例引用）

| 编号 | 验收项 |
|---|---|
| A1 | 授权后服务连接，实时流显示外部通知全字段 |
| A2 | 规则命中后目标通知被取消，并在历史中标记 `intercept` |
| A3 | Flutter Activity 销毁（返回键退出）后规则仍然生效 |
| A4 | 规则首条命中语义、非法正则容错、静默时段跨天判定正确 |
| A5 | 重启设备后规则与历史保留 |
| A6 | API 36 模拟器/真机上 ongoing、系统级、敏感通知的取消结果被逐条记录 |
| A7 | 无自触发循环、无 ANR/闪退，历史 1000 条轮转正常 |

### 5.2 分层测试

1. **Kotlin JVM 单测**（`android/app/src/test`，无 Android 依赖）：匹配优先级、空条件、非法正则、静默时段跨界、自身包名、JSON 往返、历史轮转。
2. **Dart 单测**（`test/unit`）：模型解析容错、repository 对通道异常的映射、控制器状态机。
3. **Widget 测试**（`test/widget`）：规则编辑校验、空态/错误态渲染。
4. **集成验证**（`integration_test` + adb 脚本）：授权 → 造通知 → 命中 → 取消 → 历史核对。
5. **统计检验**（`tool/stats.ps1`）：在批量采样之上给出漏拦率/误拦率的置信区间与
   单侧二项检验，以及分档的时延均值 ± 95% CI。回答"会不会漏/会不会误拦/平均多久"，
   而不是"跑一遍没报错"。协议见 [ADR 0007](docs/decisions/0007-statistical-testing.md)。

### 5.3 端到端脚本（模拟器）

```powershell
adb shell cmd notification allow_listener dev.poc.notifinterceptor/.listener.NotificationInterceptorService
adb shell cmd notification post -t "秒杀提醒" tag_demo "限时优惠"
adb shell dumpsys notification --noredact | Select-String "tag_demo"
```

> API 36 Play 镜像上 `cmd notification allow_listener` 与 `post` 是否可用需在 M1 首日实测；不可用则退化为手工点击授权 + 用第二台模拟器/演示 App 造通知。

### 5.4 手工清单（真机阶段）

- 锁屏/亮屏、免打扰模式下的行为差异。
- 通知更新（同 key 二次 post）、分组通知与 group summary。
- 撤销授权、强制停止、清理后台后的恢复表现。
- 各 OEM（小米/华为/OPPO/vivo）自启动白名单与保活差异。

---

## 6. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| 取消存在闪现、无法阻止首次响铃 | 体验与预期不符 | 文档明确能力边界；实测记录时延；后续评估"静音通道 + 拦截"组合 |
| 部分 ROM/版本取消失败（静默） | 规则看似无效 | 取消后延迟校验 `getActiveNotifications()` 是否仍存在，失败则标记 `cancel_rejected` 并展示 |
| OEM 后台限制杀服务 | 规则间歇失效 | 引导自启动白名单；M6 可加前台服务 |
| 正则回溯引发卡顿 | 主线程阻塞风险 | 限制模式长度（≤200）、编译结果缓存、判定放后台线程、单条判定超时保护 |
| 通知含敏感信息 | 隐私风险 | 全部本地存储、不联网、导出需用户显式操作；提供一键清空 |
| 范围蔓延到"上架可用产品" | 工期失控 | 严格按 1.2 非目标执行；M6 之后另立计划 |
| 首次构建下载 Kotlin/AGP | 受代理与网络影响 | 复用已缓存 Gradle 8.12 + AGP 8.7.3；Kotlin 固定 2.0.21（已缓存）；不配置 Gradle 代理 |

---

## 7. 本机环境基线（2026-10-17 勘察）

| 项目 | 实测值 |
|---|---|
| Flutter / Dart | 3.32.5 stable / 3.8.1 |
| Android SDK | platforms 33/34/35；build-tools 30.0.3/34.0.0/35.0.1/36.0.0；platform-tools 36 |
| NDK / CMake | 23.1 / 26.3 / 27.0；CMake 3.22.1（本项目不使用） |
| Gradle | 8.12 已完整解压（含 229 MB zip） |
| AGP 缓存 | 7.3.1 / 8.0.0 / 8.5.0 / 8.7.3 / 8.12.1 |
| Kotlin 插件缓存 | 1.8.0 / 1.9.23 / 2.0.21 / 2.2.10（**无 2.1.0**） |
| JDK | `JAVA_HOME=D:\Java` 为 JDK 8（不可用于 AGP 8.x）；可用 `D:\Android_Studio\jbr`（JDK 21） |
| 模拟器 | `Medium_Phone`，Android 36（google_apis_playstore，x86_64，2 GB RAM），已有 quick-boot 快照 |
| 加速 | WHPX 可用 |
| 主机 | i7-14700HX（20C/28T）、31.7 GB RAM、F 盘 345 GB 可用 |
| 网络 | 代理 `127.0.0.1:7890` 在线；pub.dev 可达 |
| 设备 | 当前 `adb devices` 为空 |
| 参考工程 | `D:\Dart_Application\time_manager`（Gradle 8.12 + AGP 8.7.3 + JBR，2026-09-18 产出 67.9 MB release APK） |

结论：无需安装新工具链；仅需在 M0 固化 JDK 路径与 SDK 版本。

---

## 8. 待定决策

| 编号 | 议题 | 当前倾向 |
|---|---|---|
| D1 | 状态管理方案 | `ChangeNotifier` + 构造注入，零第三方依赖；规模的再引入 Riverpod |
| D2 | 规则存储格式 | JSON（单文件，原子写）；规则数量 > 200 时再考虑 SQLite |
| D3 | 是否引入通知类第三方库 | 不引入，直接写 Kotlin，避免依赖与新版本兼容风险 |
| D4 | 是否支持"通知合并摘要" | M4 先做展示，不做合并判定 |
| D5 | 前台服务保活 | M6 可选，PoC 阶段仅文档说明 |

---

## 9. 与后续文档的关系

- 目录结构与分层依赖规则见 [`structure.md`](./structure.md)。
- 与代码一一对应的验收项见第 5.1 节；测试用例命名需引用 A 编号。
- 每次架构性变更需在 `docs/decisions/` 新增 ADR，并回写本文件版本与变更记录。

### 变更记录

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-10-17 | v1.0 | 初版：可行性结论、架构、M0–M5、验收项与环境基线 |
| 2026-10-17 | v1.1 | 实现完成：M0–M4 交付，补充实施状态与实测结论（见第 10 节） |

---

## 10. 实施状态（2026-10-17）

| 里程碑 | 状态 | 说明 |
|---|---|---|
| M0 骨架 | 完成 | `flutter create` + 固定 JBR、`minSdk 26`、`compileSdk/targetSdk 35`；debug APK 构建通过 |
| M1 监听打通 | 完成 | 服务被系统自动绑定；快照含全部字段与 extras；实时流与历史均验证 |
| M2 拦截打通 | 完成 | 规则命中后 `cancelStatus=success`，通知从通知栏消失；自身包名放行 |
| M3 规则引擎 | 完成 | 原生引擎 + 40 个 JVM 测试（含随机化与去重）；编辑器、试运行、静态校验可用 |
| M4 高级过滤 | 完成 | 关键词/正则/渠道/ongoing/clearable/静默时段/首条命中/导入导出（剪贴板 JSON） |
| M5 验证文档 | 完成 | `flutter analyze` 无问题、52 个 Dart 测试、40 个 Kotlin 测试、分层检查 5 条通过；记录见 `docs/verification/checklist.md` |
| M6 前台服务保活 | 未开始 | 按计划可选，PoC 阶段不阻塞 |
| M7 通知生成器 | 完成 | 独立应用 `dev.poc.notifgen`：13 类自然语言语料、随机弹出、手动/自动/adb 三种驱动；配合 4 条预设规则演示「只留需要的通知」 |
| M8 量化指标 | 完成 | e2e 产出 JSON，`tool/metrics.ps1` 复算 precision/recall、时延分位、取消成功率、重复率、响铃观测值，并支持 `-Gate` 阈值回归 |
| M9 响铃测量 | 完成 | `alert-sound` 受控协议（清空托盘 + 静默 8 s + 对照组）：6 条用例量化"拦截是否漏响"；生成器新增响铃模式（`--ez loud true`） |
| M10 显著性检验 | 完成 | `-Bulk` 采样 + `tool/stats.ps1`：903 条样本，漏拦 0/452、误拦 0/451，双侧均可宣称 <1%；单条拦截时延 208.6 ms（95% CI [207.9, 209.3]）。见 10.3 节 |
| M11 时延优化 | 完成 | 取消确认改回调驱动 + 落盘异步（ADR 0008）：单条拦截 466.7→**208.6 ms**，批量 p95 9663→**435 ms**，判定质量与 e2e 无退化 |
| T 测试架构 | 完成 | 纯 JVM 流水线 + 探针 App + 生成器 + `tool/e2e.ps1`；19 场景全绿（PASS 11 / OBSERVED 8），见第 10.1 节 |

验收：A1–A7 全部有实测结论（A6 在 API 36 上实测为 `rejected`，即 ongoing 与 progress
通知无法被第三方取消；no-clear 可取消）。细节见 `docs/verification/checklist.md`。

### 10.1 测试架构（2026-10-17 追加）

分五层，越靠下层越贵，能用上层断言的不下推：

| 层 | 手段 | 数量 | 命令 |
|---|---|---|---|
| L1 纯 JVM | 规则引擎 / 处理流水线 / 去重 / 契约固件 / 随机化 / 语料与 tag | 46 | `gradlew :app:testDebugUnitTest :generator:testDebugUnitTest` |
| L2 Dart | 控制器 / 模型 / 页面 / 预设契约 | 57 | `flutter test` |
| L3 结构 | 分层依赖 5 条规则 | 5 | `dart run tool/check_layer_imports.dart` |
| L4 端到端 | 探针 App + 生成器 + 真实通知形态 | 19 场景 | `tool\e2e.ps1` |
| L5 真机 | 厂商 ROM 差异 | 手工 | `docs/verification/checklist.md` |

"模拟真实情况"靠三个改动：

1. **把业务逻辑从 Android 里拔出来**：`domain/NotificationProcessor` 注入
   canceller / verifier / historySink / timeSource / idFactory，可测异常分支。
2. **用真实通知形态而不是 `cmd notification post`**：探针 App 走真实
   `NotificationManager`，能造 ongoing、no-clear、分组、MessagingStyle、进度、批量。
3. **把"环境就绪"当成断言的一部分**：脚本先预热并验证"投递→判定→入库"通畅，
   再跑场景；时间窗用设备时钟；记录型场景（ongoing 能否取消）标 OBSERVED 不算失败。
4. **用真实文案压测规则**：`dev.poc.notifgen` 生成器内置 13 类自然语言语料，
   配合 `assets/presets/generator_triage.json` 验证「白名单放行 + 兜底拦截」
   能否做到"只有需要的通知留在通知栏"。
5. **把结果变成可复算的数据**：e2e 输出 JSON，`tool/metrics.ps1` 复算
   precision/recall、时延分位、取消成功率、重复率与响铃观测值，并提供 `-Gate`
   阈值回归。当前基线：precision/recall 100%、p50 1759 ms、p95 5178 ms、
   取消成功率 100%、重复率 0%。
6. **把"跑一遍没报错"换成统计结论**：`-Bulk` 采样只收数据不断言，
   `tool/stats.ps1` 在其上做 Wilson 区间 + 单侧二项检验。
   0 个错误不等于不会出错——只报"100% 正确"是误导，必须同时给上界。

### 10.2 响铃结论（实测，受控协议见 ADR 0006）

| 用例 | 入队 | 打扰 | 被拦截 | 结论 |
|---|---|---|---|---|
| 放行 + DEFAULT（对照组） | 1 | 1 | 0 | 仪器有效 |
| 拦截 + DEFAULT | 1 | **1** | 1 | 取消成功也会响 |
| 拦截 + LOW 渠道 | 1 | 0 | 1 | 低重要度天然不响 |
| 拦截 + 3×8 s 间隔 | 3 | 2 | 3 | 仍响，且系统再抑制 1 条 |
| 拦截 + 5 条连发 | 5 | 1 | 5 | 其余被 2048/32768 抑制 |
| 生成器噪声 + 响铃模式 | 3 | 2 | 3 | 真实语料同样漏响 |

- 响铃发生在 post 瞬间，`cancelNotification` 只能移除通知，**不能阻止首次响铃**：
  实测 `cancelStatus=success` 与 EventLog 的 `aboveThreshold=1` 同时成立。
- **时序证据（2026-10-18 复测）**：同一 key 的 `alert→cancel` 只差 4–9 ms。
  原始日志显示系统在 +203 ms 播放提示音，在 +210 ms 才完成我们的取消。
  ADR 0008 把取消从 466 ms 压到 208 ms 后，6 个响铃用例结果**完全不变**——
  证明这是平台时序约束，不是取消速度问题。
- `IMPORTANCE_LOW` 渠道从不响铃；同应用连发会被系统抑制（flag `2048`/`32768`）。
- 因此"留下 = 会响"、"被拦 = 也响过一次"；真要静音只能改渠道重要度或开勿扰。
- 生成器默认把噪声放 LOW 渠道，会让"拦截 = 静音"成为假象，故提供**响铃模式**。

### 10.3 显著性检验（2026-10-17 追加，协议见 ADR 0007）

单轮 e2e 只有几十条样本，0 错误时真实错误率上界仍在 10% 量级。因此把**采样**与
**断言**拆开：`tool/e2e.ps1 -Bulk N` 只发通知、只收记录；`tool/stats.ps1` 在其上
做区间估计与假设检验。

样本构成（903 条）：

| 来源 | 命令 | 条数 |
|---|---|---|
| 批量判定样本 | `-Only bulk-triage -Bulk 800` | 800（`uniqueTags=800`） |
| 单条时延样本 | `-Only bulk-triage -Bulk 60 -BulkRound 1` | 60（`uniqueTags=60`） |
| 常规场景 | `tool\e2e.ps1`（19 场景） | 46（含探针 19 条） |

结论：

| 问题 | 答案 | 统计依据 |
|---|---|---|
| 会不会漏掉 | **0/452**，95% 上界 **0.843%**，可宣称 <1% | Wilson 区间 + 单侧二项 p=0.0106 |
| 会不会误拦截 | **0/451**，95% 上界 **0.845%**，可宣称 <1% | Wilson 区间 + 单侧二项 p=0.0108 |
| 平均拦截时间 | 单条 **208.6 ms**（95% CI [207.9, 209.3]，p95 212 ms） | bootstrap 2000 次与正态近似一致 |
| 批量时延 | 800 条均值 319.8 ms、p95 **435 ms** | 单线程队列 + 异步落盘，已非瓶颈 |
| 取消成功率 | 100%（452/452），Wilson [99.16%, 100%] | 只统计 `cancelStatus` 已尝试且非 OBSERVED |
| 重复处理率 | 0%（0/903），Wilson [0, 0.424%] | 按单次运行内 key 去重 |

统计纪律：

- **0 错误 ≠ 不会错**：只能给上界。当前样本量（452/451）能证到的最严格上界是 <0.66%；
  要证 <0.5% 需每侧约 600 条。
- 时延必须分档：把 40 条/轮的批量投递和单条投递混算，会得到假"平均拦截时间"。
- 时延必须拆到"谁引入的"：466.7 ms 里有 250 ms 是自设的校验等待，改成回调驱动后降到 208.6 ms。
- OBSERVED 场景（ongoing/progress 被系统拒绝）不进判定质量，否则凭空制造漏拦。
- ground truth 由采样脚本按"渠道 + 关键词"独立推导，与规则引擎解耦。

### 10.4 时延优化（2026-10-18，见 ADR 0008）

原始流程把"确认取消生效"放在关键路径上：`cancelNotification` → `sleep(250)` → 查
`activeNotifications` → 落盘。插桩实测证明这 250 ms 是自设常量，不是平台限制。
改为 `onNotificationRemoved` 回调驱动 + 独立 IO 线程落盘后：

| 指标 | 优化前 | 优化后 | 变化 |
|---|---|---|---|
| 单条 · 拦截 | 466.7 ms（n=25） | **208.6 ms**（n=33） | -55% |
| 单条 · 保留 | 212.9 ms（n=40） | 208.8 ms（n=34） | — |
| 批量 800 条 p95 | 9663 ms | **435 ms** | -95% |
| 取消成功率 | 100% | 100%（452/452） | 不变 |
| 判定质量 | 漏 0/451 · 误 0/452 | 漏 0/452 · 误 0/451 | 不变 |

拦截与保留两条路径现在统计上不可区分 → "取消通知"本身几乎不耗时，
剩余 208 ms 全部是系统分发（模拟器上 ~210 ms），属于平台下限。
`metrics.ps1` 的 p95 门禁随之从 6000 ms 收紧到 1000 ms。

实施期间对计划的两处修正：

1. 规则缓存增加文件 mtime 校验（外部改写 `rules.json` 即时生效），否则调试与导入需重启进程。
2. `json_cast.dart` 从 `core/channel` 移到 `core/util`，让 domain 层不依赖"通道"概念，符合 L2 分层规则。
