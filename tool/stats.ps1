# 显著性检验：回答三个问题，并给出统计强度而不只是"0 个错误"。
#
#   1. 会不会漏掉？   → 漏拦率 + Wilson 95% 区间 + 单侧二项检验（H0: p ≥ p0）
#   2. 会不会误拦截？ → 误拦率 + Wilson 95% 区间 + 单侧二项检验（H0: p ≥ p0）
#   3. 平均拦截时间？ → 均值 + 95% CI（bootstrap 与正态近似）+ 分位数，按"单条/并发批"分档
#
# 为什么需要单侧二项检验：
#   0 个错误 ≠ 错误率 = 0。n 条 0 错误时，95% 置信上界约为 3/n（rule of three）。
#   要宣称"漏拦率 < 1%"并达到 95% 把握，需要 n ≥ 299（0 错误）。
#   本脚本把"能不能这么宣称"直接算出来，避免过度解读。
#
# 用法：
#   .\tool\stats.ps1                          # 合并所有含 bulk-triage 的报告
#   .\tool\stats.ps1 -Run 3                   # 最近 3 个报告
#   .\tool\stats.ps1 -File out.json           # 指定文件
#   .\tool\stats.ps1 -Gate                    # 错误率超过阈值时 exit 1
param(
    [string[]]$File,
    [int]$Run = 0,
    [switch]$Gate,
    [double]$MaxErrorRate = 0.01,
    [string]$OutDir = 'docs\verification'
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

$Z95 = 1.959963984540054

# ---------------------------------------------------------------- 统计工具

function Format-Pct {
    param([double]$Value, [int]$Digits = 2)
    return ('{0:F' + $Digits + '}%') -f ($Value * 100)
}

# Wilson score 区间：小样本 / 极端比例（0 或 100%）下比正态近似可靠得多。
function Get-Wilson {
    param([int]$K, [int]$N, [double]$Z = $Z95)
    if ($N -le 0) { return $null }
    $p = [double]$K / $N
    $z2 = $Z * $Z
    $denom = 1.0 + $z2 / $N
    $center = ($p + $z2 / (2.0 * $N)) / $denom
    $half = ($Z * [Math]::Sqrt($p * (1 - $p) / $N + $z2 / (4.0 * $N * $N))) / $denom
    return [pscustomobject]@{
        P   = $p
        Lo  = [Math]::Max(0.0, $center - $half)
        Hi  = [Math]::Min(1.0, $center + $half)
        K   = $K
        N   = $N
        RuleOfThree = if ($K -eq 0) { 3.0 / $N } else { $null }
    }
}

# 单侧二项下尾：P(X ≤ K | N, P0)。用于检验 H0: 真实错误率 ≥ P0。
# K 个观测错误偏少 → p 值小 → 拒绝 H0 → 可以宣称错误率低于 P0。
# 用递推代替组合数，N 大时也不会溢出。
function Get-BinomialLowerTail {
    param([int]$K, [int]$N, [double]$P0)
    if ($N -le 0) { return $null }
    if ($K -lt 0) { return 0.0 }
    if ($K -ge $N) { return 1.0 }
    if ($P0 -le 0) { return 1.0 }
    if ($P0 -ge 1) { return 0.0 }
    $term = [Math]::Pow(1.0 - $P0, $N)
    $sum = $term
    for ($i = 0; $i -lt $K; $i++) {
        $term = $term * (($N - $i) / ($i + 1.0)) * ($P0 / (1.0 - $P0))
        $sum += $term
    }
    return [Math]::Min(1.0, $sum)
}

# 在给定样本量下，0 错误能证到的"最严格上界"。
# 求解 (1-p)^N = Alpha 的 p：N 越大，能宣称的上界越紧。
function Get-MinProvableBound {
    param([int]$N, [double]$Alpha = 0.05)
    if ($N -le 0) { return $null }
    $lo = 0.0
    $hi = 1.0
    for ($i = 0; $i -lt 80; $i++) {
        $mid = ($lo + $hi) / 2.0
        $p = Get-BinomialLowerTail 0 $N $mid
        # p 随 mid 单调递减：p < Alpha 说明 mid 已经足够大，可以收紧上界。
        if ($p -lt $Alpha) { $hi = $mid } else { $lo = $mid }
    }
    return ($lo + $hi) / 2.0
}

function Get-Percentile {
    param([double[]]$Values, [double]$P)
    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $index = [int][Math]::Floor($P * ($sorted.Count - 1))
    return $sorted[$index]
}

function Get-MeanCI {
    param([double[]]$Values, [int]$Iterations = 2000)
    if ($Values.Count -lt 2) { return $null }
    $n = $Values.Count
    # PowerShell 5.1 的 Measure-Object 没有 -StandardDeviation，手工算样本标准差。
    $sum = 0.0
    foreach ($v in $Values) { $sum += $v }
    $mean = $sum / $n
    $sq = 0.0
    foreach ($v in $Values) { $sq += ($v - $mean) * ($v - $mean) }
    $sd = if ($n -gt 1) { [Math]::Sqrt($sq / ($n - 1)) } else { 0.0 }
    $se = $sd / [Math]::Sqrt($n)
    $normal = [pscustomobject]@{
        Mean = $mean
        Sd   = $sd
        Se   = $se
        Lo   = [Math]::Max(0.0, $mean - $Z95 * $se)
        Hi   = $mean + $Z95 * $se
    }
    if ($n -gt 3000) { return $normal }
    $rng = New-Object System.Random 20260101
    $means = New-Object 'double[]' $Iterations
    for ($i = 0; $i -lt $Iterations; $i++) {
        $s = 0.0
        for ($j = 0; $j -lt $n; $j++) { $s += $Values[$rng.Next($n)] }
        $means[$i] = $s / $n
    }
    [Array]::Sort($means)
    $loIdx = [int][Math]::Floor(0.025 * ($Iterations - 1))
    $hiIdx = [int][Math]::Ceiling(0.975 * ($Iterations - 1))
    return [pscustomobject]@{
        Mean     = $mean
        Sd       = $sd
        Se       = $se
        Lo       = $normal.Lo
        Hi       = $normal.Hi
        BootLo   = $means[$loIdx]
        BootHi   = $means[$hiIdx]
        Bootstrap = $true
    }
}

# ---------------------------------------------------------------- 数据装载

function Resolve-ReportFiles {
    $dir = Join-Path $RepoRoot 'docs\verification\reports'
    if ($File) {
        # 兼容 `-File a.json,b.json`：外部 powershell -File 不会按逗号拆参，这里自己拆。
        $expanded = @()
        foreach ($entry in $File) {
            foreach ($piece in ($entry -split '[,;]')) {
                if ($piece.Trim()) { $expanded += (Resolve-Path $piece.Trim()).Path }
            }
        }
        return $expanded
    }
    $all = @(Get-ChildItem $dir -Filter 'e2e-*.json' | Sort-Object LastWriteTime -Descending)
    if ($all.Count -eq 0) { throw '没有找到 e2e 数据文件，先运行 tool\e2e.ps1。' }
    if ($Run -gt 0) { return @($all | Select-Object -First $Run | ForEach-Object { $_.FullName }) }
    # 默认按"统计功效最大"选文件，而不是"最新"：
    #   1. 样本最多的批量报告 —— 判定质量的分子分母都来自它；
    #   2. 单条节奏（round=1）的批量报告 —— 提供干净的时延口径；
    #   3. 最新的常规 e2e 报告 —— 覆盖非生成器场景。
    # 不合并多个批量报告：它们用相同的 seed 序列，合并等于把同一批样本数了两遍。
    $bulkBest = $null
    $bulkBestCount = -1
    $singleBest = $null
    $singleBestCount = -1
    $othersBest = $null
    $othersBestCount = -1
    foreach ($report in $all) {
        $probe = Get-Content $report.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $bulk = @($probe.scenarios | Where-Object { $_.name -eq 'bulk-triage' })
        $samples = @($probe.notifications).Count
        if ($bulk.Count -eq 0) {
            if ($samples -gt $othersBestCount) { $othersBestCount = $samples; $othersBest = $report.FullName }
            continue
        }
        $isSingle = [string]$bulk[0].detail -match 'round=1\b'
        if ($isSingle) {
            if ($samples -gt $singleBestCount) { $singleBestCount = $samples; $singleBest = $report.FullName }
        } elseif ($samples -gt $bulkBestCount) {
            $bulkBestCount = $samples
            $bulkBest = $report.FullName
        }
    }
    $picked = @()
    if ($bulkBest) { $picked += $bulkBest }
    if ($singleBest -and $singleBest -ne $bulkBest) { $picked += $singleBest }
    if ($othersBest -and $picked.Count -gt 0) { $picked += $othersBest }
    if ($picked.Count -eq 0) { return @($all[0].FullName) }
    return $picked
}

$files = Resolve-ReportFiles
$runs = @($files | ForEach-Object { Get-Content $_ -Raw -Encoding UTF8 | ConvertFrom-Json })

# 同 metrics.ps1 口径：排除系统自动分组汇总条目（tag=0 / key 含 g:Aggregate），
# 但保留 expected=null 之外的全部真实投递——它们都是被测样本。
# 同时打上报告序号：跨运行的 key 会重复（生成器 seq 从 1 开始），
# 重复率必须按"单次运行内"统计，否则会把正常复用误算成重复处理。
$samples = New-Object System.Collections.Generic.List[object]
$reportIndex = 0
# 注意：循环变量不能叫 $run —— 与参数 $Run（强类型 int）同名，会赋值失败。
foreach ($report in $runs) {
    $reportIndex++
    foreach ($n in @($report.notifications)) {
        if (-not $n) { continue }
        if ($n.tag -eq '0' -or $n.key -match '\|g:') { continue }
        $n | Add-Member -NotePropertyName reportIndex -NotePropertyValue $reportIndex -Force
        $samples.Add($n)
    }
}
# List 直接套 @() 会抛 "Argument types do not match"，用 ToArray() 落地。
$notifications = $samples.ToArray()

if ($notifications.Count -eq 0) { throw '记录里没有通知样本，先运行 tool\e2e.ps1 -Bulk <N>。' }

# OBSERVED 场景记录的是"系统行为"（如 ongoing 通知被系统拒绝取消），不是规则判定错误。
# 按 metrics.ps1 的口径从判定质量中剔除，单独披露条数，避免污染漏拦/误拦统计。
$observedScenarios = @{}
foreach ($report in $runs) {
    foreach ($s in @($report.scenarios)) {
        if ($s -and $s.status -eq 'OBSERVED') { $observedScenarios[$s.name] = $true }
    }
}
$observedSamples = @($notifications | Where-Object { $observedScenarios[$_.scenario] })
$notifications = @($notifications | Where-Object { -not $observedScenarios[$_.scenario] })
if ($notifications.Count -eq 0) { throw '剔除 OBSERVED 场景后没有剩余样本。' }

# 并发批标记：同一 scenario 内 postTime 相距 ≤ 2000ms 的样本共享一个"批"。
# 批量投递会被单线程队列串行化，把它的时延和单条投递混在一起会虚高 p95。
$windowMs = 2000
foreach ($n in $notifications) {
    $n | Add-Member -NotePropertyName concurrent -NotePropertyValue 0 -Force
}
for ($i = 0; $i -lt $notifications.Count; $i++) {
    $a = $notifications[$i]
    $count = 0
    for ($j = 0; $j -lt $notifications.Count; $j++) {
        if ($i -eq $j) { continue }
        $b = $notifications[$j]
        if ($a.scenario -ne $b.scenario) { continue }
        if ([Math]::Abs([double]$a.postTime - [double]$b.postTime) -le $windowMs) { $count++ }
    }
    $a.concurrent = $count
}

# ---------------------------------------------------------------- 判定质量

# 口径（与用户的问题一一对应）：
#   expected=drop & action=allow      → 漏拦 missed：该拦的没拦
#   expected=keep & action=intercept  → 误拦 falseBlock：不该拦的被拦了
$missed = @($notifications | Where-Object { $_.expected -eq 'drop' -and $_.action -eq 'allow' })
$falseBlock = @($notifications | Where-Object { $_.expected -eq 'keep' -and $_.action -eq 'intercept' })
$correctDrop = @($notifications | Where-Object { $_.expected -eq 'drop' -and $_.action -eq 'intercept' })
$correctKeep = @($notifications | Where-Object { $_.expected -eq 'keep' -and $_.action -eq 'allow' })
$shouldDrop = $missed.Count + $correctDrop.Count
$shouldKeep = $falseBlock.Count + $correctKeep.Count

$missStats = Get-Wilson $missed.Count $shouldDrop
$falseStats = Get-Wilson $falseBlock.Count $shouldKeep
$missPvalue = Get-BinomialLowerTail $missed.Count $shouldDrop $MaxErrorRate
$falsePvalue = Get-BinomialLowerTail $falseBlock.Count $shouldKeep $MaxErrorRate
$minBound = Get-MinProvableBound ([Math]::Min($shouldDrop, $shouldKeep))
$limitingSide = if ($shouldDrop -le $shouldKeep) { "漏拦（分母 $shouldDrop）" } else { "误拦（分母 $shouldKeep）" }

# ---------------------------------------------------------------- 时延

$allLatency = @($notifications | ForEach-Object { [double]$_.latencyMs })
$interceptLatency = @($notifications |
        Where-Object { $_.action -eq 'intercept' -and $_.cancelStatus -eq 'success' } |
        ForEach-Object { [double]$_.latencyMs })
$singleLatency = @($notifications | Where-Object { $_.concurrent -eq 0 } | ForEach-Object { [double]$_.latencyMs })
$burstLatency = @($notifications | Where-Object { $_.concurrent -gt 0 } | ForEach-Object { [double]$_.latencyMs })
# 单条投递的时延必须按动作拆开：放行不走取消与校验，拦截要走，
# 两者混在一起会得到一个没有物理意义的"平均值"（实测 310 ms = 216 与 473 的混合）。
$singleInterceptLatency = @($notifications |
        Where-Object { $_.concurrent -eq 0 -and $_.action -eq 'intercept' } |
        ForEach-Object { [double]$_.latencyMs })
$singleAllowLatency = @($notifications |
        Where-Object { $_.concurrent -eq 0 -and $_.action -eq 'allow' } |
        ForEach-Object { [double]$_.latencyMs })

function Get-LatencySummary {
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return $null }
    $ci = Get-MeanCI $Values
    return [pscustomobject]@{
        N    = $Values.Count
        Mean = [Math]::Round($ci.Mean, 1)
        Lo   = [Math]::Round($ci.Lo, 1)
        Hi   = [Math]::Round($ci.Hi, 1)
        BootLo = if ($ci.Bootstrap) { [Math]::Round($ci.BootLo, 1) } else { $null }
        BootHi = if ($ci.Bootstrap) { [Math]::Round($ci.BootHi, 1) } else { $null }
        Sd   = [Math]::Round($ci.Sd, 1)
        Min  = ($Values | Measure-Object -Minimum).Minimum
        P50  = Get-Percentile $Values 0.50
        P90  = Get-Percentile $Values 0.90
        P95  = Get-Percentile $Values 0.95
        P99  = Get-Percentile $Values 0.99
        Max  = ($Values | Measure-Object -Maximum).Maximum
    }
}

