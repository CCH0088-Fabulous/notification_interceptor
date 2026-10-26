# 端到端验收脚本：在真机/模拟器上跑真实通知场景。
#
# 前置：
#   flutter build apk --debug
#   cd android; .\gradlew.bat :probe:assembleDebug :generator:assembleDebug
#
# 用法：
#   .\tool\e2e.ps1                 # 全量场景（13 个）
#   .\tool\e2e.ps1 -Only burst-10  # 只跑一个
#   .\tool\e2e.ps1 -Only generator-triage
#   .\tool\e2e.ps1 -IncludeReboot  # 额外验证重启后规则仍生效
#   .\tool\e2e.ps1 -SkipInstall    # 复用已安装包（不重装主应用/探针/生成器）
#   .\tool\e2e.ps1 -Only bulk-triage -Bulk 800            # 大批量采样（判定质量）
#   .\tool\e2e.ps1 -Only bulk-triage -Bulk 60 -BulkRound 1 # 单条节奏采样（时延口径）
param(
    [string]$Adb = 'D:\Android_SDK\platform-tools\adb.exe',
    [string]$App = 'dev.poc.notifinterceptor',
    [string]$Probe = 'dev.poc.probe',
    [string]$Generator = 'dev.poc.notifgen',
    [string]$AppApk = 'build\app\outputs\flutter-apk\app-debug.apk',
    [string]$ProbeApk = 'build\probe\outputs\apk\debug\probe-debug.apk',
    [string]$GeneratorApk = 'build\generator\outputs\apk\debug\generator-debug.apk',
    [switch]$SkipInstall,
    [switch]$IncludeReboot,
    [string]$Only,
    # 大批量采样：为显著性检验积累样本（只发通知+收集记录，不断言）。0 表示不采样。
    [int]$Bulk = 0,
    # 每轮投递条数。1 = 单条节奏，用来测"没有队列积压时的判定时延"。
    [int]$BulkRound = 40
)

$ErrorActionPreference = 'Stop'
$script:results = New-Object System.Collections.ArrayList
# 逐条通知的量化记录 + 每个场景的系统事件统计，最后写成 e2e-<stamp>.json 供 metrics.ps1 复算。
$script:records = New-Object System.Collections.ArrayList
$script:eventStats = New-Object System.Collections.ArrayList
# 响铃专项用例（alert-sound）：每条用例一次受控测量。
$script:alertCases = New-Object System.Collections.ArrayList
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

function Adb {
    # 不声明形参：否则 adb 的 -c、-n 等会被当成函数的命名参数。
    $ErrorActionPreference = 'Continue'
    $out = & $AdbPath @args 2>&1
    return @($out | ForEach-Object { "$_" })
}

$AdbPath = $Adb

function Assert-Device {
    $devices = (Adb devices) | Where-Object { $_ -match '\tdevice$' }
    if (-not $devices) { throw "没有可用设备，请先启动模拟器或连接真机。" }
}

function Assert-Listener {
    param([bool]$Enabled)
    $component = "$App/$App.listener.NotificationInterceptorService"
    $current = ((Adb shell settings get secure enabled_notification_listeners) -join ':').Trim()
    $parts = @()
    if ($current) { $parts = $current -split ':' | Where-Object { $_ -and $_ -ne $component } }
    if ($Enabled) { $parts += $component }
    Adb shell settings put secure enabled_notification_listeners ($parts -join ':') | Out-Null
    Start-Sleep -Milliseconds 800
}

function Set-Rules {
    param([object]$RuleSet)
    $json = $RuleSet | ConvertTo-Json -Depth 12 -Compress
    $local = Join-Path $env:TEMP "notif_rules.json"
    [System.IO.File]::WriteAllText($local, $json, $Utf8NoBom)
    Adb push $local /data/local/tmp/notif_rules.json | Out-Null
    Adb shell "cat /data/local/tmp/notif_rules.json | run-as $App sh -c 'cat > files/rules.json'" | Out-Null
    Start-Sleep -Milliseconds 300
}

function New-RuleSet {
    param(
        [string[]]$Packages = @(),
        [string[]]$Keywords = @(),
        [string]$TitleRegex,
        [string]$Action = 'intercept',
        [bool]$GlobalEnabled = $true
    )
    $match = @{
        mode        = 'all'
        packages    = @($Packages)
        keywordsAny = @($Keywords)
        titleRegex  = $TitleRegex
        textRegex   = $null
        channelIds  = @()
        isOngoing   = $null
        isClearable = $null
        quietHours  = $null
    }
    return @{
        schemaVersion = 1
        globalEnabled = $GlobalEnabled
        defaultAction = 'allow'
        rules         = @(
            @{
                id      = 'e2e-rule'
                name    = 'e2e'
                enabled = $true
                action  = $Action
                match   = $match
            }
        )
    }
}

function Get-HistoryRaw {
    $lines = Adb shell run-as $App cat files/history.jsonl
    $entries = @()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $entries += ($line | ConvertFrom-Json) } catch { }
    }
    return $entries
}

function Get-DeviceMillis {
    # 用设备时钟切时间窗：主机与设备的时钟不一定对齐，历史条目里的时间戳是设备时间。
    $raw = ((Adb shell date +%s%3N) -join '').Trim()
    $value = 0L
    if ([long]::TryParse($raw, [ref]$value)) { return $value }
    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Get-NewEntries {
    param([long]$Since, [string]$Package = $Probe)
    $all = Get-HistoryRaw
    # 排除系统自动生成的汇总条目（tag 为 0、key 含 g:Aggregate），
    # 但保留应用自己发出的 summary（tag 有实际值），group-summary 场景要用到它。
    return @($all | Where-Object {
            $_.snapshot.packageName -eq $Package -and
            $_.snapshot.postTime -ge $Since -and
            (Get-NotificationTag $_.snapshot.key) -ne '0' -and
            $_.snapshot.key -notmatch '\|g:'
        })
}

function Wait-NewEntries {
    param([long]$Since, [string]$Package = $Probe, [int]$TimeoutSeconds = 10, [int]$AtLeast = 1)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $new = @(Get-NewEntries -Since $Since -Package $Package)
        if ($new.Count -ge $AtLeast) { return $new }
        Start-Sleep -Milliseconds 400
    }
    return @()
}

