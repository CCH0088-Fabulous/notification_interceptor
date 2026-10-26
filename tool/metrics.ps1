# 指标计算：把 e2e 生成的 JSON 复算成可判读的量化报告。
#
# 数据来源：docs/verification/reports/e2e-<stamp>.json（由 tool/e2e.ps1 自动产出）
#
# 用法：
#   .\tool\metrics.ps1                 # 用最新一次 e2e 数据
#   .\tool\metrics.ps1 -Run 3          # 最近 3 次合并统计（样本量更大）
#   .\tool\metrics.ps1 -Gate           # 同时做阈值回归，超阈值 exit 1
#   .\tool\metrics.ps1 -File path.json # 指定文件
param(
    [string]$File,
    [int]$Run = 0,
    [switch]$Gate,
    [string]$OutDir = 'docs\verification'
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

# 阈值：低于/高于即视为回归。数值来自当前基线的保守区间，可按需调整。
$thresholds = @{
    Precision          = 0.98    # 该保留的里被正确保留的比例
    Recall             = 0.98    # 该拦的里被正确拦掉的比例
    P95LatencyMs       = 1000    # 单次运行全场景的 p95（ADR 0008 后基线 ~300ms，改前 ~5.2s）
    CancelSuccessRate  = 0.99    # 取消成功率（ongoing/系统拒绝除外）
    DuplicateRate      = 0.0     # 重复处理率必须为 0
}

function Resolve-ReportFiles {
    $dir = Join-Path $RepoRoot 'docs\verification\reports'
    if ($File) { return @((Resolve-Path $File).Path) }
    $all = @(Get-ChildItem $dir -Filter 'e2e-*.json' | Sort-Object LastWriteTime -Descending)
    if ($all.Count -eq 0) { throw "没有找到 e2e 数据文件，先运行 tool\e2e.ps1。" }
    if ($Run -gt 0) { return @($all | Select-Object -First $Run | ForEach-Object { $_.FullName }) }
    # 默认按内容选文件，而不是"最新"：单跑一个专项（如 -Only alert-sound）
    # 会产出一份 0 条通知记录的报告，用它覆盖 metrics.md 会把判定质量清空。
    # 因此取「通知样本最多的一份」+「alerts 最多的一份」，两份各自贡献自己的指标。
    $bestNotifications = $null
    $bestNotificationsCount = -1
    $bestAlerts = $null
    $bestAlertsCount = -1
    foreach ($report in $all) {
        $probe = Get-Content $report.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $n = @($probe.notifications | Where-Object { $_ -and $_.tag -ne '0' -and $_.key -notmatch '\|g:' }).Count
        $a = @($probe.alerts | Where-Object { $_ }).Count
        if ($n -gt $bestNotificationsCount) { $bestNotificationsCount = $n; $bestNotifications = $report.FullName }
        if ($a -gt $bestAlertsCount) { $bestAlertsCount = $a; $bestAlerts = $report.FullName }
    }
    $picked = @()
    if ($bestNotifications) { $picked += $bestNotifications }
    if ($bestAlerts -and $bestAlerts -ne $bestNotifications) { $picked += $bestAlerts }
    if ($picked.Count -eq 0) { return @($all[0].FullName) }
    return $picked
}

function Get-Percentile {
    param([double[]]$Values, [double]$P)
    if ($Values.Count -eq 0) { return $null }
    $sorted = $Values | Sort-Object
    $index = [int][Math]::Floor($P * ($sorted.Count - 1))
    return $sorted[$index]
}

function Format-Rate {
    param([int]$Numerator, [int]$Denominator)
    if ($Denominator -eq 0) { return 'n/a' }
    return ('{0:P2} ({1}/{2})' -f ($Numerator / $Denominator), $Numerator, $Denominator)
}

# 0 错误时的 95% 置信上界（rule of three），避免"100% 通过"被过度解读。
function Format-ZeroBound {
    param([int]$Total)
    if ($Total -eq 0) { return 'n/a' }
    return ('≤{0:P1}' -f (3.0 / $Total))
}

$files = Resolve-ReportFiles
$runs = @($files | ForEach-Object { Get-Content $_ -Raw -Encoding UTF8 | ConvertFrom-Json })
# 防御：早期版本可能把系统自动分组的汇总条目也写进了记录（tag=0 / key 含 g:Aggregate）。
$notifications = @($runs | ForEach-Object { $_.notifications } | Where-Object {
        $_ -and $_.tag -ne '0' -and $_.key -notmatch '\|g:'
    })
$events = @($runs | ForEach-Object { $_.events } | Where-Object { $_ })
$alerts = @($runs | ForEach-Object { $_.alerts } | Where-Object { $_ })
$scenarios = @($runs | ForEach-Object { $_.scenarios } | Where-Object { $_ })
$latest = $runs[0]

Write-Host ("数据来源：{0} 个文件，{1} 条通知记录，{2} 个场景" -f `
        $files.Count, $notifications.Count, $scenarios.Count)

# ---------------------------------------------------------------- 判定质量

$tp = 0; $fp = 0; $fn = 0; $tn = 0
foreach ($n in $notifications) {
    if (-not $n.expected) { continue }
    $shouldKeep = ($n.expected -eq 'keep')
    $kept = ($n.action -eq 'allow')
    if ($shouldKeep -and $kept) { $tp++ }
    elseif (-not $shouldKeep -and $kept) { $fp++ }
    elseif ($shouldKeep -and -not $kept) { $fn++ }
    else { $tn++ }
}
$precision = if (($tp + $fp) -gt 0) { $tp / ($tp + $fp) } else { $null }
$recall = if (($tp + $fn) -gt 0) { $tp / ($tp + $fn) } else { $null }
$f1 = if ($precision -and $recall -and ($precision + $recall) -gt 0) {
    2 * $precision * $recall / ($precision + $recall)
} else { $null }

# ---------------------------------------------------------------- 时延

$latencies = @($notifications | Where-Object { $_.latencyMs -ne $null } | ForEach-Object { [double]$_.latencyMs })
$latStats = [ordered]@{
    n    = $latencies.Count
    min  = if ($latencies.Count) { ($latencies | Measure-Object -Minimum).Minimum } else { $null }
    p50  = Get-Percentile $latencies 0.5
    p90  = Get-Percentile $latencies 0.9
    p95  = Get-Percentile $latencies 0.95
    p99  = Get-Percentile $latencies 0.99
    max  = if ($latencies.Count) { ($latencies | Measure-Object -Maximum).Maximum } else { $null }
    mean = if ($latencies.Count) { [math]::Round(($latencies | Measure-Object -Average).Average, 1) } else { $null }
}

$byScenario = @($notifications | Group-Object scenario | ForEach-Object {
        $values = @($_.Group | ForEach-Object { [double]$_.latencyMs })
        [pscustomobject]@{
            scenario = $_.Name
            n        = $values.Count
            p50      = Get-Percentile $values 0.5
            p95      = Get-Percentile $values 0.95
            max      = ($values | Measure-Object -Maximum).Maximum
        }
    }) | Sort-Object -Property p95 -Descending

# ---------------------------------------------------------------- 取消与去重

# OBSERVED 场景是"记录系统行为"（如 ongoing 被系统拒绝取消），不计入成功率分子分母。
$observedScenarios = @{}
foreach ($s in $scenarios) { if ($s.status -eq 'OBSERVED') { $observedScenarios[$s.name] = $true } }

$cancelAttempts = @($notifications | Where-Object {
        $_.cancelStatus -and $_.cancelStatus -ne 'not_attempted' -and -not $observedScenarios[$_.scenario]
    })
$cancelOk = @($cancelAttempts | Where-Object { $_.cancelStatus -eq 'success' })
$cancelRejected = @($cancelAttempts | Where-Object { $_.cancelStatus -eq 'rejected' })
$cancelFailed = @($cancelAttempts | Where-Object { $_.cancelStatus -eq 'failed' })
$cancelRate = if ($cancelAttempts.Count) { $cancelOk.Count / $cancelAttempts.Count } else { $null }
$observedRejected = @($notifications | Where-Object {
        $_.cancelStatus -eq 'rejected' -and $observedScenarios[$_.scenario]
    }).Count

# 重复处理必须在**单次运行内**看：跨运行复用同一 tag/id 属正常现象。
$duplicateTotal = 0
$uniqueTotal = 0
foreach ($report in $runs) {
    $scoped = @($report.notifications | Where-Object { $_ -and $_.tag -ne '0' -and $_.key -notmatch '\|g:' })
    foreach ($group in ($scoped | Group-Object scenario)) {
        $keys = @($group.Group | ForEach-Object { $_.key } | Sort-Object -Unique)
        $uniqueTotal += $keys.Count
        $duplicateTotal += ($group.Group.Count - $keys.Count)
    }
}
$duplicateRate = if (($uniqueTotal + $duplicateTotal) -gt 0) {
    $duplicateTotal / ($uniqueTotal + $duplicateTotal)
} else { 0 }

# ---------------------------------------------------------------- 响铃

$enqueued = ($events | Measure-Object -Property enqueued -Sum).Sum
$alerted = ($events | Measure-Object -Property alerted -Sum).Sum
$coalesced = ($events | Measure-Object -Property coalesced -Sum).Sum
$suppressedOther = ($events | Measure-Object -Property suppressedOther -Sum).Sum
$below = ($events | Measure-Object -Property belowThreshold -Sum).Sum
$alertRate = if ($enqueued -gt 0) { $alerted / $enqueued } else { $null }

$soundContext = $latest.sound
$audibleNote = '未知'
if ($soundContext) {
    $volumeOk = ($soundContext.notificationVolume -ne $null) -and
                ($soundContext.notificationVolumeMax -gt 0) -and
                ($soundContext.notificationVolume -gt 0)
    $zenOk = ($soundContext.zenMode -eq '0')
    $audibleNote = if ($volumeOk -and $zenOk) { '可听（音量>0 且未开勿扰）' } else { '不可听（音量 0 或勿扰开启）' }
}

# ---------------------------------------------------------------- 响铃专项（alert-sound）

# 对照组必须响：不响说明设备静音/勿扰，后面所有"拦截是否漏响"的结论都不成立。
$alertControls = @($alerts | Where-Object { $_.name -eq 'allow-default' })
$controlRang = @($alertControls | Where-Object { $_.alerted -ge 1 }).Count
$controlTotal = $alertControls.Count
$instrumentValid = ($controlTotal -gt 0) -and ($controlRang -eq $controlTotal)

$interceptedCases = @($alerts | Where-Object { $_.cancelledByIc -gt 0 -and $_.name -ne 'allow-default' })
$leakCases = @($interceptedCases | Where-Object { $_.alerted -gt 0 })
$leakRate = if ($interceptedCases.Count) { $leakCases.Count / $interceptedCases.Count } else { $null }

# ---------------------------------------------------------------- 场景

$passCount = @($scenarios | Where-Object { $_.status -eq 'PASS' }).Count
$failCount = @($scenarios | Where-Object { $_.status -eq 'FAIL' }).Count
$observedCount = @($scenarios | Where-Object { $_.status -eq 'OBSERVED' }).Count

# ---------------------------------------------------------------- 报告

$outDirPath = Join-Path $RepoRoot $OutDir
New-Item -ItemType Directory -Force -Path $outDirPath | Out-Null
$mdPath = Join-Path $outDirPath 'metrics.md'
$csvPath = Join-Path $outDirPath 'metrics.csv'

$md = New-Object System.Collections.ArrayList
[void]$md.Add('# 量化指标报告')
[void]$md.Add('')
[void]$md.Add(("- 数据来源：{0}（{1} 个文件，最新 {2}）" -f (($files | ForEach-Object { Split-Path $_ -Leaf }) -join '、'), $files.Count, $latest.stamp))
[void]$md.Add(("- 样本：{0} 条通知记录 · {1} 个场景" -f $notifications.Count, $scenarios.Count))
[void]$md.Add(("- 设备：{0} / Android {1} (API {2})" -f $latest.device.model, $latest.device.release, $latest.device.sdk))
[void]$md.Add('')
[void]$md.Add('## 1. 判定质量')
[void]$md.Add('')
[void]$md.Add('| 指标 | 值 |')
[void]$md.Add('|---|---|')
[void]$md.Add(("| 混淆矩阵 | TP={0} · FP={1} · FN={2} · TN={3} |" -f $tp, $fp, $fn, $tn))
[void]$md.Add(("| Precision（保留的正确率） | {0} |" -f (Format-Rate $tp ($tp + $fp))))
[void]$md.Add(("| Recall（拦截的召回率） | {0} |" -f (Format-Rate $tp ($tp + $fn))))
[void]$md.Add(("| F1 | {0} |" -f $(if ($f1) { '{0:P4}' -f $f1 } else { 'n/a' })))
[void]$md.Add(("| 零错误置信上界 | 假阳性 {0} · 漏拦 {1}（95%，rule of three） |" -f `
                (Format-ZeroBound ($tn + $fp)), (Format-ZeroBound ($tp + $fn))))