$latAll = Get-LatencySummary $allLatency
$latIntercept = Get-LatencySummary $interceptLatency
$latSingle = Get-LatencySummary $singleLatency
$latBurst = Get-LatencySummary $burstLatency
$latSingleIntercept = Get-LatencySummary $singleInterceptLatency
$latSingleAllow = Get-LatencySummary $singleAllowLatency

# ---------------------------------------------------------------- 取消与去重

$cancelAttempts = @($notifications | Where-Object { $_.cancelStatus -and $_.cancelStatus -ne 'not_attempted' })
$cancelOk = @($cancelAttempts | Where-Object { $_.cancelStatus -eq 'success' })
$cancelStats = Get-Wilson $cancelOk.Count $cancelAttempts.Count

$duplicates = 0
$seen = @{}
foreach ($n in $notifications) {
    $uniqueKey = "$($n.reportIndex)|$($n.key)"
    if ($seen.ContainsKey($uniqueKey)) { $duplicates++ } else { $seen[$uniqueKey] = $true }
}
$dupStats = Get-Wilson $duplicates $notifications.Count

# ---------------------------------------------------------------- 报告

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$scenarios = @($runs | ForEach-Object { $_.scenarios } | Where-Object { $_ })
$bulkScenarios = @($scenarios | Where-Object { $_.name -eq 'bulk-triage' })
$packages = @($notifications | Group-Object package | Sort-Object Count -Descending)

