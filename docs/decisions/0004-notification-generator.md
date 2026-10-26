# ADR 0004：通知生成器独立成包，分流规则用「白名单 + 兜底拦截」

- 状态：已采纳
- 日期：2026-10-17

## 背景

需要一个能持续产出"像真实世界"的通知的来源，用来演示与压测规则：

- `adb shell cmd notification post` 只能造 basic 通知，且文案固定，看不出过滤效果；
- 主应用自己发通知不可行——`NotificationInterceptorService` 会放行自身包名
  （防止自触发循环），同包的通知永远不会进入规则判定；
- 现有探针 `dev.poc.probe` 的目标是"系统形态"（ongoing、进度、分组），
  不适合承载大量自然语言语料。

## 决策

1. 新增独立应用 `dev.poc.notifgen`（模块 `android/generator/`）：
   - 13 类语料（私聊、群聊、验证码、银行、物流、日程、促销、营销、资讯、社交、
     游戏、可疑信息、清理提醒），加权随机 + 随机值填充（人名、金额、验证码、取件码）；
   - 每类一个通知渠道 `gen_<category>`，规则用 `channelIds` 就能精确分流；
   - 三种驱动方式：界面按钮、自动模式（2.5 秒一条）、adb 广播（可指定 `seed` 复现）。
2. 分流规则写成**先白名单、后兜底**的四条规则（`assets/presets/generator_triage.json`）：
   1. 渠道 `gen_code/gen_bank/gen_logistics/gen_calendar` → 放行
   2. 关键词 `验证码/入账/取件码/会议` → 放行（内容兜底）
   3. 渠道 `gen_chat/gen_group` → 放行
   4. 该包其余通知 → 拦截
   全部规则都限定 `dev.poc.notifgen`，不影响其他应用。
3. 该 JSON 同时被 UI（`assets/presets/` + `rootBundle`）与 `tool/e2e.ps1`
   （直接 push 到 `files/rules.json`）使用，避免两套规则漂移；
   `generator_preset_test.dart` 校验顺序与覆盖范围。

## 为什么用渠道而不是文案匹配

MessagingStyle 的通知标题会被系统改写成会话名（见 checklist 实测第 6 条），
按标题关键词匹配会漏命中。渠道由发布方自己声明、系统不改写，是最稳的分流维度。
关键词规则保留为"内容兜底"，用来覆盖新增渠道但文案特征已知的情况。

## 结果

- `generator-triage` 场景：24 条随机通知 → 14 条应保留、全部留在通知栏；
  0 条非白名单通知残留；0 条取消失败；8 秒后集合不变（"长久留在通知栏"）。
- 顺带发现：系统自动分组生成的聚合通知会**继承渠道 id**，但 tag 形如
  `0|pkg|g:Aggregate_...`，脚本必须按 tag 前缀过滤，否则会误判成"多处理了几条"。

## 代价

- 多一个 App 与一份预设要维护；语料需要随演示目标演进。
- 预设包含固定包名 `dev.poc.notifgen`，换包名需同步改 JSON 与 Dart 测试常量。

## 相关

- [structure.md](../../structure.md) 第 4 节
- [docs/verification/checklist.md](../verification/checklist.md)