[void]$md.Add('')
[void]$md.Add('## 2. 处理时延')
[void]$md.Add('')
[void]$md.Add('| n | min | p50 | p90 | p95 | p99 | max | mean |')
[void]$md.Add('|---|---|---|---|---|---|---|---|')
[void]$md.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |" -f `
            $latStats.n, $latStats.min, $latStats.p50, $latStats.p90, $latStats.p95, $latStats.p99, $latStats.max, $latStats.mean))
[void]$md.Add('')
[void]$md.Add('按场景（p95 降序）：')
[void]$md.Add('')
[void]$md.Add('| 场景 | n | p50 | p95 | max |')
[void]$md.Add('|---|---|---|---|---|')
foreach ($row in $byScenario) {
    [void]$md.Add(("| {0} | {1} | {2} | {3} | {4} |" -f $row.scenario, $row.n, $row.p50, $row.p95, $row.max))
}
[void]$md.Add('')
[void]$md.Add('## 3. 取消与去重')
[void]$md.Add('')
[void]$md.Add('| 指标 | 值 |')
[void]$md.Add('|---|---|')
[void]$md.Add(("| 取消成功率 | {0} |" -f (Format-Rate $cancelOk.Count $cancelAttempts.Count)))
[void]$md.Add(("| 被系统拒绝（rejected，非 OBSERVED 场景） | {0} |" -f $cancelRejected.Count))
[void]$md.Add(("| 观测到被系统拒绝（OBSERVED 场景，如 ongoing/progress） | {0} |" -f $observedRejected))
[void]$md.Add(("| 调用失败（failed） | {0} |" -f $cancelFailed.Count))
[void]$md.Add(("| 重复处理率 | {0}（{1} 条重复 / {2} 条记录） |" -f ('{0:P2}' -f $duplicateRate), $duplicateTotal, ($uniqueTotal + $duplicateTotal)))
[void]$md.Add('')
[void]$md.Add('## 4. 响铃（系统 EventLog，观测值）')
[void]$md.Add('')
[void]$md.Add('| 指标 | 值 | 说明 |')
[void]$md.Add('|---|---|---|')
[void]$md.Add(("| 入队通知数 | {0} | 已排除系统自动分组的汇总条目 |" -f $enqueued))
[void]$md.Add(("| 实际打扰数 | {0} | notification_alert 的 aboveThreshold=1，即真的响铃/震动 |" -f $alerted))
[void]$md.Add(("| 系统合并抑制 | {0} | aboveThreshold=0 且 flag=2048：同批只响一次，与本应用无关 |" -f $coalesced))
[void]$md.Add(("| 系统其他抑制 | {0} | aboveThreshold=0 且 flag=其他非零值（如 32768）：同应用连续通知被抑制 |" -f $suppressedOther))
[void]$md.Add(("| 低于打扰阈值 | {0} | 如 IMPORTANCE_LOW 渠道，本来就不会响 |" -f $below))
[void]$md.Add(("| 观测打扰率 | {0} | 仅作观测：受托盘是否已有同应用通知、系统合并策略影响 |" -f (Format-Rate $alerted $enqueued)))
[void]$md.Add(("| 可听性前提 | {0} | 音量 {1}/{2} · zenMode={3} |" -f `
                $audibleNote, $soundContext.notificationVolume, $soundContext.notificationVolumeMax, $soundContext.zenMode))
[void]$md.Add('')
[void]$md.Add('分场景（跨运行合计）：')
[void]$md.Add('')
[void]$md.Add('| 场景 | 入队 | 打扰 | 合并抑制 | 其他抑制 | 低阈值 |')
[void]$md.Add('|---|---|---|---|---|---|')
foreach ($row in ($events | Group-Object scenario | ForEach-Object {
            [pscustomobject]@{
                scenario        = $_.Name
                enqueued        = ($_.Group | Measure-Object -Property enqueued -Sum).Sum
                alerted         = ($_.Group | Measure-Object -Property alerted -Sum).Sum
                coalesced       = ($_.Group | Measure-Object -Property coalesced -Sum).Sum
                suppressedOther = ($_.Group | Measure-Object -Property suppressedOther -Sum).Sum
                belowThreshold  = ($_.Group | Measure-Object -Property belowThreshold -Sum).Sum
            }
        } | Sort-Object -Property scenario)) {
    [void]$md.Add(("| {0} | {1} | {2} | {3} | {4} | {5} |" -f `
                $row.scenario, $row.enqueued, $row.alerted, $row.coalesced, $row.suppressedOther, $row.belowThreshold))
}
[void]$md.Add('')
[void]$md.Add('> 两个已确认的结论：')
[void]$md.Add('> 1. 响铃发生在 post 瞬间，早于 cancelNotification（实测单条 `cancelStatus=success` 且 `aboveThreshold=1`），**拦截无法阻止首次响铃**。')
[void]$md.Add('> 2. 同一应用的连发会被系统抑制（flag `2048` / `32768`），因此"响了几次"不能直接当"漏拦率"；受控的单条结论见第 5 节。')
[void]$md.Add('')
[void]$md.Add('## 5. 响铃泄漏（alert-sound 专项）')
[void]$md.Add('')
if ($alerts.Count -eq 0) {
    [void]$md.Add('> 本次数据没有 alert-sound 用例；运行 `tool\e2e.ps1 -Only alert-sound` 后重新生成。')
} else {
    [void]$md.Add('| 指标 | 值 | 说明 |')
    [void]$md.Add('|---|---|---|')
    [void]$md.Add(("| 仪器有效性（对照组响铃） | {0} | 放行 + DEFAULT 渠道必须响，否则测量无效 |" -f (Format-Rate $controlRang $controlTotal)))
    [void]$md.Add(("| 拦截后仍响铃的用例 | {0} | 已成功取消（cancelledByIc>0）且系统记录 aboveThreshold=1 |" -f (Format-Rate $leakCases.Count $interceptedCases.Count)))
    [void]$md.Add(("| 走音比例 | {0} | 拦截的用例里响过铃的比例 |" -f $(if ($leakRate -ne $null) { '{0:P1}' -f $leakRate } else { 'n/a' })))
    [void]$md.Add('')
    [void]$md.Add('| 用例 | 说明 | 发送 | 入队 | 打扰 | 合并抑制 | 其他抑制 | 低阈值 | 被拦截 |')
    [void]$md.Add('|---|---|---|---|---|---|---|---|---|')
    foreach ($case in $alerts) {
        [void]$md.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |" -f `
                    $case.name, $case.description, $case.count, $case.enqueued, $case.alerted,
                    $case.coalesced, $case.suppressedOther, $case.belowThreshold, $case.cancelledByIc))
    }
    [void]$md.Add('')
    [void]$md.Add('> 结论：拦截只能移除通知，**不能阻止首次响铃**；低重要度渠道天然不响；')
    [void]$md.Add('> 系统还会对同一应用的连续通知做打扰抑制（flag 2048 / 32768），')
    [void]$md.Add('> 因此"响了几次"不能当"漏拦率"，单条用例必须留足静默期再测。')
}
[void]$md.Add('')
[void]$md.Add('## 6. 场景结果')
[void]$md.Add('')
[void]$md.Add(("- PASS {0} · FAIL {1} · OBSERVED {2}" -f $passCount, $failCount, $observedCount))
[void]$md.Add('')

