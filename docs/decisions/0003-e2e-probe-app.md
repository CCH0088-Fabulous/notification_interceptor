# ADR 0003：端到端用探针 App + 脚本，不用 integration_test

- 状态：已采纳
- 日期：2026-10-17

## 背景

需要验证的是"第三方 App 发布通知 → 本应用监听/读取/取消"这条跨进程链路。
可选方案有三种：

1. `flutter integration_test`：能驱动 Flutter UI，但**无法合成系统通知事件**，
   也拿不到 `NotificationListenerService` 的真实回调。
2. `adb shell cmd notification post`：简单，但只能造 basic 通知。
   实测无法生成 ongoing、no-clear、分组、MessagingStyle、进度、批量等形态，
   而这几种恰好是拦截器最容易出问题的地方。
3. 自带一个测试用 APK，用真实 `NotificationManager` 造通知。

## 决策

采用方案 3，并配合 `tool/e2e.ps1` 作为唯一的端到端入口。

- `android/probe/`（`dev.poc.probe`）是独立 Gradle 模块，**不进入主 APK**。
- 通过广播驱动：`dev.poc.probe.POST` / `VERIFY` / `CLEAR`，
  参数 `scenario/tag/title/text/id/count/delay`。
- 日志格式固定：`PROBE|<scenario>|<tag>|<EVENT>|<detail>`，
  `verify` 必定输出一行 `COUNT` 作为"这次探测真的跑完了"的哨兵。
- 脚本负责：装包 → 授权 → 写规则 → 造通知 → 读 `history.jsonl` → 用探针
  `VERIFY` 判定"通知是否仍在通知栏" → 生成 Markdown 报告。

## 结果

- 场景从 7 个扩到 12 个，覆盖 ongoing / no-clear / 静默渠道 / 分组 / MessagingStyle /
  进度 / 批量 / 界面关闭 / 规则热改 / 授权撤销 / 重启。
- 首轮即发现 3 个真实缺陷：重复回调未去重（`processed=20/10`）、
  MessagingStyle 标题被系统改写导致关键词不命中、撤销授权场景判据错误。
- 报告落盘 `docs/verification/reports/e2e-<时间戳>.md`，可与 A1–A7 对照。

## 代价

- 多一个模块要维护；探针的"通知形态"必须跟着被观测行为演进。
- 端到端依赖模拟器/真机环境，机器负载会影响时延断言
  （已通过预热与"就绪探测"缓解，见 structure.md 8.4）。

## 相关

- [structure.md](../../structure.md) 第 8 节
- [docs/verification/checklist.md](../verification/checklist.md)
