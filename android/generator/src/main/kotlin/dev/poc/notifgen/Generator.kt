package dev.poc.notifgen

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import java.util.Random

/**
 * 造通知。所有通知都来自本应用自有渠道，`tag` 里带类别与序号，
 * 便于测试脚本按类别统计"谁留下了、谁被拦截了"。
 */
class Generator(private val context: Context) {

    private val manager: NotificationManager? =
        context.getSystemService(NotificationManager::class.java)

    private var random = Random()
    private var corpus = NoticeCorpus(random)

    /** 固定 seed 可让一批评测的数据完全可复现。 */
    fun reseed(seed: Long?) {
        random = if (seed == null) Random() else Random(seed)
        corpus = NoticeCorpus(random)
    }

    fun post(
        count: Int = 1,
        categoryId: String? = null,
        delayMs: Long = 0,
        loud: Boolean = false,
    ): List<Draft> {
        val manager = manager ?: return emptyList()
        ensureChannels(context)
        val total = count.coerceIn(1, 100)
        val fixedCategory = categoryId?.let { corpus.findCategory(it) }
        val posted = ArrayList<Draft>(total)
        repeat(total) { index ->
            val draft = corpus.next(fixedCategory ?: corpus.pickCategory())
            val sequence = nextSequence()
            val tag = tagFor(draft.category, sequence)
            val channelId = GeneratorChannels.channelIdFor(draft.category, loud)
            ensureChannel(draft.category, loud)
            runCatching { manager.notify(tag, sequence, build(draft, channelId)) }
                .onSuccess { posted += draft }
                .onFailure { log("post", tag, draft.category.id, "FAILED", "${it.message}") }
            val verdict = when {
                draft.category.keep -> "keep"
                loud -> "drop-loud"
                else -> "drop"
            }
            log("post", tag, draft.category.id, verdict, draft.text)
            if (delayMs > 0 && index < total - 1) Thread.sleep(delayMs)
        }
        return posted
    }

    fun verify() {
        val manager = manager ?: return
        // 系统会为自动分组生成 tag 形如 `0|pkg|g:...` 的聚合通知，只统计本应用真正发出的那些。
        val active = runCatching { manager.activeNotifications }.getOrNull().orEmpty()
            .filter { it.packageName == context.packageName && GeneratorTags.isGenerated(it.tag) }
        active.forEach { sbn ->
            val tag = sbn.tag ?: "-"
            Log.i(NoticeCorpus.TAG_LOG, "GEN|present|$tag|${GeneratorTags.categoryOf(tag)}|id=${sbn.id}")
        }
        Log.i(NoticeCorpus.TAG_LOG, "GEN|verify|-|COUNT|${active.size}")
    }

    fun clearAll() {
        manager?.cancelAll()
        log("clear", "-", "-", "DONE", "0")
    }

    private fun build(draft: Draft, channelId: String): Notification {
        val builder = Notification.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(draft.title)
            .setContentText(draft.text)
            .setAutoCancel(true)
            .setContentIntent(openIntent())

        when (draft.category.style) {
            NoticeStyle.BASIC -> Unit

            NoticeStyle.BIG_TEXT -> builder.setStyle(
                Notification.BigTextStyle().bigText(draft.text),
            )

            NoticeStyle.MESSAGING -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    val me = android.app.Person.Builder()
                        .setName(draft.sender ?: "我")
                        .setImportant(true)
                        .build()
                    builder.setStyle(
                        Notification.MessagingStyle(me)
                            .setConversationTitle(draft.persona)
                            .addMessage(draft.text, System.currentTimeMillis(), me),
                    )
                } else {
                    builder.setStyle(Notification.BigTextStyle().bigText(draft.text))
                }
            }
        }
        return builder.build()
    }

    private fun openIntent(): PendingIntent {
        val intent = Intent(context, GeneratorActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun log(event: String, tag: String, category: String, verdict: String, detail: String) {
        Log.i(NoticeCorpus.TAG_LOG, "GEN|$event|$tag|$category|$verdict|$detail")
    }

    companion object {
        private val SEQUENCE = java.util.concurrent.atomic.AtomicInteger(0)

        private fun nextSequence(): Int = SEQUENCE.incrementAndGet()

        fun tagFor(category: Category, sequence: Int): String =
            GeneratorTags.forCategory(category, sequence)

        fun ensureChannels(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            NoticeCorpus.CATEGORIES.forEach { category ->
                manager.createNotificationChannel(
                    NotificationChannel(
                        GeneratorChannels.channelIdFor(category),
                        GeneratorChannels.nameFor(category),
                        GeneratorChannels.importanceFor(category),
                    ),
                )
            }
        }
    }

    /** 响铃模式的高重要度渠道按需创建，避免给通知设置页塞十几条无用渠道。 */
    private fun ensureChannel(category: Category, loud: Boolean) {
        if (!loud || category.keep) return
        val manager = manager ?: return
        manager.createNotificationChannel(
            NotificationChannel(
                GeneratorChannels.channelIdFor(category, loud = true),
                GeneratorChannels.nameFor(category, loud = true),
                GeneratorChannels.importanceFor(category, loud = true),
            ),
        )
    }
}