# 等应用首帧完成。Debug 构建 + 冷启动在这台模拟器上实测要 40 秒以上，
# 未等待就断言会把"启动中"误判成"不工作"。
function Start-AppAndWait {
    param([int]$TimeoutSeconds = 120)
    Adb shell am start -n "$App/.MainActivity" | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        # API 36 的 dumpsys 用 topResumedActivity；老版本用 mResumedActivity。
        $bundle = (Adb shell dumpsys activity activities) -join "`n"
        if ($bundle -match "(?:topResumedActivity|mResumedActivity)[^\n]*$([regex]::Escape($App))/") {
            return $true
        }
        Start-Sleep -Milliseconds 1000
    }
    return $false
}

# 预热：让服务完成一次真实的投递→判定→入库，之后的断言才有稳定基线。
function Invoke-WarmUp {
    param([object]$Rules, [int]$TimeoutSeconds = 45)
    Set-Rules $Rules
    $since = Get-DeviceMillis
    Send-Probe -Scenario basic -Tag e2e_warmup -Title '预热' -Text 'warmup'
    $new = @(Wait-NewEntries -Since $since -TimeoutSeconds $TimeoutSeconds)
    Adb shell am broadcast -n "$Probe/.ProbeReceiver" -a "$Probe.CLEAR" | Out-Null
    return $new.Count -gt 0
}

function Send-Probe {
    param([string]$Scenario, [string]$Tag, [string]$Title, [string]$Text, [int]$Id = 2001, [int]$Count = 1)
    Adb shell am broadcast -n "$Probe/.ProbeReceiver" -a "$Probe.POST" `
        --es scenario $Scenario --es tag $Tag --es title $Title --es text $Text `
        --ei id $Id --ei count $Count | Out-Null
}

function Get-ProbeTags {
    # 轮询到探针输出统计行（COUNT）为止：设备繁忙时 900ms 可能还没跑完广播。
    param([int]$TimeoutSeconds = 10)
    Adb logcat -c | Out-Null
    Adb shell am broadcast -n "$Probe/.ProbeReceiver" -a "$Probe.VERIFY" | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $present = @{}
    $finishedAt = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $present = @{}
        $finished = $false
        foreach ($line in (Adb logcat -d -s ProbeApp)) {
            if ($line -match 'PROBE\|verify\|([^|]+)\|PRESENT\|id=(\d+)') {
                $present[$matches[1]] = [int]$matches[2]
            }
            if ($line -match 'PROBE\|verify\|.+\|COUNT\|') { $finished = $true }
        }
        # 统计行出现后再多读一轮，确保日志已完整落盘。
        if ($finished) {
            if ($finishedAt) { break }
            $finishedAt = Get-Date
        }
    }
    return $present
}

# 生成器当前留在通知栏的 tag → 类别。只统计 tag 以 gen_ 开头的（系统聚合通知除外）。
function Get-GeneratorTags {
    param([int]$TimeoutSeconds = 10)
    Adb logcat -c | Out-Null
    Adb shell am broadcast -n "$Generator/.GenReceiver" -a "$Generator.VERIFY" | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $present = @{}
    $finishedAt = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $present = @{}
        $finished = $false
        foreach ($line in (Adb logcat -d -s NotifGen)) {
            if ($line -match 'GEN\|present\|(gen_[^|]+)\|([^|]+)\|id=(\d+)') {
                $present[$matches[1]] = $matches[2]
            }
            if ($line -match 'GEN\|verify\|.+\|COUNT\|') { $finished = $true }
        }
        if ($finished) {
            if ($finishedAt) { break }
            $finishedAt = Get-Date
        }
    }
    return $present
}

# 把仓库里的预设 JSON 直接写到设备上的规则文件（与 UI 的“导入分流规则”用的是同一份）。
function Set-RulesFile {
    param([string]$RelativePath)
    $local = Join-Path $RepoRoot $RelativePath
    if (-not (Test-Path $local)) { throw "规则文件不存在：$RelativePath" }
    Adb push $local /data/local/tmp/notif_rules.json | Out-Null
    Adb shell "cat /data/local/tmp/notif_rules.json | run-as $App sh -c 'cat > files/rules.json'" | Out-Null
    Start-Sleep -Milliseconds 400
}

# history key 形如 `0|pkg|id|tag|uid`，tag 在第四段。
function Get-NotificationTag {
    param([string]$Key)
    $parts = $Key -split '\|'
    if ($parts.Count -ge 4) { return $parts[3] }
    return ''
}

# 一条通知的量化记录：期望 vs 实际、时延、规则、取消结果。
function Add-Record {
    param([string]$Scenario, $Entry, [string]$Expected)
    $snapshot = $Entry.snapshot
    $tag = Get-NotificationTag $snapshot.key
    # 系统自动分组的汇总条目（tag 为 0 / key 含 g:Aggregate）不是真实投递，统计时排除。
    if ($snapshot.isGroupSummary -or $tag -eq '0' -or $snapshot.key -match '\|g:') { return }
    [void]$script:records.Add([pscustomobject]@{
            scenario     = $Scenario
            key          = $snapshot.key
            tag          = $tag
            package      = $snapshot.packageName
            channelId    = $snapshot.channelId
            isOngoing    = [bool]$snapshot.isOngoing
            isClearable  = [bool]$snapshot.isClearable
            expected     = $Expected
            action       = $Entry.action
            cancelStatus = $Entry.cancelStatus
            ruleId       = $Entry.matchedRuleId
            postTime     = [long]$snapshot.postTime
            decisionTime = [long]$Entry.timestamp
            latencyMs    = [long]($Entry.timestamp - $snapshot.postTime)
        })
}

# 系统 EventLog 是"是否真的响铃"的权威来源：
#   notification_alert: [key,user,aboveThreshold,?,?,flag]
#   aboveThreshold=1        → 真的打扰（响铃/震动）
#   aboveThreshold=0,2048   → 同批合并被系统抑制
#   aboveThreshold=0,0      → 低于打扰阈值（如 IMPORTANCE_LOW）
function Get-EventStats {
    param([string]$Package = $null)
    $lines = Adb logcat -b events -d
    $enqueued = 0
    $alerted = 0
    $coalesced = 0
    $suppressedOther = 0
    $belowThreshold = 0
    $cancelledByIc = 0
    foreach ($line in $lines) {
        if ($line -notmatch 'notification_(enqueue|alert|canceled)') { continue }
        if ($Package -and $line -notmatch [regex]::Escape($Package)) { continue }

        if ($line -match 'notification_enqueue') {
            # 系统自动分组的汇总通知（tag 形如 `0|pkg|g:Aggregate_...`）不算一条真实投递。
            if ($line -notmatch 'g:Aggregate') { $enqueued++ }
            continue
        }
        if ($line -match 'notification_canceled') {
            if ($line -match 'NotificationInterceptorService') { $cancelledByIc++ }
            continue
        }
        $m = [regex]::Match($line, 'notification_alert: \[[^\]]*?,(\d+),(\d+),(\d+),(\d+),(-?\d+)\]')
        if (-not $m.Success) { continue }
        if ($m.Groups[2].Value -eq '1') { $alerted++ }
        elseif ($m.Groups[5].Value -eq '2048') { $coalesced++ }
        elseif ($m.Groups[5].Value -ne '0') { $suppressedOther++ }
        else { $belowThreshold++ }
    }
    return [pscustomobject]@{
        enqueued        = $enqueued
        alerted         = $alerted
        coalesced       = $coalesced
        suppressedOther = $suppressedOther
        belowThreshold  = $belowThreshold
        cancelledByIc   = $cancelledByIc
    }
}