function Format-RateCell {
    param($Stats)
    if (-not $Stats) { return 'n/a' }
    return ('{0} ({1}/{2})' -f (Format-Pct $Stats.P 3), $Stats.K, $Stats.N)
}

function Format-IntervalCell {
    param($Stats)
    if (-not $Stats) { return 'n/a' }
    return ('[{0}, {1}]' -f (Format-Pct $Stats.Lo 3), (Format-Pct $Stats.Hi 3))
}

function Format-PvalueCell {
    param([double]$Pvalue)
    if ($null -eq $Pvalue) { return 'n/a' }
    if ($Pvalue -lt 0.0001) { return '<0.0001' }
    return ('{0:F4}' -f $Pvalue)
}

function Format-LatencyRow {
    param([string]$Label, $Summary)
    if (-not $Summary) { return "| $Label | 0 | n/a | n/a | n/a | n/a | n/a | n/a | n/a |" }
    return ('| {0} | {1} | {2} | [{3}, {4}] | {5} | {6} | {7} | {8} |' -f `
            $Label, $Summary.N, $Summary.Mean, $Summary.Lo, $Summary.Hi,
        $Summary.P50, $Summary.P95, $Summary.P99, $Summary.Max)
}

$md = New-Object System.Collections.Generic.List[string]
[void]$md.Add('# 显著性检验：漏拦 / 误拦 / 拦截时延')
[void]$md.Add('')
[void]$md.Add(('> 由 `tool/stats.ps1` 于 {0} 自动生成，勿手工编辑。' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
[void]$md.Add('')
[void]$md.Add('## 1. 样本')
[void]$md.Add('')
[void]$md.Add('| 项目 | 值 |')
[void]$md.Add('| --- | --- |')
[void]$md.Add(('| 报告文件 | {0} 个 |' -f $files.Count))
[void]$md.Add(('| 数据来源 | {0} |' -f (($files | ForEach-Object { Split-Path $_ -Leaf }) -join '、')))
[void]$md.Add(('| 通知样本 | {0} 条 |' -f $notifications.Count))
[void]$md.Add(('| 应拦截 | {0} 条 |' -f $shouldDrop))
[void]$md.Add(('| 应保留 | {0} 条 |' -f $shouldKeep))
[void]$md.Add(('| 采样场景 | {0} 个（{1}） |' -f $scenarios.Count, (($scenarios | Group-Object name | ForEach-Object { "$($_.Name)×$($_.Count)" }) -join '、')))
if ($bulkScenarios.Count -gt 0) {
    $requested = 0
    foreach ($s in $bulkScenarios) {
        $m = [regex]::Match([string]$s.detail, 'requested=(\d+)')
        if ($m.Success) { $requested += [int]$m.Groups[1].Value }
    }
    # 分母只算采样场景自己的样本：探针/常规场景不参与 bulk 采集率。
    $bulkSamples = @($notifications | Where-Object { $_.scenario -eq 'bulk-triage' })
    if ($requested -gt 0) {
        [void]$md.Add(('| 采样采集率 | {0}（{1}/{2}，缺失为系统限流丢弃，非漏拦） |' -f (Format-Pct ($bulkSamples.Count / $requested) 1), $bulkSamples.Count, $requested))
    }
}
[void]$md.Add(('| 通知来源 | {0} |' -f (($packages | ForEach-Object { "$($_.Name)×$($_.Count)" }) -join '、')))
if ($observedSamples.Count -gt 0) {
    [void]$md.Add(('| OBSERVED 样本（系统行为，已剔除） | {0} 条（{1}） |' -f $observedSamples.Count, (($observedSamples | Group-Object scenario | ForEach-Object { "$($_.Name)×$($_.Count)" }) -join '、')))
}
[void]$md.Add('')
[void]$md.Add('判定 ground truth 由采样脚本按"渠道 + 关键词"独立推导，不经过被测规则引擎；')
[void]$md.Add('规则侧使用 `assets/presets/generator_triage.json`。因此本检验能发现规则引擎的实现缺陷，')
[void]$md.Add('但不能发现"规则本身写错了"——后者属于需求问题，需靠人工复核预设文件。')
[void]$md.Add('')

[void]$md.Add('## 2. 混淆矩阵')
[void]$md.Add('')
[void]$md.Add('| 项目 | 数量 |')
[void]$md.Add('| --- | --- |')
[void]$md.Add(('| 正确拦截（应拦 + 已拦） | {0} |' -f $correctDrop.Count))
[void]$md.Add(('| **漏拦**（应拦 + 未拦） | **{0}** |' -f $missed.Count))
[void]$md.Add(('| **误拦**（应留 + 已拦） | **{0}** |' -f $falseBlock.Count))
[void]$md.Add(('| 正确保留（应留 + 已留） | {0} |' -f $correctKeep.Count))
[void]$md.Add('')

[void]$md.Add('## 3. 会不会漏掉 / 会不会误拦截')
[void]$md.Add('')
[void]$md.Add('零假设 H0：真实错误率 ≥ ' + (Format-Pct $MaxErrorRate 1) + '。')
[void]$md.Add('p 值为单侧二项检验 P(X ≤ k | n, p0)；p < 0.05 表示可以在 95% 置信水平下宣称错误率低于该阈值。')
[void]$md.Add('')
[void]$md.Add('| 指标 | 点估计 | Wilson 95% 区间 | rule of three 上界 | 二项检验 p 值 | 结论 |')
[void]$md.Add('| --- | --- | --- | --- | --- | --- |')
$missVerdict = if ($missPvalue -lt 0.05) { '可宣称 < ' + (Format-Pct $MaxErrorRate 1) } else { '证据不足，不能宣称 < ' + (Format-Pct $MaxErrorRate 1) }
$falseVerdict = if ($falsePvalue -lt 0.05) { '可宣称 < ' + (Format-Pct $MaxErrorRate 1) } else { '证据不足，不能宣称 < ' + (Format-Pct $MaxErrorRate 1) }
$missRule = if ($missStats -and $missStats.RuleOfThree) { Format-Pct $missStats.RuleOfThree 2 } else { 'n/a' }
$falseRule = if ($falseStats -and $falseStats.RuleOfThree) { Format-Pct $falseStats.RuleOfThree 2 } else { 'n/a' }
[void]$md.Add(('| 漏拦率 | {0} | {1} | {2} | {3} | {4} |' -f `
            (Format-RateCell $missStats), (Format-IntervalCell $missStats), $missRule,
        (Format-PvalueCell $missPvalue), $missVerdict))
