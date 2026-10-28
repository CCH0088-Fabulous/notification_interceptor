# 生成器契约（拦截器 ↔ 通知生成器）

两人分工时，生成器与拦截器代码各自独立，但共享三条契约。**任何一条改动都必须在同一次提交里同步关联方**，否则 e2e 会假 PASS 或全线误判。

## 1. 包名（定死，不改）

```
dev.poc.notifgen
```

引用处：`tool/e2e.ps1`（`$Generator`）、`assets/presets/generator_triage.json`（`packages`）、`lib/.../settings_page.dart`（文案）。

## 2. tag 格式（定死，不改）

```
gen_<categoryId>_<seq>
```

例：`gen_promo_42`。定义在 `GeneratorTags.kt`（`PREFIX = "gen_"`）。

> e2e 靠 `gen_*` 前缀过滤系统自动分组的聚合通知（tag 形如 `0|pkg|g:Aggregate_...`）。改格式会让拦截器 E2E 误判，且错误会显示成"拦截器不工作"。

## 3. ground truth 单一来源：`Category.keep`

生成器类别用 `NoticeCorpus.kt` 的 `Category.keep: Boolean` 声明"本类应否保留"。

- 这是 e2e 判定期望值的**唯一来源**（读 `GEN|post` 日志的 `keep/drop` 字段）。
- 测试脚本**不再**按渠道/关键词推导，故"规则配置写错"与"引擎实现写错"都会被暴露。

## 渠道 id 契约

`Category` 第二列 `channelId` 与 `generator_triage.json` 白名单必须一字不差；响铃模式加 `_loud` 后缀（`gen_promo` → `gen_promo_loud`）。

## 生成器加新类别的检查清单

1. `NoticeCorpus.kt`：新 `Category(...)` 的 `keep` 值
2. `assets/presets/generator_triage.json`：白名单要不要加该 `channelId`
3. `NoticeCorpusTest.kt`：补断言（keep / drop 覆盖）

## 边界约定

- **`tool/e2e.ps1` 由拦截器负责人维护**，生成器负责人只读，要改先提给拦截器负责人。
- 生成器可独立自测：`gradlew :generator:testDebugUnitTest :generator:assembleDebug`，无需装拦截器。