function Add-EventStats {
    param([string]$Scenario, [string]$Package)
    $stats = Get-EventStats -Package $Package
    [void]$script:eventStats.Add([pscustomobject]@{
            scenario        = $Scenario
            enqueued        = $stats.enqueued
            alerted         = $stats.alerted
            coalesced       = $stats.coalesced
            suppressedOther = $stats.suppressedOther
            belowThreshold  = $stats.belowThreshold
            cancelledByIc   = $stats.cancelledByIc
        })
    return $stats
}

# 响铃专项用例：清空托盘 → 静默等待 UI 稳定 → 只发一条并读系统事件。
# 托盘必须先清空，否则新通知会并入已有同应用分组，被判定为"更新"而不再打扰。
function Measure-Alert {
    param(
        [string]$Name,
        [string]$Description,
        [object]$Rules,
        [string]$Sender,            # 'probe' 或 'generator'
        [string]$Scenario = 'basic',
        [int]$Count = 1,
        [long]$GapMs = 0,
        [switch]$Loud,
        [int]$QuietSeconds = 8,
        [int]$SettleSeconds = 4
    )

    if ($Sender -eq 'generator') {
        Adb shell am broadcast -n "$Generator/.GenReceiver" -a "$Generator.CLEAR" | Out-Null
    } else {
        Adb shell am broadcast -n "$Probe/.ProbeReceiver" -a "$Probe.CLEAR" | Out-Null
    }
    # 系统对同一应用的连续通知会抑制打扰（实测连发第 2 条会被抑制），
    # 因此必须先静默一段时间，否则测到的是系统的抑制策略而不是我们的行为。
    Start-Sleep -Seconds $QuietSeconds
    Set-Rules $Rules
    Adb logcat -b events -c | Out-Null

    if ($Sender -eq 'generator') {
        $extra = ''
        if ($Loud) { $extra = ' --ez loud true' }
        Adb shell "am broadcast -n $Generator/.GenReceiver -a $Generator.POST --ei count $Count --el delay $GapMs$extra" | Out-Null
    } else {
        Adb shell am broadcast -n "$Probe/.ProbeReceiver" -a "$Probe.POST" `
            --es scenario $Scenario --es tag "alert_$Name" --es title '秒杀提醒' --es text '响铃测试' `
            --ei count $Count --el delay $GapMs | Out-Null
    }

    Start-Sleep -Seconds $SettleSeconds
    $stats = Get-EventStats -Package $(if ($Sender -eq 'generator') { $Generator } else { $Probe })
    [void]$script:alertCases.Add([pscustomobject]@{
            name            = $Name
            description     = $Description
            sender          = $Sender
            count           = $Count
            gapMs           = $GapMs
            loud            = [bool]$Loud
            enqueued        = $stats.enqueued
            alerted         = $stats.alerted
            coalesced       = $stats.coalesced
            suppressedOther = $stats.suppressedOther
            belowThreshold  = $stats.belowThreshold
            cancelledByIc   = $stats.cancelledByIc
        })
    return $stats
}

# 记录"是否可听"的三个环境量：响铃依赖音量/勿扰/铃声模式，不记就不可解释。
function Get-SoundContext {
    $volume = $null
    $maxVolume = $null
    $line = (Adb shell cmd media_session volume --stream 5 --get) -join ' '
    $m = [regex]::Match($line, 'volume is (\d+) in range \[0\.\.(\d+)\]')
    if ($m.Success) {
        $volume = [int]$m.Groups[1].Value
        $maxVolume = [int]$m.Groups[2].Value
    }
    $zen = ((Adb shell settings get global zen_mode) -join '').Trim()
    $ringer = ((Adb shell settings get global mode_ringer) -join '').Trim()
    return [pscustomobject]@{
        notificationVolume = $volume
        notificationVolumeMax = $maxVolume
        zenMode            = $zen
        ringerMode         = $ringer
    }
}

function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail, [double]$Seconds)
    [void]$script:results.Add([pscustomobject]@{
            Name    = $Name
            Status  = $Status
            Detail  = $Detail
            Seconds = [math]::Round($Seconds, 2)
        })
    $mark = if ($Status -eq 'PASS') { 'PASS' } elseif ($Status -eq 'OBSERVED') { 'OBSV' } else { 'FAIL' }
    Write-Host ("[{0}] {1} — {2}" -f $mark, $Name, $Detail)
}

