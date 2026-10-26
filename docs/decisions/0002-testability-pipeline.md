# ADR 0002：把判定流水线抽出 Android，副作用靠注入

- 状态：已采纳
- 日期：2026-10-17

## 背景

最初 `NotificationInterceptorService` 自己完成"取快照 → 查规则 → 取消 → 写历史"
的全部动作。后果是这段最需要测试的业务逻辑只能靠真机/模拟器验证：一条用例要等
装包、授权、造通知、读日志，反馈周期以分钟计，且无法覆盖异常分支
（取消抛异常、校验被拒、落库失败）。

## 决策

把 **判定 → 取消 → 校验 → 落盘** 抽成纯 JVM 的 `domain/NotificationProcessor`，
所有与 Android 的接触点改成函数式接口注入：

| 接口 | 职责 | 生产实现 | 测试替身 |
|---|---|---|---|
| `RuleEvaluator` | 快照 → 决策 | `RuleEngine` | 直接复用真实引擎 |
| `NotificationCanceller` | 按 key 取消 | `ServiceCanceller` | 记录调用并返回布尔 |
| `CancelVerifier` | 取消后校验 | `DelayedCancelVerifier` | 返回预设状态 |
| `HistorySink` | 落库 | `HistoryRepository` | 内存列表 |
| `TimeSource` / `IdFactory` | 时间与 ID | 系统实现 | 固定值 |

`NotificationInterceptorService` 只保留：生命周期回调、快照提取、自身包名过滤、
去重、线程投递、事件下发。

## 结果

- `NotificationProcessorTest` 9 项覆盖命中/放行/取消失败/校验拒绝/落库异常/时间与 ID 注入。
- 服务类瘦身到 154 行（只留 Android 接线），判定流水线 79 行可纯 JVM 测试。
- 端到端场景从"验证业务逻辑"退化为"验证 Android 接线"，失败定位明显更快。

## 代价

- 多了一层数据传递（`ProcessedNotification`），阅读时需要在两个文件间跳一次。
- 接口数量增加 5 个；若后续有第二种消费者（如批量重放），收益才能完全兑现。

## 相关

- [structure.md](../../structure.md) 第 8 节
- [ADR 0003](0003-e2e-probe-app.md)
