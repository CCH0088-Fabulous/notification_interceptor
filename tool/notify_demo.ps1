# 通知验证脚本：授权、造通知、检查拦截结果。
# 用法：
#   .\tool\notify_demo.ps1 enable     # 授予通知使用权（需要能修改 secure settings）
#   .\tool\notify_demo.ps1 post       # 造一条包含"秒杀"的通知
#   .\tool\notify_demo.ps1 check      # 检查该通知是否仍在通知栏
#   .\tool\notify_demo.ps1 history    # 打印应用历史最后一条
param(
    [Parameter(Position = 0)]
    [ValidateSet('enable', 'post', 'check', 'history')]
    [string]$Action = 'check',
    [string]$Adb = 'D:\Android_SDK\platform-tools\adb.exe',
    [string]$Package = 'dev.poc.notifinterceptor',
    [string]$Tag = 'poc_demo'
)

$component = "$Package/$Package.listener.NotificationInterceptorService"

switch ($Action) {
    'enable' {
        $current = (& $Adb shell settings get secure enabled_notification_listeners).Trim()
        if ($current -notmatch [regex]::Escape($component)) {
            $updated = if ([string]::IsNullOrWhiteSpace($current)) { $component } else { "$current`:$component" }
            & $Adb shell settings put secure enabled_notification_listeners $updated
        }
        & $Adb shell settings get secure enabled_notification_listeners
    }
    'post' {
        & $Adb shell cmd notification post -t 秒杀 $Tag 限时优惠
    }
    'check' {
        $dump = (& $Adb shell dumpsys notification --noredact 2>&1 | Out-String)
        if ($dump -match "tag=$Tag\b") { Write-Output "PRESENT: $Tag 仍在通知栏" }
        else { Write-Output "CANCELLED: $Tag 已不在通知栏" }
    }
    'history' {
        & $Adb shell run-as $Package tail -n 1 files/history.jsonl
    }
}
