package dev.poc.probe

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.util.Log

/**
 * 渠道与通知构造。测试脚本通过 scenario 选择形态，
 * 目的是覆盖 `cmd notification post` 造不出来的真实通知类型。
 */
class ProbeNotifications(private val context: Context) {

    private val manager: NotificationManager =
        context.getSystemService(NotificationManager::class.java)

    fun post(
        scenario: String,
        tag: String,
        title: String,
        text: String,
        id: Int,
        count: Int,
        delayMs: Long,
    ) {
        when (scenario) {
            SCENARIO_BASIC -> postBasic(tag, id, title, text)
            SCENARIO_ONGOING -> postOngoing(tag, id, title, text)
            SCENARIO_NOCLEAR -> postNoClear(tag, id, title, text)
            SCENARIO_SILENT -> postSilent(tag, id, title, text)
            SCENARIO_GROUP -> postGroup(tag, title, text)
            SCENARIO_MESSAGING -> postMessaging(tag, id, title, text)
            SCENARIO_INBOX -> postInbox(tag, id, title, text)
            SCENARIO_PROGRESS -> postProgress(tag, id, title, text)
            SCENARIO_UPDATE -> postUpdate(tag, id, title, text)
            SCENARIO_BURST -> postBurst(tag, id, title, text, count, delayMs)
            SCENARIO_REMOVE -> remove(tag, id)
            else -> log(scenario, tag, "ERROR", "未知场景 $scenario")
        }
    }

    fun verify(tag: String?) {
        val active = manager.activeNotifications
        active.forEach { sbn ->
            Log.i(TAG_LOG, "PROBE|verify|${sbn.tag ?: "-"}|PRESENT|id=${sbn.id}|pkg=${sbn.packageName}")
        }
        Log.i(TAG_LOG, "PROBE|verify|${tag ?: "-"}|COUNT|${active.size}")
    }

    fun cancelAll() {
        manager.cancelAll()
        Log.i(TAG_LOG, "PROBE|clearAll|-|DONE|0")
    }

    private fun postBasic(tag: String, id: Int, title: String, text: String) {
        val builder = baseBuilder(CHANNEL_DEFAULT, title, text)
        notify(tag, id, builder.build(), SCENARIO_BASIC)
    }

    private fun postOngoing(tag: String, id: Int, title: String, text: String) {
        val builder = baseBuilder(CHANNEL_DEFAULT, title, text).setOngoing(true)
        notify(tag, id, builder.build(), SCENARIO_ONGOING)
    }

    private fun postNoClear(tag: String, id: Int, title: String, text: String) {
        val notification = baseBuilder(CHANNEL_DEFAULT, title, text).build()
        notification.flags = notification.flags or android.app.Notification.FLAG_NO_CLEAR
        notify(tag, id, notification, SCENARIO_NOCLEAR)
    }

    private fun postSilent(tag: String, id: Int, title: String, text: String) {
        val builder = baseBuilder(CHANNEL_SILENT, title, text)
            .setSound(null, null)
            .setVibrate(null)
        notify(tag, id, builder.build(), SCENARIO_SILENT)
    }

    /** 两个子通知 + 一个 group summary：验证规则只会命中子通知。 */
    private fun postGroup(tag: String, title: String, text: String) {
        val groupKey = "probe-group"
        for (index in 1..2) {
            val builder = baseBuilder(CHANNEL_DEFAULT, title, "$text #$index")
                .setGroup(groupKey)
            manager.notify("$tag-child$index", 100 + index, builder.build())
            log(SCENARIO_GROUP, "$tag-child$index", "POSTED", "id=${100 + index}")
        }
        val summary = baseBuilder(CHANNEL_DEFAULT, "分组汇总", "$text 汇总")
            .setGroup(groupKey)
            .setGroupSummary(true)
            .build()
        manager.notify(tag, 100, summary)
        log(SCENARIO_GROUP, tag, "POSTED", "id=100")
    }