function Invoke-Scenario {
    param(
        [string]$Name,
        [object]$Rules,
        [string]$Scenario,
        [string]$Tag,
        [string]$Title = '秒杀提醒',
        [string]$Text = '限时优惠',
        [string]$ExpectAction = 'intercept',
        [bool]$ExpectPresent = $false,
        [int]$TimeoutSeconds = 10
    )

    if ($Only -and $Only -ne $Name) { return }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Set-Rules $Rules
    # 清空托盘再发：否则新通知会并入已有的同应用分组，系统判定为更新而不再打扰，
    # "有没有响"就测不准（实测同一场景清空后必然响 1 次）。
    Adb shell am broadcast -n "$Probe/.ProbeReceiver" -a "$Probe.CLEAR" | Out-Null
    Start-Sleep -Milliseconds 500
    $since = Get-DeviceMillis
    Adb logcat -c | Out-Null
    Adb logcat -b events -c | Out-Null
    Send-Probe -Scenario $Scenario -Tag $Tag -Title $Title -Text $Text
    $new = @(Wait-NewEntries -Since $since -TimeoutSeconds $TimeoutSeconds)
    $present = Get-ProbeTags
    $expected = if ($ExpectAction -eq 'intercept') { 'drop' } else { 'keep' }
    foreach ($entry in $new) { Add-Record -Scenario $Name -Entry $entry -Expected $expected }
    Add-EventStats -Scenario $Name -Package $Probe
    $watch.Stop()

    if ($new.Count -eq 0) {
        Add-Result $Name 'FAIL' '通知未进入历史（服务未处理？）' $watch.Elapsed.TotalSeconds
        return
    }

    $entry = $new[0]
    $actualPresent = $present.ContainsKey($Tag)
    $actionOk = $entry.action -eq $ExpectAction
    $presenceOk = $actualPresent -eq $ExpectPresent
    $cancelOk = $true
    if ($ExpectAction -eq 'intercept') {
        $cancelOk = $entry.cancelStatus -eq 'success'
    }

    $detail = ("action={0} cancel={1} present={2} latency={3}ms" -f `
            $entry.action, $entry.cancelStatus, $actualPresent, ($entry.timestamp - $entry.snapshot.postTime))

    if ($actionOk -and $presenceOk -and $cancelOk) {
        Add-Result $Name 'PASS' $detail $watch.Elapsed.TotalSeconds
    } else {
        Add-Result $Name 'FAIL' $detail $watch.Elapsed.TotalSeconds
    }
}

function Invoke-ObserveScenario {
    param(
        [string]$Name,
        [object]$Rules,
        [string]$Scenario,
        [string]$Tag,
        [string]$Title = '秒杀提醒'
    )
    if ($Only -and $Only -ne $Name) { return }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Set-Rules $Rules
    Adb shell am broadcast -n "$Probe/.ProbeReceiver" -a "$Probe.CLEAR" | Out-Null
    Start-Sleep -Milliseconds 500
    $since = Get-DeviceMillis
    Adb logcat -b events -c | Out-Null
    Send-Probe -Scenario $Scenario -Tag $Tag -Title $Title -Text '限时优惠'
    $new = @(Wait-NewEntries -Since $since)
    $present = Get-ProbeTags
    foreach ($entry in $new) { Add-Record -Scenario $Name -Entry $entry -Expected 'drop' }
    Add-EventStats -Scenario $Name -Package $Probe
    $watch.Stop()

    if ($new.Count -eq 0) {
        Add-Result $Name 'FAIL' '通知未进入历史' $watch.Elapsed.TotalSeconds
        return
    }
    $entry = $new[0]
    $detail = ("action={0} cancel={1} stillPresent={2}" -f `
            $entry.action, $entry.cancelStatus, $present.ContainsKey($Tag))
    Add-Result $Name 'OBSERVED' $detail $watch.Elapsed.TotalSeconds
}

# ---------------------------------------------------------------- 环境准备

Assert-Device
if (-not $SkipInstall) {
    Write-Host '安装应用、探针与生成器…'
    Adb install -r $AppApk | Out-Null
    Adb install -r $ProbeApk | Out-Null
    Adb install -r $GeneratorApk | Out-Null
}
Adb shell pm grant $Probe android.permission.POST_NOTIFICATIONS | Out-Null
Adb shell pm grant $Generator android.permission.POST_NOTIFICATIONS | Out-Null
Assert-Listener -Enabled $true
# 清掉遗留通知，避免 presence 判定被旧数据污染
Adb shell am broadcast -n "$Probe/.ProbeReceiver" -a "$Probe.CLEAR" | Out-Null
Adb shell cmd notification post -t cleanup cleanup_tag cleanup 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

$interceptRules = New-RuleSet -Packages @($Probe) -Keywords @('秒杀')
$allowRules = New-RuleSet -Packages @('com.example.not.installed') -Keywords @('不存在')

# 预热：冷启动 + 首次投递可能耗时几十秒，先跑一轮再开始断言。
# 服务是否"就绪"只能用功能性判据：真的收到一条通知并入库。
Write-Host '预热应用与服务…'
if (-not (Start-AppAndWait)) { Write-Host '警告：应用首帧等待超时' }
Adb shell input keyevent KEYCODE_HOME | Out-Null
Start-Sleep -Seconds 1
if (-not (Invoke-WarmUp -Rules $interceptRules)) {
    Write-Host '首次预热失败，重新绑定监听器后重试…'
    Assert-Listener -Enabled $false
    Start-Sleep -Seconds 1
    Assert-Listener -Enabled $true
    if (-not (Invoke-WarmUp -Rules $interceptRules)) {
        throw '监听服务未就绪：预热阶段没有收到任何历史条目，请检查通知使用权与规则文件。'
    }
}
Write-Host '预热完成'

Write-Host ''
Write-Host '=== 场景执行 ==='

