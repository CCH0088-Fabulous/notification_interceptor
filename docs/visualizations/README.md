# 批量规则效果可视化

[打开独立报告](batch-comparison.html)。报告使用白底、黑字与灰阶图表；字体、SVG、数据和脚本均内嵌，浏览器直接打开即可离线查看。页面中的筛选仅影响明细表，四张图始终使用同一份完整样本。

应用内入口与回放规则见[批量效果对比说明](../usage/batch-comparison.md)。

## 默认报告的数据来源

当前默认报告使用[模拟器受控演示的应用导出 JSON](data/batch-comparison-controlled.json)，经应用内批量对比后通过 Android 系统文件选择器（SAF）导出，并按原始字节复制保存。演示发送了 56 条受控通知：生成器 36 条、Probe 10 条、Shell 10 条；历史窗口还包含 1 条 Android 屏幕锁建议。源窗口共 61 个处理事件，排除 4 条系统分组汇总后，完整保留 57 个样本。

报告使用导出时区 `GMT` 和原始时间戳。当前与候选分别预计放行 47 → 40 条、预计拦截 6 → 13 条、仅记录 4 → 4 条；动作变化 15 条，其中新增预计拦截 11 条、减少预计拦截 4 条；仅命中来源改变 8 条。历史确认移除 6 条是原有执行参考。上述数字描述这一轮受控通知回放，不是用户生活数据、整日测量或候选规则已实际生效的结果。

保存的 JSON 的 SHA-256 为 `b5f7c71d63f5079657d4b03ce692d2fc71b08adec3eed6de36f0b7d05464a3a6`。重现当前默认报告：

```powershell
& 'D:\Anaconda\envs\space1\python.exe' tool/render_batch_comparison.py docs/visualizations/data/batch-comparison-controlled.json --source device
```

## 渲染环境

使用已有的 `D:\Anaconda\envs\space1\python.exe`，本次没有安装包或修改该环境。已核查的本地版本如下：

| 组件 | 版本 | 用途 |
| --- | --- | --- |
| Python | 3.12.7 | 运行脚本，使用标准库 `zoneinfo` 处理导出时区 |
| FigCompose | 0.1.1 | 图形画布、面板组合、SVG/PNG 导出与布局检查；导入名为 `data_visuals` |
| Matplotlib | 3.9.2 | FigCompose 的绘图后端与原生自定义面板 |
| pandas | 2.2.2 | 向 FigCompose 内置矩阵图提供计数表 |
| fontTools | 4.51.0 | 从仓库字体生成报告所需的 WOFF2 子集 |
| Brotli | 1.0.9 | WOFF2 编码 |

FigCompose 的本地包元数据还声明了 NumPy、cycler、PyYAML、SciPy 与 statsmodels 依赖。它们已随 `space1` 环境提供；报告脚本不负责安装或升级依赖。

脚本是 [tool/render_batch_comparison.py](../../tool/render_batch_comparison.py)。所有图均实际经由 FigCompose 生成：动作迁移矩阵使用其内置 `confusion` 图形接口，其余三图使用其支持的原生自定义面板。每张图导出后调用 `figure.check()`，检查失败时停止生成报告。

## 生成报告

从仓库根目录运行，输入应用中“导出对比数据 JSON”获得的 JSON：

```powershell
Set-Location 'F:\notication_interceptor'
& 'D:\Anaconda\envs\space1\python.exe' tool/render_batch_comparison.py 'path\notification-batch-comparison.json' --source export
```

默认更新 `docs/visualizations/batch-comparison.html`，并将各图的 SVG、PNG 和 `render-manifest.json` 写入已被 Git 忽略的 `build/figcompose-comparison/`。生成清单记录 FigCompose 版本、输入路径、数据来源、样本数、摘要和四图检查结果。可用 `--output` 与 `--artifacts` 指定其他输出位置，用 `--label` 指定报告中的候选预设显示名称。

`--source device` 标记“模拟器受控通知回放”，用于本轮受控设备演示；一般本机导出使用 `--source export`。此参数用于如实描述数据来源，不改变导出 JSON 中的样本、决策或时间。

使用可复现的[构造示例数据](data/batch-comparison-demo.json)验证呈现方式时，输出到独立的构建目录，保留默认设备报告：

```powershell
& 'D:\Anaconda\envs\space1\python.exe' tool/render_batch_comparison.py --demo --output build/figcompose-comparison/demo.html --artifacts build/figcompose-comparison/demo
```

`--demo` 使用固定数据生成示例 JSON，页首明确显示“示例数据 · 非真实效果”。示例中的多日期时间分布仅用于展示图表，不能作为实际产品效果或用户生活规律的证据。设备报告使用应用真实导出的本轮处理事件，保留原始时间戳，不添加或挪动时间，也不代表日常使用或完整一天的测量。

HTML 不支持直接替换为另一份 JSON：需要重新运行脚本，同时生成四图与明细，避免数据不同步。页面提供搜索、应用与变化类型筛选、每页 30 条明细、下载本次 JSON，以及打印或保存 PDF。打印使用当前筛选和当前页的明细；完整数据保存在内嵌 JSON 中。

## 四张图的口径