[System.IO.File]::WriteAllLines($mdPath, $md, $Utf8NoBom)

$notifications | Select-Object scenario, tag, package, channelId, expected, action, cancelStatus, ruleId, latencyMs, postTime, decisionTime |
    Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host '=== 关键指标 ==='
Write-Host ("判定：TP={0} FP={1} FN={2} TN={3} · precision={4} · recall={5}" -f `
        $tp, $fp, $fn, $tn, (Format-Rate $tp ($tp + $fp)), (Format-Rate $tp ($tp + $fn)))
Write-Host ("时延：p50={0}ms p95={1}ms max={2}ms（n={3}）" -f $latStats.p50, $latStats.p95, $latStats.max, $latStats.n)
Write-Host ("取消：成功率={0} · 拒绝={1} · 失败={2} · 重复率={3:P2}" -f `
        (Format-Rate $cancelOk.Count $cancelAttempts.Count), $cancelRejected.Count, $cancelFailed.Count, $duplicateRate)
Write-Host ("响铃：打扰 {0}/{1}（合并抑制 {2}，其他抑制 {3}，低阈值 {4}）· {5}" -f `
        $alerted, $enqueued, $coalesced, $suppressedOther, $below, $audibleNote)
if ($alerts.Count -gt 0) {
    Write-Host ("响铃专项：对照组 {0} · 拦截后仍响 {1} · 走音比例 {2}" -f `
            (Format-Rate $controlRang $controlTotal),
        (Format-Rate $leakCases.Count $interceptedCases.Count),
        $(if ($leakRate -ne $null) { '{0:P1}' -f $leakRate } else { 'n/a' }))
}
Write-Host ("报告：{0}" -f (Resolve-Path -Relative $mdPath))
Write-Host ("明细：{0}" -f (Resolve-Path -Relative $csvPath))

