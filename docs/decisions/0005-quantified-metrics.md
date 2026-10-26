# ADR 0005：把 e2e 结果做成可复算的量化数据

- 状态：已采纳
- 日期：2026-10-17

## 背景

`tool/e2e.ps1` 原本只产出 Markdown 表格（场景名 + PASS/FAIL + 一句详情）。问题：

- 无法回答"准确率多少、时延分布如何、稳定性怎样"这类需要计算的问题；
- 无法做回归门禁，只能靠人看日志；
- "会不会响"这类系统行为没有结构化数据，只能凭印象。

## 决策

1. **e2e 同时产出机器可读的 JSON**（`reports/e2e-<stamp>.json`）：
   - `notifications[]`：每条通知一行，含 `expected / action / cancelStatus /
     ruleId / postTime / decisionTime / latencyMs`；
   - `events[]`：每个场景的系统事件统计（`enqueued / alerted / coalesced /
     belowThreshold / cancelledByIc`）；
   - `sound`：响铃可听性前提（通知流音量、`zenMode`、铃声模式）。
2. **指标由独立脚本复算**（`tool/metrics.ps1`），不在 e2e 里算：
   混淆矩阵、Precision/Recall/F1、时延分位（p50/p90/p95/p99）、取消成功率、
   重复处理率、响铃观测值；输出 `metrics.md` + `metrics.csv`。
3. **响铃以系统 EventLog 为权威源**，不用 `dumpsys audio` 采样：
   - `notification_alert[key, user, aboveThreshold, ?, ?, flag]`
     —— `aboveThreshold=1` 表示系统真的打扰；`flag=2048` 表示同批合并被抑制；
   - `notification_canceled[..., {cancellerComponent}]` —— 第 8 段直接写明
     取消者组件，可审计"是不是我们取消的"。
4. **阈值回归**：`-Gate` 检查 precision ≥ 98%、recall ≥ 98%、p95 ≤ 6000 ms、
   取消成功率 ≥ 99%、重复率 = 0，不达标 `exit 1`。

## 关键度量纪律

| 纪律 | 原因 |
|---|---|
| ground truth 必须来自数据（生成器 `keep` 标记 / 场景 `ExpectAction`） | 用被测代码的输出当标准就是自证 |
| OBSERVED 场景不进成功率分母 | ongoing/progress 被系统拒绝是事实，不是缺陷 |
| 重复率只在单次运行内统计 | 跨运行复用同一 tag/id 是正常现象 |
| 响铃必须先清空托盘再发 | 同应用已有通知会让新通知判为"更新"而不打扰 |
| 0 错误要报置信上界 | 30 个样本 100% 通过，真实失败率上界仍在 10% 量级 |

## 结果

- 一次运行即可给出：TP=13/FP=0/FN=0/TN=33、p50 1759 ms、p95 5178 ms、
  取消成功率 100%、重复率 0%。
- 得到一个此前只能靠猜的结论：**拦截成功 ≠ 没有响**——`aboveThreshold=1` 与
  `cancelStatus=success` 同时成立，响铃比取消早 200–1300 ms。

## 代价

- e2e 每次多跑 3 次 `logcat`/`sets` 采样（约 +2 s/场景）。
- 响铃观测值仍受托盘状态与系统合并策略影响，只能作为观测指标，不能进门禁。

## 相关

- [structure.md](../../structure.md) 8.5
- [docs/verification/checklist.md](../verification/checklist.md)
- [ADR 0003](0003-e2e-probe-app.md)
- [ADR 0006](0006-alert-sound-protocol.md)
- [ADR 0007](0007-statistical-testing.md)（把点估计升级为区间与假设检验）