# 大批量采样：为显著性检验积累样本。只发通知、只收集记录，不做断言。
# 规则用与 generator-triage 相同的白名单预设，ground truth 来自渠道/关键词，不来自被测代码。
if ($Bulk -gt 0 -and (-not $Only -or $Only -eq 'bulk-triage')) {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $roundSize = [Math]::Max(1, $BulkRound)
    $rounds = [int][Math]::Ceiling($Bulk / $roundSize)
    $keepChannels = @('gen_code', 'gen_bank', 'gen_logistics', 'gen_calendar', 'gen_chat', 'gen_group')
    $keywords = @('验证码', '入账', '取件码', '会议')

    Set-RulesFile 'assets\presets\generator_triage.json'
    # 历史上限 1000 条且按最新保留：旧数据会把新样本挤出窗口，
    # 也会让每轮的全量读取变慢。采样前必须清空（truncate 比 shell 重定向可靠）。
    Adb shell "run-as $App truncate -s 0 files/history.jsonl" | Out-Null
    Adb shell am broadcast -n "$Generator/.GenReceiver" -a "$Generator.CLEAR" | Out-Null
    Start-Sleep -Milliseconds 800

    $samples = New-Object System.Collections.Generic.List[object]
    $requested = 0
    $zeroRounds = 0
    Write-Host ("批量采样：目标 {0} 条（{1} 轮 × 最多 {2} 条）" -f $Bulk, $rounds, $roundSize)
    for ($r = 1; $r -le $rounds; $r++) {
        $want = [Math]::Min($roundSize, $Bulk - $requested)
        if ($want -le 0) { break }
        # 每轮独立开窗：查询量恒定在一轮之内，不会被全库扫描拖慢，也不会因轮转丢样本。
        $since = Get-DeviceMillis
        Adb shell am broadcast -n "$Generator/.GenReceiver" -a "$Generator.POST" --ei count $want --el seed $r | Out-Null
        $requested += $want

        $round = @()
        $deadline = (Get-Date).AddSeconds(90)
        $last = -1
        $idle = 0
        while ((Get-Date) -lt $deadline) {
            $round = @(Get-NewEntries -Since $since -Package $Generator |
                    Where-Object { $_.snapshot.channelId -like 'gen_*' -and (Get-NotificationTag $_.snapshot.key) -like 'gen_*' })
            if ($round.Count -ge $want) { break }
            # 系统对单应用有通知速率限制，偶尔会静默丢弃；连续 6 秒无新增即认为本轮封口。
            if ($round.Count -eq $last) { $idle++ } else { $idle = 0 }
            $last = $round.Count
            if ($idle -ge 5) { break }
            Start-Sleep -Milliseconds 1200
        }
        foreach ($item in $round) { $samples.Add($item) }
        Write-Host ("  第 {0}/{1} 轮：{2}/{3}（累计 {4}）" -f $r, $rounds, $round.Count, $want, $samples.Count)
        if ($round.Count -eq 0) { $zeroRounds++ }
        Adb shell am broadcast -n "$Generator/.GenReceiver" -a "$Generator.CLEAR" | Out-Null
        Start-Sleep -Milliseconds 500
    }
    $watch.Stop()

    $uniqueTags = @($samples | ForEach-Object { Get-NotificationTag $_.snapshot.key } | Sort-Object -Unique).Count
    foreach ($entry in $samples) {
        $keep = $entry.snapshot.channelId -in $keepChannels
        if (-not $keep) {
            foreach ($k in $keywords) {
                if ("$($entry.snapshot.title)$($entry.snapshot.text)" -match [regex]::Escape($k)) { $keep = $true; break }
            }
        }
        Add-Record -Scenario 'bulk-triage' -Entry $entry -Expected $(if ($keep) { 'keep' } else { 'drop' })
    }
    $dropped = @($samples | Where-Object { $_.action -eq 'intercept' }).Count
    $kept = $samples.Count - $dropped
    $status = if ($zeroRounds -gt 0) { 'FAIL' } else { 'PASS' }
    Add-Result 'bulk-triage' $status `
    ("samples={0} uniqueTags={1} keep={2} drop={3} requested={4} round={5} zeroRounds={6}" -f `
            $samples.Count, $uniqueTags, $kept, $dropped, $requested, $roundSize, $zeroRounds) `
        $watch.Elapsed.TotalSeconds
}

Invoke-Scenario -Name 'allow-non-matching' -Rules $interceptRules -Scenario basic `
    -Tag e2e_allow -Title '普通消息' -Text '没有关键词' -ExpectAction 'allow' -ExpectPresent $true

Invoke-Scenario -Name 'intercept-basic' -Rules $interceptRules -Scenario basic `
    -Tag e2e_basic -ExpectAction 'intercept' -ExpectPresent $false

Invoke-Scenario -Name 'intercept-silent-channel' -Rules $interceptRules -Scenario silent `
    -Tag e2e_silent -ExpectAction 'intercept' -ExpectPresent $false

Invoke-Scenario -Name 'intercept-messaging' -Rules $interceptRules -Scenario messaging `
    -Tag e2e_msg -ExpectAction 'intercept' -ExpectPresent $false

Invoke-ObserveScenario -Name 'observe-ongoing' -Rules $interceptRules -Scenario ongoing -Tag e2e_ongoing
Invoke-ObserveScenario -Name 'observe-noclear' -Rules $interceptRules -Scenario noclear -Tag e2e_noclear
Invoke-ObserveScenario -Name 'observe-progress' -Rules $interceptRules -Scenario progress -Tag e2e_progress

# 分组：子通知命中，汇总通知不命中
if (-not $Only -or $Only -eq 'group-summary') {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Set-Rules $interceptRules
    Adb shell am broadcast -n "$Probe/.ProbeReceiver" -a "$Probe.CLEAR" | Out-Null
    Start-Sleep -Milliseconds 500
    $since = Get-DeviceMillis
    Send-Probe -Scenario group -Tag e2e_group -Title '秒杀提醒' -Text '分组'
    # 子通知、汇总通知由系统分批投递，轮询到稳定数量再判定。
    $new = @(Wait-NewEntries -Since $since -TimeoutSeconds 15 -AtLeast 3)
    $present = Get-ProbeTags
    foreach ($entry in $new) {
        # 子通知文案带关键词 → 期望拦截；汇总通知不带 → 期望放行
        $expect = if ("$($entry.snapshot.title)$($entry.snapshot.text)" -match '秒杀') { 'drop' } else { 'keep' }
        Add-Record -Scenario 'group-summary' -Entry $entry -Expected $expect
    }
    $watch.Stop()
    $intercepted = @($new | Where-Object { $_.action -eq 'intercept' })
    $allowed = @($new | Where-Object { $_.action -eq 'allow' })
    $ok = ($intercepted.Count -ge 2) -and ($allowed.Count -ge 1) -and $present.ContainsKey('e2e_group')
    $detail = "intercepted={0} allowed={1} summaryPresent={2}" -f `
        $intercepted.Count, $allowed.Count, $present.ContainsKey('e2e_group')
    if ($ok) { Add-Result 'group-summary' 'PASS' $detail $watch.Elapsed.TotalSeconds }
    else { Add-Result 'group-summary' 'FAIL' $detail $watch.Elapsed.TotalSeconds }
}