| 图形 | 展示内容 | 解释边界 |
| --- | --- | --- |
| 动作流向图 | 同一处理事件从当前策略动作迁移到候选策略动作，带宽为事件数；深灰为动作改变 | 更多“预计拦截”不自动代表规则更好 |
| 应用配对点图 | 每个应用当前与候选的预计拦截比例，按动作变化数量排序，最多 8 个应用 | 按 `packageName` 分组，`appLabel` 仅用于显示；分母为该应用在本批中的处理事件数 |
| 动作迁移矩阵 | 三种当前动作 × 三种候选动作的交叉事件数 | 使用 FigCompose 的矩阵接口绘制计数；没有人工真值，不是准确率、召回率或误报率评估 |
| 小时变化热图 | 新增预计拦截、减少预计拦截与仅命中来源改变，按历史时刻在导出时区内逐小时聚合 | 跨日期的同一小时合计；单小时样本保留单小时分布；空白不等于完整一天没有通知 |

## 数据与计算边界

输入遵循 `schemaVersion: 1`、`kind: "notification_batch_comparison"` 的导出契约。脚本校验样本数、动作枚举和时间戳，拒绝混入系统分组汇总或超过 1000 条的样本，逐行重算摘要并核对导出摘要；导出的调试 `extras` 不进入报告。

- 一行是一个历史**处理事件**。同一通知的更新可能留下多条事件，不能将行数解释成独立通知数。
- 当前与候选策略都按各行历史 `timestamp` 和导出 `zoneId` 回放；此功能不应用候选规则，也不重新发送或取消通知。
- `sampleCount` 是排除系统汇总后、按所选上限采样的最新事件数。`scope.sourceCount` 是本地历史窗口按时间范围筛选后的源事件数；本地最多保留 1000 条，不保证覆盖完整一天或一周。
- `actionChanged` 是动作改变；`ruleChanged` 是 `ruleId` 或 `reason` 改变，可能与动作改变重叠；`totalChanged` 是二者并集。仅命中来源改变为 `totalChanged - actionChanged`。
- 新增预计拦截是放行或仅记录变为 `intercept`；减少预计拦截是相反方向。“预计拦截”表示规则判断，不能当作已经从通知栏成功移除。
- 历史确认移除数仅统计原历史动作为 `intercept` 且 `cancelStatus` 为 `success` 的事件；`pending`、拒绝、失败或未尝试不计入。这项历史参考也不代表候选策略的执行结果。
- 内容被系统隐藏时，仅能对实际可见文本匹配。规则顺序、全局开关、默认动作、场景的历史时段均影响回放。

## 字体与许可

图表使用仓库原版 `android/generator/src/main/res/font/source_han_serif_sc_regular.otf`（思源宋体 Source Han Serif SC Regular）绘制矢量字形。网页正文内嵌的是按本次文本生成的衍生 WOFF2 子集；为避开原字体的保留名称 `Source`，子集家族、PostScript 名称与 CFF 名称改为 `Notification Report Serif` / `NotificationReportSerif-Regular`。

子集保留原字体版权、许可文字和许可链接对应的 `name` 元数据（包括 ID 0、13、14）。HTML 还在“内嵌字体来源与 OFL 许可”折叠区内携带原版字体版权元数据和[仓库随附的完整 SIL Open Font License 1.1](../../assets/licenses/SourceHanSerif-OFL.txt)，无须联网查看。原 OTF 元数据的版权年份为 2017–2024，仓库独立许可文本头为 2017–2022；两份原始声明均如实保留。此许可适用于字体软件，未将报告内容改为字体许可证。

## 手机通知管理与专注状态调研

[打开离线调研报告](notification-survey.html)，或直接使用 [PNG图片](notification-survey/survey-overview.png)、[SVG矢量图](notification-survey/survey-overview.svg) 与 [PDF图表](notification-survey/survey-overview.pdf)。报告内嵌图形、字体及下载文件，可以单独复制、离线打开；完整题目与原始选项可逐题展开。

数据来自仓库根目录的 `手机通知管理与专注状态调研_392334267 (1).docx`。Q1–Q4各55份有效回答，Q5为53份，Q6–Q9各50份；Q1的55份回答均为本科生。原始文件只有各题边际频数，不能还原同一个人的多题回答，因此不使用要求逐人记录的 `participant_tracks` 环形多轨图。最终以8道题各自独立的100%堆叠条形图展示Q2–Q9，Q1作为样本说明，原始零人数选项保留在报告和数据中。

图形通过已有FigCompose 0.1.1的自定义面板绘制、导出和检查，使用仓库内置思源宋体；无需安装或升级环境。复现命令：

```powershell
& 'D:\Anaconda\envs\space1\python.exe' tool/render_notification_survey.py
```

脚本 [render_notification_survey.py](../../tool/render_notification_survey.py) 直接解析Word XML统计表，校验选项人数之和、源文件比例、堆叠长度和FigCompose布局。提取的数据位于 [notification-survey.json](data/notification-survey.json)；[CSV](notification-survey/notification-survey.csv) 使用UTF-8 BOM；[生成清单](notification-survey/render-manifest.json) 保存源文件SHA-256、环境版本、各题人数和检查结果。脚本为本份问卷配置了中文缩写与摘要，源数据变化时会要求先复核展示标签和结论。

每题按本题有效人数归一化，选项依原文顺序，颜色只在本题内区分选项。Q2、Q3显示比例合计100.01%，Q5为99.99%，属于四舍五入；图形长度使用人数计算的未舍入比例。文档未说明各题有效人数不同的原因，报告不推断题间关联、因果关系或总体代表性。PNG、SVG和PDF均为完整八题图；网页打印另含数据口径，导出的PDF图表只有单页图形。
