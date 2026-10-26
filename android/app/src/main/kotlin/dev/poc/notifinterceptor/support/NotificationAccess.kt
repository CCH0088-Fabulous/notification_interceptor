package dev.poc.notifinterceptor.support

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.service.notification.NotificationListenerService
import dev.poc.notifinterceptor.listener.NotificationInterceptorService

/** 通知使用权（notification access）的状态查询与设置跳转。 */
object NotificationAccess {

    private const val ENABLED_LISTENERS = "enabled_notification_listeners"

    fun isGranted(context: Context): Boolean {
        val flat = runCatching {
            Settings.Secure.getString(context.contentResolver, ENABLED_LISTENERS)
        }.getOrNull() ?: return false
        return flat.split(':').any { component ->
            android.content.ComponentName.unflattenFromString(component)?.packageName == context.packageName
        }
    }

    fun settingsIntent(): Intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /**
     * 已授权但服务未绑定时（例如进程被 force-stop、或被厂商清理）请求系统重新绑定。
     * 未授权时调用会被系统拒绝，因此直接跳过。
     */
    fun rebindIfGranted(context: Context): Boolean {
        if (!isGranted(context)) return false
        val component = ComponentName(context, NotificationInterceptorService::class.java)
        return runCatching {
            NotificationListenerService.requestRebind(component)
            true
        }.getOrDefault(false)
    }
}