# 批量：10 条通知的排队延迟与重复处理
if (-not $Only -or $Only -eq 'burst-10') {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Set-Rules $interceptRules
    Adb shell am broadcast -n "$Probe/.ProbeReceiver" -a "$Probe.CLEAR" | Out-Null
    Start-Sleep -Milliseconds 500
    $startTime = Get-DeviceMillis
    Adb logcat -b events -c | Out-Null
    Send-Probe -Scenario burst -Tag e2e_burst -Title '秒杀提醒' -Text '批量' -Count 10
    $new = @()
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $new = @(Get-NewEntries -Since $startTime)
        if ($new.Count -ge 10) {
            # 多等一轮，让可能存在的重复回调暴露出来
            Start-Sleep -Seconds 1
            $new = @(Get-NewEntries -Since $startTime)
            break
        }
        Start-Sleep -Milliseconds 500
    }
    foreach ($entry in $new) { Add-Record -Scenario 'burst-10' -Entry $entry -Expected 'drop' }
    Add-EventStats -Scenario 'burst-10' -Package $Probe
    $watch.Stop()
    $latencies = @($new | ForEach-Object { $_.timestamp - $_.snapshot.postTime })
    $maxLatency = ($latencies | Measure-Object -Maximum).Maximum
    $uniqueIds = @($new | ForEach-Object { $_.snapshot.id } | Sort-Object -Unique)
    $duplicates = $new.Count - $uniqueIds.Count
    $ok = ($uniqueIds.Count -ge 10) -and ($duplicates -eq 0)
    $detail = "entries={0} unique={1} duplicates={2} maxLatency={3}ms total={4}s" -f `
        $new.Count, $uniqueIds.Count, $duplicates, $maxLatency, [math]::Round($watch.Elapsed.TotalSeconds, 1)
    if ($ok) { Add-Result 'burst-10' 'PASS' $detail $watch.Elapsed.TotalSeconds }
    else { Add-Result 'burst-10' 'FAIL' $detail $watch.Elapsed.TotalSeconds }
}

# 界面关闭后仍生效
if (-not $Only -or $Only -eq 'ui-closed') {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Set-Rules $interceptRules
    Adb shell am force-stop $App | Out-Null
    Start-Sleep -Seconds 1
    if (-not (Start-AppAndWait)) { Write-Host '警告：应用首帧等待超时' }
    Adb shell input keyevent KEYCODE_BACK | Out-Null
    Start-Sleep -Seconds 2
    # force-stop 会让监听器解绑，必须先确认服务重新就绪，否则断言的是"环境没起"。
    $ready = Invoke-WarmUp -Rules $interceptRules -TimeoutSeconds 20
    if (-not $ready) {
        Assert-Listener -Enabled $false
        Start-Sleep -Seconds 1
        Assert-Listener -Enabled $true
        $ready = Invoke-WarmUp -Rules $interceptRules -TimeoutSeconds 20
    }
    if (-not $ready) {
        $watch.Stop()
        Add-Result 'ui-closed' 'FAIL' '界面关闭后监听服务未重新绑定（预热无历史条目）' $watch.Elapsed.TotalSeconds
    } else {
        $since = Get-DeviceMillis
        Send-Probe -Scenario basic -Tag e2e_closed -Title '秒杀提醒' -Text '界面已关闭'
        $new = @(Wait-NewEntries -Since $since -TimeoutSeconds 20)
        $present = Get-ProbeTags
        foreach ($item in $new) { Add-Record -Scenario 'ui-closed' -Entry $item -Expected 'drop' }
        $watch.Stop()
        $entry = $new | Select-Object -First 1
        $ok = $entry -and $entry.action -eq 'intercept' -and (-not $present.ContainsKey('e2e_closed'))
        $detail = if ($entry) { "action={0} cancel={1} present={2}" -f $entry.action, $entry.cancelStatus, $present.ContainsKey('e2e_closed') } else { '无历史记录' }
        if ($ok) { Add-Result 'ui-closed' 'PASS' $detail $watch.Elapsed.TotalSeconds }
        else { Add-Result 'ui-closed' 'FAIL' $detail $watch.Elapsed.TotalSeconds }
    }
}

# 外部改写规则文件（进程不重启）应立即生效
if (-not $Only -or $Only -eq 'rules-hot-reload') {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Set-Rules $allowRules
    $since = Get-DeviceMillis
    Send-Probe -Scenario basic -Tag e2e_hot_allow -Title '秒杀提醒' -Text '规则已改为不匹配'
    $newAllow = @(Wait-NewEntries -Since $since -TimeoutSeconds 15)
    foreach ($item in $newAllow) { Add-Record -Scenario 'rules-hot-reload' -Entry $item -Expected 'keep' }
    Set-Rules $interceptRules
    $since2 = Get-DeviceMillis
    Send-Probe -Scenario basic -Tag e2e_hot_block -Title '秒杀提醒' -Text '规则已恢复'
    $newBlock = @(Wait-NewEntries -Since $since2 -TimeoutSeconds 15)
    foreach ($item in $newBlock) { Add-Record -Scenario 'rules-hot-reload' -Entry $item -Expected 'drop' }
    $watch.Stop()
    $allowEntry = $newAllow | Select-Object -First 1
    $blockEntry = $newBlock | Select-Object -First 1
    $ok = $allowEntry -and $allowEntry.action -eq 'allow' -and $blockEntry -and $blockEntry.action -eq 'intercept'
    $detail = "beforeReload={0} afterReload={1}" -f $allowEntry.action, $blockEntry.action
    if (-not $allowEntry) { $detail = '改写规则后无历史条目' }
    elseif (-not $blockEntry) { $detail = "beforeReload=$($allowEntry.action) afterReload=无历史条目" }
    if ($ok) { Add-Result 'rules-hot-reload' 'PASS' $detail $watch.Elapsed.TotalSeconds }
    else { Add-Result 'rules-hot-reload' 'FAIL' $detail $watch.Elapsed.TotalSeconds }
}

# 生成器分流：内置语料随机弹 24 条，只有白名单类别应留在通知栏
if (-not $Only -or $Only -eq 'generator-triage') {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $keepChannels = @('gen_code', 'gen_bank', 'gen_logistics', 'gen_calendar', 'gen_chat', 'gen_group')
    Set-RulesFile 'assets\presets\generator_triage.json'
    Adb shell am broadcast -n "$Generator/.GenReceiver" -a "$Generator.CLEAR" | Out-Null
    Start-Sleep -Milliseconds 600

    $since = Get-DeviceMillis
    Adb logcat -b events -c | Out-Null
    Adb shell am broadcast -n "$Generator/.GenReceiver" -a "$Generator.POST" --ei count 24 --el seed 42 | Out-Null

    # 等历史里出现 24 条带 gen_* 渠道的条目。
    # 必须同时用 tag 前缀过滤：系统自动分组会生成"继承渠道、tag 形如 0|pkg|g:..."的聚合通知。
    $entries = @()
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        $entries = @(Get-NewEntries -Since $since -Package $Generator |
                Where-Object { $_.snapshot.channelId -like 'gen_*' -and (Get-NotificationTag $_.snapshot.key) -like 'gen_*' })
        if ($entries.Count -ge 24) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($entries.Count -lt 24) {
        $watch.Stop()
        Add-Result 'generator-triage' 'FAIL' ("只处理了 {0}/24 条" -f $entries.Count) $watch.Elapsed.TotalSeconds
    } else {
        $present = Get-GeneratorTags
        $dropEntries = @($entries | Where-Object { $_.snapshot.channelId -notin $keepChannels })
        $keepEntries = @($entries | Where-Object { $_.snapshot.channelId -in $keepChannels })
        # 逐条记录期望：渠道在白名单内 → keep，否则检查关键词兜底，再否则 drop
        $keywords = @('验证码', '入账', '取件码', '会议')
        foreach ($entry in $entries) {
            $keepByChannel = $entry.snapshot.channelId -in $keepChannels
            $keepByKeyword = $false
            foreach ($k in $keywords) {
                if ("$($entry.snapshot.title)$($entry.snapshot.text)" -match [regex]::Escape($k)) { $keepByKeyword = $true; break }
            }
            $expect = if ($keepByChannel -or $keepByKeyword) { 'keep' } else { 'drop' }
            Add-Record -Scenario 'generator-triage' -Entry $entry -Expected $expect
        }
        Add-EventStats -Scenario 'generator-triage' -Package $Generator
        $expectedKeepTags = @($keepEntries | ForEach-Object { Get-NotificationTag $_.snapshot.key })
        # 白名单里实际生成出来的那些必须还在；不在白名单的类别一条都不能留
        $missing = @($expectedKeepTags | Where-Object { -not $present.ContainsKey($_) })
        $keepCategories = @('code', 'bank', 'logistics', 'calendar', 'chat', 'group')
        $intruders = @($present.Keys | Where-Object { $present[$_] -notin $keepCategories })
        $cancelFailed = @($dropEntries | Where-Object { $_.action -ne 'intercept' -or $_.cancelStatus -ne 'success' })
        # 允许的通知应该"长久"留下：8 秒后再查一次，集合不变
        Start-Sleep -Seconds 8
        $presentLater = Get-GeneratorTags
        $unstable = @($present.Keys | Where-Object { -not $presentLater.ContainsKey($_) })
        $watch.Stop()

        $ok = ($missing.Count -eq 0) -and ($intruders.Count -eq 0) -and
              ($cancelFailed.Count -eq 0) -and ($unstable.Count -eq 0)
        $detail = "generated={0} kept={1}/{2} present={3} missing={4} intruders={5} cancelFailed={6} unstable={7}" -f `
            $entries.Count, $keepEntries.Count, $expectedKeepTags.Count, $present.Count,
            $missing.Count, $intruders.Count, $cancelFailed.Count, $unstable.Count
        if (-not $ok) {
            $detail += " | missing=[$($missing -join ',')] intruders=[$($intruders -join ',')]"
        }
        if ($ok) { Add-Result 'generator-triage' 'PASS' $detail $watch.Elapsed.TotalSeconds }
        else { Add-Result 'generator-triage' 'FAIL' $detail $watch.Elapsed.TotalSeconds }
    }
}

