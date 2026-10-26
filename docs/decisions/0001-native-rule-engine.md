# ADR 0001：规则引擎放在 Kotlin 原生侧

- 状态：已采纳
- 日期：2026-10-17
- 相关：PLAN.md §2、§3.2；structure.md §4

## 背景

应用需要在 Android 上监听并取消其他应用的通知。`NotificationListenerService`
只能由 Java/Kotlin 类继承，Dart 无法实现该服务。除此之外还有一个容易忽略的问题：
Flutter Activity 被用户划掉后，Dart isolate 可能被销毁，但系统仍会绑定监听服务。

## 决策

1. 监听、快照提取、规则判定、取消、历史落盘全部放在 Kotlin 侧。
2. 规则引擎 `RuleEngine` 位于 `android/.../domain/`，**不依赖任何 `android.*` 类型**，
   从而可以用纯 JVM 单元测试覆盖所有匹配语义。
3. Dart 侧不实现第二套匹配逻辑。规则编辑器的「试运行」通过
   `evaluateSample` 调用同一个原生引擎。
4. 规则与历史的权威数据在原生侧；Dart 仅持有镜像副本用于展示。

## 备选方案

| 方案 | 否决理由 |
|---|---|
| Dart 侧做判定，原生只负责取消 | 界面销毁后规则失效；且双份实现必然漂移 |
| 用 `flutter_notification_listener` 等插件 | 仍需自写 Kotlin 服务；插件抽象不足以暴露 extras 与取消校验 |
| 规则引擎独立成 AAR 模块 | PoC 阶段增加构建复杂度，收益不足 |

## 后果

- 好处：规则在无 Flutter 进程时仍生效；判定逻辑可被 JVM 测试直接覆盖；
  跨语言只有一份契约（JSON），没有第二实现。
- 代价：任何规则能力扩展都要同时改 Kotlin domain 与 Dart UI 模型；
  由 `schemaVersion` 与共享 fixture 测试约束一致性。
- 约束：`domain` 包禁止 `import android.*`，由 `tool/check_layer_imports.dart`（规则 L5）强制。