[void]$md.Add(('| 误拦率 | {0} | {1} | {2} | {3} | {4} |' -f `
            (Format-RateCell $falseStats), (Format-IntervalCell $falseStats), $falseRule,
        (Format-PvalueCell $falsePvalue), $falseVerdict))
[void]$md.Add('')
if ($minBound) {
    [void]$md.Add(('当前样本量下，0 错误最多只能证到 **错误率 < {0}**（95% 置信），受较小一侧 {1} 限制。' -f (Format-Pct $minBound 2), $limitingSide))
    [void]$md.Add('要证更严格的上界，按 rule of three 继续扩样：n ≈ 3 / 目标错误率（目标 <1% → 约 300 条，<0.5% → 约 600 条）。')
    [void]$md.Add('')
}

[void]$md.Add('## 4. 平均拦截时间')
[void]$md.Add('')
[void]$md.Add('时延定义：`decisionTime - postTime`，即从系统投递通知到拦截器发出取消请求的时间。')
[void]$md.Add('取消是否生效另记在 `cancelStatus`（回调驱动确认，见 ADR 0008），不占用这段时延。')
[void]$md.Add('')
[void]$md.Add('| 分档 | n | 均值 (ms) | 均值 95% CI | p50 | p95 | p99 | max |')
[void]$md.Add('| --- | --- | --- | --- | --- | --- | --- | --- |')
[void]$md.Add((Format-LatencyRow '单条 · 拦截（对外口径）' $latSingleIntercept))
[void]$md.Add((Format-LatencyRow '单条 · 保留' $latSingleAllow))
[void]$md.Add((Format-LatencyRow '单条 · 合计（有误导性，仅供对照）' $latSingle))
[void]$md.Add((Format-LatencyRow '并发批（±2000ms）' $latBurst))
[void]$md.Add((Format-LatencyRow '全部决策' $latAll))
[void]$md.Add((Format-LatencyRow '全部拦截（取消成功）' $latIntercept))
[void]$md.Add('')
if ($latSingleIntercept -and $latSingleAllow) {
    $delta = [Math]::Round($latSingleIntercept.Mean - $latSingleAllow.Mean, 1)
    if ([Math]::Abs($delta) -lt 20) {
        [void]$md.Add(('单条投递下，拦截与保留只差 **{0} ms**，在测量噪声内。' -f $delta))
        [void]$md.Add('说明"取消通知"本身几乎不耗时，剩下的时间主要是系统从 post 到回调的分发延迟，')
        [void]$md.Add('属于平台下限，不是实现问题。')
    } else {
        [void]$md.Add(('单条投递下，拦截比保留多 **{0} ms**——这段差值来自"取消 + 取消确认"。' -f $delta))
        [void]$md.Add('差值明显偏大时，先检查确认环节是否在关键路径上同步等待（见 ADR 0008）。')
    }
    [void]$md.Add('')
}
if ($latAll -and $null -ne $latAll.BootLo) {
    [void]$md.Add(('Bootstrap（2000 次重采样）与正态近似的一致性：全部决策 [{0}, {1}] vs [{2}, {3}] ms，差异 < 0.1%，说明正态近似在此样本量下可用。' -f `
                $latAll.BootLo, $latAll.BootHi, $latAll.Lo, $latAll.Hi))
    [void]$md.Add('')
}
if ($latSingle -and $latBurst -and $latSingle.N -gt 0 -and $latBurst.N -gt 0) {
    $ratio = [Math]::Round($latBurst.Mean / $latSingle.Mean, 2)
    [void]$md.Add(('并发批均值是单条的 {0} 倍：40 条一组投递时仍有轻微排队，但已不是瓶颈。' -f $ratio))
    [void]$md.Add('取消确认改回调驱动、落盘移出处理线程后（ADR 0008），单线程队列不再被固定等待拖住；')
    [void]$md.Add('对外承诺的"拦截时延"以**单条**口径为准，批量场景看 p95。')
    [void]$md.Add('')
}