if ($Gate) {
    $violations = New-Object System.Collections.ArrayList
    if ($precision -ne $null -and $precision -lt $thresholds.Precision) {
        [void]$violations.Add(("precision {0:P2} < {1:P2}" -f $precision, $thresholds.Precision))
    }
    if ($recall -ne $null -and $recall -lt $thresholds.Recall) {
        [void]$violations.Add(("recall {0:P2} < {1:P2}" -f $recall, $thresholds.Recall))
    }
    if ($latStats.p95 -ne $null -and $latStats.p95 -gt $thresholds.P95LatencyMs) {
        [void]$violations.Add(("p95 {0}ms > {1}ms" -f $latStats.p95, $thresholds.P95LatencyMs))
    }
    if ($cancelRate -ne $null -and $cancelRate -lt $thresholds.CancelSuccessRate) {
        [void]$violations.Add(("取消成功率 {0:P2} < {1:P2}" -f $cancelRate, $thresholds.CancelSuccessRate))
    }
    if ($duplicateRate -gt $thresholds.DuplicateRate) {
        [void]$violations.Add(("重复处理率 {0:P2} > {1:P2}" -f $duplicateRate, $thresholds.DuplicateRate))
    }
    if ($alerts.Count -gt 0 -and -not $instrumentValid) {
        [void]$violations.Add(('响铃对照组未响（{0}），响铃测量无效：检查通知音量与勿扰状态' -f `
                    (Format-Rate $controlRang $controlTotal)))
    }

    Write-Host ''
    if ($violations.Count -eq 0) {
        Write-Host '阈值回归：通过'
        exit 0
    }
    Write-Host '阈值回归：未通过'
    foreach ($v in $violations) { Write-Host ("  - $v") }
    exit 1
}
exit 0
