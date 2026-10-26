package dev.poc.notifinterceptor.listener

import android.app.Notification
import android.service.notification.StatusBarNotification
import dev.poc.notifinterceptor.data.AppInfoResolver
import dev.poc.notifinterceptor.domain.NotificationSnapshot

/**
 * 把 StatusBarNotification 转成稳定的领域快照。
 * 必须容错：第三方 App 可能塞入任意类型/空值的 extras。
 */
class NotificationSnapshotFactory(
    private val context: android.content.Context,
    private val appInfo: AppInfoResolver,
) {

    fun create(sbn: StatusBarNotification): NotificationSnapshot {
        val notification = sbn.notification
        val extras = notification.extras

        return NotificationSnapshot(
            key = sbn.key,
            id = sbn.id,
            packageName = sbn.packageName.orEmpty(),
            appLabel = appInfo.labelOf(sbn.packageName.orEmpty()),
            postTime = sbn.postTime,
            title = extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
            text = extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString(),
            bigText = extras?.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString(),
            textLines = extras?.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
                ?.mapNotNull { it?.toString() }
                ?: emptyList(),
            subText = extras?.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString(),
            tickerText = notification.tickerText?.toString(),
            category = notification.category,
            channelId = notification.channelId,
            channelName = channelName(notification),
            groupKey = sbn.groupKey,
            isGroupSummary = (notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0,
            isOngoing = (notification.flags and Notification.FLAG_ONGOING_EVENT) != 0,
            isClearable = (notification.flags and Notification.FLAG_NO_CLEAR) == 0,
            priority = notification.priority,
            progress = extras?.getInt(Notification.EXTRA_PROGRESS, -1) ?: -1,
            extras = debugExtras(extras),
        )
    }

    private fun channelName(notification: Notification): String? = runCatching {
        val id = notification.channelId ?: return null
        val manager = context.getSystemService(android.app.NotificationManager::class.java)
        manager?.getNotificationChannel(id)?.name?.toString()?.takeIf { it.isNotBlank() }
    }.getOrNull()

    private fun debugExtras(extras: android.os.Bundle?): Map<String, String> {
        if (extras == null) return emptyMap()
        val result = LinkedHashMap<String, String>()
        for (key in extras.keySet()) {
            if (result.size >= MAX_EXTRA_KEYS) break
            val value = runCatching { extras.get(key) }.getOrNull() ?: continue
            if (value is android.os.Bundle) continue
            val text = runCatching { value.toString() }.getOrNull() ?: continue
            result[key] = if (text.length > MAX_EXTRA_VALUE_LENGTH) {
                text.take(MAX_EXTRA_VALUE_LENGTH) + "…"
            } else {
                text
            }
        }
        return result
    }

    companion object {
        private const val MAX_EXTRA_KEYS = 40
        private const val MAX_EXTRA_VALUE_LENGTH = 200
    }
}