    private fun postMessaging(tag: String, id: Int, title: String, text: String) {
        val notification = if (android.os.Build.VERSION.SDK_INT >= 28) {
            val person = android.app.Person.Builder().setName("Probe").setImportant(true).build()
            android.app.Notification.MessagingStyle(person)
                .setConversationTitle(title)
                .addMessage(text, System.currentTimeMillis(), person)
                .also { style ->
                    baseBuilder(CHANNEL_DEFAULT, title, text).setStyle(style)
                }
                .build()
        } else {
            baseBuilder(CHANNEL_DEFAULT, title, text).build()
        }
        notify(tag, id, notification, SCENARIO_MESSAGING)
    }

    private fun postInbox(tag: String, id: Int, title: String, text: String) {
        val style = android.app.Notification.InboxStyle()
            .addLine(text)
            .addLine("第二行")
        val notification = baseBuilder(CHANNEL_DEFAULT, title, text).setStyle(style).build()
        notify(tag, id, notification, SCENARIO_INBOX)
    }

    private fun postProgress(tag: String, id: Int, title: String, text: String) {
        val notification = baseBuilder(CHANNEL_DEFAULT, title, text)
            .setProgress(100, 42, false)
            .setOngoing(true)
            .build()
        notify(tag, id, notification, SCENARIO_PROGRESS)
    }

    /** 同一个 tag/id 连发两次，第二次是更新（系统会替换）。 */
    private fun postUpdate(tag: String, id: Int, title: String, text: String) {
        for (round in 1..2) {
            val notification = baseBuilder(CHANNEL_DEFAULT, title, "$text 第 $round 版").build()
            manager.notify(tag, id, notification)
            log(SCENARIO_UPDATE, tag, "POSTED", "round=$round,id=$id")
            Thread.sleep(UPDATE_INTERVAL_MS)
        }
    }

    private fun postBurst(tag: String, id: Int, title: String, text: String, count: Int, delayMs: Long) {
        val total = count.coerceIn(1, 100)
        for (index in 0 until total) {
            val notification = baseBuilder(CHANNEL_DEFAULT, title, "$text #$index").build()
            manager.notify(tag, id + index, notification)
            log(SCENARIO_BURST, tag, "POSTED", "index=$index,id=${id + index}")
            if (delayMs > 0) Thread.sleep(delayMs)
        }
    }

    private fun remove(tag: String, id: Int) {
        manager.cancel(tag, id)
        log(SCENARIO_REMOVE, tag, "REMOVED", "id=$id")
    }

    private fun baseBuilder(channelId: String, title: String, text: String) =
        android.app.Notification.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.stat_notify_more)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)

    private fun notify(tag: String, id: Int, notification: android.app.Notification, scenario: String) {
        manager.notify(tag, id, notification)
        log(scenario, tag, "POSTED", "id=$id")
    }

    private fun log(scenario: String, tag: String, event: String, detail: String) {
        Log.i(TAG_LOG, "PROBE|$scenario|$tag|$event|$detail")
    }

    companion object {
        const val TAG_LOG = "ProbeApp"

        const val SCENARIO_BASIC = "basic"
        const val SCENARIO_ONGOING = "ongoing"
        const val SCENARIO_NOCLEAR = "noclear"
        const val SCENARIO_SILENT = "silent"
        const val SCENARIO_GROUP = "group"
        const val SCENARIO_MESSAGING = "messaging"
        const val SCENARIO_INBOX = "inbox"
        const val SCENARIO_PROGRESS = "progress"
        const val SCENARIO_UPDATE = "update"
        const val SCENARIO_BURST = "burst"
        const val SCENARIO_REMOVE = "remove"

        const val CHANNEL_DEFAULT = "probe_default"
        const val CHANNEL_SILENT = "probe_silent"

        private const val UPDATE_INTERVAL_MS = 300L

        fun ensureChannels(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_DEFAULT, "Probe 默认", NotificationManager.IMPORTANCE_DEFAULT),
            )
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_SILENT, "Probe 静默", NotificationManager.IMPORTANCE_LOW).apply {
                    setSound(null, null)
                    enableVibration(false)
                },
            )
        }
    }
}