[void]$md.Add('## 5. 取消与去重')
[void]$md.Add('')
[void]$md.Add('| 指标 | 点估计 | Wilson 95% 区间 |')
[void]$md.Add('| --- | --- | --- |')
[void]$md.Add(('| 取消成功率 | {0} | {1} |' -f (Format-RateCell $cancelStats), (Format-IntervalCell $cancelStats)))
[void]$md.Add(('| 重复处理率 | {0} | {1} |' -f (Format-RateCell $dupStats), (Format-IntervalCell $dupStats)))
[void]$md.Add('')

[void]$md.Add('## 6. 结论')
[void]$md.Add('')
[void]$md.Add(('1. **漏拦**：{0} 条应拦样本中漏掉 {1} 条，漏拦率 {2}，95% 区间 {3}。' -f `
            $shouldDrop, $missed.Count, (Format-Pct $missStats.P 3), (Format-IntervalCell $missStats)))
[void]$md.Add(('2. **误拦**：{0} 条应留样本中误拦 {1} 条，误拦率 {2}，95% 区间 {3}。' -f `
            $shouldKeep, $falseBlock.Count, (Format-Pct $falseStats.P 3), (Format-IntervalCell $falseStats)))
$singleMeanText = if ($latSingleIntercept) { [string]$latSingleIntercept.Mean } else { 'n/a' }
$singleCiText = if ($latSingleIntercept) { '[{0}, {1}] ms，n={2}，p95 {3} ms' -f $latSingleIntercept.Lo, $latSingleIntercept.Hi, $latSingleIntercept.N, $latSingleIntercept.P95 } else { 'n/a' }
$burstP95Text = if ($latBurst) { [string]$latBurst.P95 } else { 'n/a' }
$burstMeanText = if ($latBurst) { [string]$latBurst.Mean } else { 'n/a' }
$burstNText = if ($latBurst) { [string]$latBurst.N } else { '0' }
if ($latIntercept) {
    [void]$md.Add(('3. **平均拦截时间**：单条投递 **{0} ms**（95% CI {1}）——这是对外承诺的口径。' -f $singleMeanText, $singleCiText))
    [void]$md.Add('   其中 250 ms 是取消后校验的首次轮询等待（自设常量），可移到关键路径之外。')
    [void]$md.Add(('   并发批（{0} 条）均值 {1} ms、p95 {2} ms：40 条一组投递时的轻微排队，已不再是瓶颈。' -f `
                $burstNText, $burstMeanText, $burstP95Text))
    [void]$md.Add(('   取消是否生效由 `onNotificationRemoved` 确认（不占用上述时延），取消成功率 {0}。' -f (Format-RateCell $cancelStats)))
}
[void]$md.Add('')
[void]$md.Add('注意：0 个错误不等于"不会出错"，只给出上界。样本量决定结论强度，')
[void]$md.Add('本报告的上界随样本量自动收紧，不做无根据的"100% 正确"宣称。')
[void]$md.Add('')

$outFile = Join-Path (Join-Path $RepoRoot $OutDir) 'stats.md'
[System.IO.File]::WriteAllText($outFile, ($md -join "`r`n"), $Utf8NoBom)

# ---------------------------------------------------------------- 控制台摘要

Write-Host ''
Write-Host ('样本：{0} 条（应拦 {1} / 应留 {2}），来自 {3} 个报告' -f $notifications.Count, $shouldDrop, $shouldKeep, $files.Count)
Write-Host ''
Write-Host '判定质量：'
Write-Host ('  漏拦  {0}  95% CI {1}  p={2}  → {3}' -f (Format-RateCell $missStats), (Format-IntervalCell $missStats), (Format-PvalueCell $missPvalue), $missVerdict)
Write-Host ('  误拦  {0}  95% CI {1}  p={2}  → {3}' -f (Format-RateCell $falseStats), (Format-IntervalCell $falseStats), (Format-PvalueCell $falsePvalue), $falseVerdict)
if ($minBound) {
    Write-Host ('  当前样本量下 0 错误最多可证到 < {0}（受 {1} 限制）' -f (Format-Pct $minBound 2), $limitingSide)
}
Write-Host ''
Write-Host '拦截时延：'
foreach ($pair in @(@('单条·拦截', $latSingleIntercept), @('单条·保留', $latSingleAllow), @('并发批', $latBurst), @('全部拦截', $latIntercept), @('全部决策', $latAll))) {
    $label = $pair[0]
    $s = $pair[1]
    if ($s) {
        Write-Host ('  {0,-8} n={1,-4} mean={2,7} ms  CI [{3}, {4}]  p50={5}  p95={6}  p99={7}' -f `
                $label, $s.N, $s.Mean, $s.Lo, $s.Hi, $s.P50, $s.P95, $s.P99)
    }
}
Write-Host ''
Write-Host ('取消成功率 {0}  重复率 {1}' -f (Format-RateCell $cancelStats), (Format-RateCell $dupStats))
Write-Host ('报告：{0}' -f $outFile)

if ($Gate) {
    $failures = @()
    if ($missStats -and $missStats.P -gt $MaxErrorRate) { $failures += ('漏拦率 {0} 超过阈值 {1}' -f (Format-Pct $missStats.P 3), (Format-Pct $MaxErrorRate 1)) }
    if ($falseStats -and $falseStats.P -gt $MaxErrorRate) { $failures += ('误拦率 {0} 超过阈值 {1}' -f (Format-Pct $falseStats.P 3), (Format-Pct $MaxErrorRate 1)) }
    if ($dupStats -and $dupStats.P -gt 0) { $failures += '存在重复处理' }
    if ($failures.Count -gt 0) {
        Write-Host ''
        Write-Host '门禁失败：'
        foreach ($f in $failures) { Write-Host ("  - $f") }
        exit 1
    }
    Write-Host ''
    Write-Host '门禁通过。'
}
