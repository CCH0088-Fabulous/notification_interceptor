package dev.poc.notifinterceptor.support

import android.service.notification.NotificationListenerService
import dev.poc.notifinterceptor.domain.CancelStatus
import dev.poc.notifinterceptor.domain.CancelVerifier
import dev.poc.notifinterceptor.domain.NotificationCanceller
import dev.poc.notifinterceptor.domain.TimeSource

/** 直接调用系统的 cancelNotification，异常视为调用失败。 */
class ServiceCanceller(
    private val service: NotificationListenerService,
) : NotificationCanceller {
    override fun cancel(key: String): Boolean =
        runCatching {
            service.cancelNotification(key)
            true
        }.getOrDefault(false)
}

/**
 * 一次非阻塞的活动通知查询，不做任何等待。
 *
 * 只在 [RemovalDrivenCancelTracker] 的超时复查里使用：回调没来，说明系统可能拒绝了取消，
 * 这时查一次 `activeNotifications` 就能区分 rejected / success，不需要 sleep 轮询。
 */
class ImmediateCancelVerifier(
    private val service: NotificationListenerService,
) : CancelVerifier {
    override fun verify(key: String): CancelStatus = runCatching {
        val active = service.activeNotifications
        if (active == null) CancelStatus.FAILED
        else if (active.any { it.key == key }) CancelStatus.REJECTED else CancelStatus.SUCCESS
    }.getOrDefault(CancelStatus.FAILED)
}

object SystemTimeSource : TimeSource {
    override fun now(): Long = System.currentTimeMillis()
}
