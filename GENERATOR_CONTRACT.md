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

横幅提醒是默认关闭的可选功能，对所有类别使用独立的 `_banner` 渠道（例如 `gen_chat_banner`），重要度为 `IMPORTANCE_HIGH`。
开启横幅时优先使用该渠道，不再叠加 `_loud`；关闭后返回原有渠道。包名、tag、类别 id、`keep` 和 `GEN|post` 判定格式保持不变。
预设的六类保留渠道必须同时包含对应 `_banner` id；已导入旧版预设的设备需同步这六个渠道项，否则聊天等横幅通知可能被兜底规则取消。

开启横幅后，所有子通知加入固定应用组 `dev.poc.notifgen.banner`，子通知与真实汇总均使用 `GROUP_ALERT_CHILDREN`：汇总安静，具体通知按各自渠道请求提醒。
汇总使用专用低重要度渠道 `gen_banner_summary`、tag `banner_summary`、id `-1`，不是新类别，不写 `GEN|post`，不计入 `VERIFY` 或 E2E 样本数量。
**旧设备还必须把 `gen_banner_summary` 加入生成器包限定的放行规则**（最新预设放在 keep-chat 规则），否则取消汇总可能连带取消已放行的子通知；连同六类 `_banner` 共七个兼容渠道项。
汇总根据当前存活子通知原位更新数量与最新六条内容；用户划掉或拦截取消后重新对账，空组才取消汇总，不重发被移除的子通知。
对账在应用进程存活时执行，页面再次打开后根据系统活动通知恢复；`CLEAR` 先停止仿真更新及汇总对账再清除通知。横幅仍受系统设置、勿扰和频率限制。

## 生成器加新类别的检查清单

1. `NoticeCorpus.kt`：新 `Category(...)` 的 `keep` 值
2. `assets/presets/generator_triage.json`：白名单要不要加该 `channelId`
3. `NoticeCorpusTest.kt`：补断言（keep / drop 覆盖）

## 边界约定

- **`tool/e2e.ps1` 由拦截器负责人维护**，生成器负责人只读，要改先提给拦截器负责人。
- 生成器可独立自测：`gradlew :generator:testDebugUnitTest :generator:assembleDebug`，无需装拦截器。

## 界面仿真与自动验收

- 界面直接多选类别，仅在选中类别中按现有 `weight` 归一化随机生成；空选时停止发送，不改变现有类别 id、渠道或 `keep`。
- 界面仅通过底部“发送”启动任务，上方配置单条、定量或持续发送。每次任务快照保存所选类别、间隔和提醒开关，三种发送方式共用 `Generator.post`；停止或更改配置后旧回调不得继续投递。
- 界面仿真模式允许同会话合并、多阶段物流状态更新，均沿用 `gen_<categoryId>_<seq>` 格式。
- 现有 `POST` 广播默认关闭仿真，继续保持独立通知与原 E2E 计数方式；手工仿真可显式传 `--ez realistic true`。
- `POST` 广播默认关闭横幅提醒；手工验证可传 `--ez headsUp true`，不读取界面的开关状态。
- 首次投递使用 `GEN|post`，自动状态更新使用 `GEN|update`，避免将通知更新当作新的独立样本。
- `CLEAR` 必须清除待执行的仿真更新，通知被取消后也不得通过进度更新重新出现。