# 响铃专项：拦截能不能阻止首次响铃？逐条用例都受控（先清空托盘）。
if (-not $Only -or $Only -eq 'alert-sound') {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $context = Get-SoundContext
    Write-Host ("响铃环境：音量 {0}/{1} · zenMode={2} · ringerMode={3}" -f `
            $context.notificationVolume, $context.notificationVolumeMax, $context.zenMode, $context.ringerMode)

    # 对照组：允许通知应当响一次。如果不响，说明设备静音/勿扰，后续响铃测量全部无效。
    $control = Measure-Alert -Name 'allow-default' -Description 'DEFAULT 渠道 + 放行（对照组）' `
        -Rules $allowRules -Sender probe -Scenario basic -Count 1
    $controlOk = $control.alerted -ge 1
    $detail = "enqueued={0} alerted={1} cancelledByIc={2}" -f $control.enqueued, $control.alerted, $control.cancelledByIc
    if ($controlOk) { Add-Result 'alert-sound-control' 'PASS' $detail $watch.Elapsed.TotalSeconds }
    else { Add-Result 'alert-sound-control' 'FAIL' "$detail（环境不可听：检查通知音量与勿扰）" $watch.Elapsed.TotalSeconds }

    # 被测：DEFAULT 渠道 + 拦截。预期"已经响过"，这是能力边界而非缺陷，记 OBSERVED。
    $leak = Measure-Alert -Name 'intercept-default' -Description 'DEFAULT 渠道 + 拦截' `
        -Rules $interceptRules -Sender probe -Scenario basic -Count 1
    Add-Result 'alert-sound-intercept' 'OBSERVED' `
    ("enqueued={0} alerted={1} cancelledByIc={2}" -f $leak.enqueued, $leak.alerted, $leak.cancelledByIc) `
        $watch.Elapsed.TotalSeconds

    # 低重要度渠道本就不会响：拦截与放行都应当 0 次打扰。
    $low = Measure-Alert -Name 'intercept-low' -Description 'LOW 渠道 + 拦截' `
        -Rules $interceptRules -Sender probe -Scenario silent -Count 1
    $lowDetail = "enqueued={0} alerted={1} belowThreshold={2}" -f $low.enqueued, $low.alerted, $low.belowThreshold
    if ($low.alerted -eq 0) { Add-Result 'alert-sound-low-channel' 'PASS' $lowDetail $watch.Elapsed.TotalSeconds }
    else { Add-Result 'alert-sound-low-channel' 'FAIL' $lowDetail $watch.Elapsed.TotalSeconds }

    # 间隔发送：每条之间留足 8 秒，绕开系统对同应用的打扰抑制。
    $spaced = Measure-Alert -Name 'intercept-spaced' -Description 'DEFAULT 渠道 + 拦截 + 3 条间隔 8s' `
        -Rules $interceptRules -Sender probe -Scenario burst -Count 3 -GapMs 8000 -SettleSeconds 32
    Add-Result 'alert-sound-spaced' 'OBSERVED' `
    ("enqueued={0} alerted={1} suppressed={2} cancelledByIc={3}" -f $spaced.enqueued, $spaced.alerted, ($spaced.coalesced + $spaced.suppressedOther), $spaced.cancelledByIc) `
        $watch.Elapsed.TotalSeconds

    # 连发：系统会把同一应用的连发抑制掉一部分（flag 2048 / 32768），不能当"漏拦率"。
    $burst = Measure-Alert -Name 'intercept-burst' -Description 'DEFAULT 渠道 + 拦截 + 5 条连发' `
        -Rules $interceptRules -Sender probe -Scenario burst -Count 5 -GapMs 0
    Add-Result 'alert-sound-burst' 'OBSERVED' `
    ("enqueued={0} alerted={1} coalesced={2} suppressedOther={3} cancelledByIc={4}" -f $burst.enqueued, $burst.alerted, $burst.coalesced, $burst.suppressedOther, $burst.cancelledByIc) `
        $watch.Elapsed.TotalSeconds

    # 生成器噪声类别开启响铃模式：演示"促销通知确实会响，被拦截后仍然响过一次"。
    $loud = Measure-Alert -Name 'generator-loud' -Description '生成器噪声类别 + 响铃模式 + 全包拦截' `
        -Rules (New-RuleSet -Packages @($Generator)) -Sender generator `
        -Scenario promo -Count 3 -GapMs 8000 -Loud -SettleSeconds 32
    Add-Result 'alert-sound-generator-loud' 'OBSERVED' `
    ("enqueued={0} alerted={1} suppressed={2} cancelledByIc={3}" -f $loud.enqueued, $loud.alerted, ($loud.coalesced + $loud.suppressedOther), $loud.cancelledByIc) `
        $watch.Elapsed.TotalSeconds
}

# 撤销授权后规则失效。部分系统在改 secure settings 后不会立即解绑，需先确认。
if (-not $Only -or $Only -eq 'permission-revoked') {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Set-Rules $interceptRules
    Assert-Listener -Enabled $false
    $unbound = $false
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $dump = (Adb shell dumpsys notification --noredact) -join "`n"
        if ($dump -notmatch [regex]::Escape($App)) { $unbound = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $unbound) {
        Assert-Listener -Enabled $true
        $watch.Stop()
        Add-Result 'permission-revoked' 'OBSERVED' '修改 secure settings 后系统未解绑监听器，需在设置页手工撤销' $watch.Elapsed.TotalSeconds
    } else {
        $since = Get-DeviceMillis
        Send-Probe -Scenario basic -Tag e2e_revoked -Title '秒杀提醒' -Text '已撤销授权'
        Start-Sleep -Seconds 3
        $present = Get-ProbeTags
        $entries = @(Get-NewEntries -Since $since)
        Assert-Listener -Enabled $true
        $watch.Stop()
        $ok = $present.ContainsKey('e2e_revoked') -and $entries.Count -eq 0
        $detail = "presentAfterRevoke={0} newEntries={1}" -f `
            $present.ContainsKey('e2e_revoked'), $entries.Count
        if ($ok) { Add-Result 'permission-revoked' 'PASS' $detail $watch.Elapsed.TotalSeconds }
        else { Add-Result 'permission-revoked' 'FAIL' $detail $watch.Elapsed.TotalSeconds }
    }
}

if ($IncludeReboot) {
    if (-not $Only -or $Only -eq 'reboot-persistence') {
        Write-Host '重启设备（约 60–90 秒）…'
        Adb reboot | Out-Null
        Start-Sleep -Seconds 20
        Adb wait-for-device | Out-Null
        $deadline = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $deadline) {
            $booted = (Adb shell getprop sys.boot_completed) -join ''
            if ($booted.Trim() -eq '1') { break }
            Start-Sleep -Seconds 3
        }
        Start-Sleep -Seconds 15
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        Assert-Listener -Enabled $true
        Set-Rules $interceptRules
        $since = Get-DeviceMillis
        Send-Probe -Scenario basic -Tag e2e_reboot -Title '秒杀提醒' -Text '重启后'
        $new = @(Wait-NewEntries -Since $since -TimeoutSeconds 30)
        foreach ($item in $new) { Add-Record -Scenario 'reboot-persistence' -Entry $item -Expected 'drop' }
        $present = Get-ProbeTags
        $watch.Stop()
        $entry = $new | Select-Object -First 1
        $ok = $entry -and $entry.action -eq 'intercept' -and (-not $present.ContainsKey('e2e_reboot'))
        $detail = if ($entry) { "action={0} cancel={1}" -f $entry.action, $entry.cancelStatus } else { '无历史记录' }
        if ($ok) { Add-Result 'reboot-persistence' 'PASS' $detail $watch.Elapsed.TotalSeconds }
        else { Add-Result 'reboot-persistence' 'FAIL' $detail $watch.Elapsed.TotalSeconds }
    }
}

# ---------------------------------------------------------------- 报告

$passed = @($script:results | Where-Object { $_.Status -eq 'PASS' }).Count
$failed = @($script:results | Where-Object { $_.Status -eq 'FAIL' }).Count
$observed = @($script:results | Where-Object { $_.Status -eq 'OBSERVED' }).Count

$sdk = (Adb shell getprop ro.build.version.sdk) -join ''
$release = (Adb shell getprop ro.build.version.release) -join ''
$model = (Adb shell getprop ro.product.model) -join ''

$reportDir = Join-Path $RepoRoot 'docs\verification\reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportPath = Join-Path $reportDir "e2e-$stamp.md"

$lines = New-Object System.Collections.ArrayList
[void]$lines.Add("# E2E 报告 $stamp")
[void]$lines.Add('')
[void]$lines.Add(("- 设备：{0} / Android {1} (API {2})" -f $model, $release, $sdk))
[void]$lines.Add(("- 应用：{0}；探针：{1}" -f $App, $Probe))
[void]$lines.Add(("- 结果：PASS {0} · FAIL {1} · OBSERVED {2}" -f $passed, $failed, $observed))
[void]$lines.Add('')
[void]$lines.Add('| 场景 | 结果 | 耗时(s) | 详情 |')
[void]$lines.Add('|---|---|---|---|')
foreach ($r in $script:results) {
    [void]$lines.Add(("| {0} | {1} | {2} | {3} |" -f $r.Name, $r.Status, $r.Seconds, $r.Detail))
}
[void]$lines.Add('')
[void]$lines.Add('> OBSERVED 表示该场景用于观测系统行为（如 ongoing 通知能否取消），不计入失败。')

[System.IO.File]::WriteAllLines($reportPath, $lines, $Utf8NoBom)

# 机器可读副本：逐条通知 + 每个场景的系统事件统计，metrics.ps1 从这里复算。
$sound = Get-SoundContext
$jsonPath = Join-Path $reportDir "e2e-$stamp.json"
$payload = [ordered]@{
    schemaVersion = 1
    stamp         = $stamp
    device        = [ordered]@{ model = $model; release = $release; sdk = $sdk }
    apps          = [ordered]@{ app = $App; probe = $Probe; generator = $Generator }
    sound         = $sound
    summary       = [ordered]@{ pass = $passed; fail = $failed; observed = $observed }
    scenarios     = @($script:results | ForEach-Object {
            [ordered]@{ name = $_.Name; status = $_.Status; seconds = $_.Seconds; detail = $_.Detail }
        })
    events        = @($script:eventStats)
    alerts        = @($script:alertCases)
    notifications = @($script:records)
}
[System.IO.File]::WriteAllText($jsonPath, ($payload | ConvertTo-Json -Depth 8), $Utf8NoBom)

Write-Host ''
Write-Host ("报告：{0}" -f $reportPath)
Write-Host ("数据：{0}（{1} 条通知记录，{2} 条响铃用例）" -f $jsonPath, $script:records.Count, $script:alertCases.Count)
Write-Host ("结果：PASS {0} · FAIL {1} · OBSERVED {2}" -f $passed, $failed, $observed)

if ($failed -gt 0) { exit 1 }
exit 0
