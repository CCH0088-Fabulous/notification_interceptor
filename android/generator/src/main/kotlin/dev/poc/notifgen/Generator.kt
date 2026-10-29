package dev.poc.notifgen

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.LruCache
import java.security.SecureRandom
import java.util.Random
import java.util.concurrent.atomic.AtomicInteger

/** Builds real system notifications; simulation is opt-in so E2E batches stay independent. */
class Generator(context: Context) {
    private val context = context.applicationContext
    private val manager = this.context.getSystemService(NotificationManager::class.java)
    private val avatars = LruCache<String, Bitmap>(24)
    private var corpus = NoticeCorpus(Random())

    fun reseed(seed: Long?) {
        corpus = NoticeCorpus(if (seed == null) Random() else Random(seed))
    }

    fun post(
        count: Int = 1,
        categoryId: String? = null,
        delayMs: Long = 0,
        loud: Boolean = false,
        realistic: Boolean = false,
        categoryIds: Set<String>? = null,
        headsUp: Boolean = false,
    ): List<Draft> {
        val manager = manager ?: return emptyList()
        ensureChannels(context)
        val fixedCategory = categoryId?.let { id ->
            requireNotNull(corpus.findCategory(id)) { "未知通知类别：$id" }
        }
        val categories = NoticeCorpus.CATEGORIES.filter { categoryIds == null || it.id in categoryIds }
        require(categories.isNotEmpty()) { "至少选择一个通知类别" }
        val total = count.coerceIn(1, 100)
        val posted = ArrayList<Draft>(total)
        repeat(total) { index ->
            val draft = corpus.next(fixedCategory ?: corpus.pickCategory(categories))
            val timestamp = System.currentTimeMillis()
            val channelId = GeneratorChannels.channelIdFor(draft.category, loud, headsUp)
            val planned = simulation.conversations.plan(
                draft, realistic, timestamp, identityScope = channelId, isActive = ::isActive,
            )
            val journey = if (realistic && draft.category.id == "logistics") LogisticsJourney.steps(draft) else null
            ensureChannel(draft.category, loud, headsUp)
            runCatching {
                if (headsUp) BannerSummaries.get(context).prepare(BannerChild(
                    planned.identity, draft.title, journey?.first()?.status ?: draft.text,
                    BannerGrouping.GROUP_KEY, postedAt = timestamp,
                ))
                manager.notify(
                    planned.identity.tag,
                    planned.identity.id,
                    build(draft, channelId, planned, timestamp, realistic, journey?.first()),
                )
            }.onSuccess {
                posted += draft
                log("post", planned.identity.tag, draft.category.id, verdict(draft, loud), draft.text)
                if (journey != null) scheduleJourney(draft, channelId, planned, timestamp, loud, journey)
            }.onFailure {
                log("failed", planned.identity.tag, draft.category.id, "FAILED", it.message.orEmpty())
            }
            // Kept for the synchronous broadcast API. The UI schedules individual posts.
            if (delayMs > 0 && index < total - 1) Thread.sleep(delayMs)
        }
        return posted
    }

    fun verify() {
        val manager = manager ?: return
        val active = runCatching { manager.activeNotifications }.getOrNull().orEmpty()
            .filter { it.packageName == context.packageName && GeneratorTags.isGenerated(it.tag) }
        active.forEach { sbn ->
            val tag = sbn.tag ?: "-"
            Log.i(NoticeCorpus.TAG_LOG, "GEN|present|$tag|${GeneratorTags.categoryOf(tag)}|id=${sbn.id}")
        }
        Log.i(NoticeCorpus.TAG_LOG, "GEN|verify|-|COUNT|${active.size}")
    }

    fun clearAll() {
        stopPendingUpdates()
        simulation.conversations.clear()
        BannerSummaries.get(context).stop()
        manager?.cancelAll()
        log("clear", "-", "-", "DONE", "0")
    }

    /** Recover summary maintenance from actual notifications after an Activity/process restart. */
    fun refreshBannerSummary() = BannerSummaries.get(context).refresh()

    /** UI, broadcasts and updates share the main Looper and a process-wide cancellation registry. */
    fun stopPendingUpdates() {
        simulation.updates.clear()
        handler.removeCallbacksAndMessages(null)
    }

    private fun scheduleJourney(
        draft: Draft,
        channelId: String,
        planned: PlannedNotice,
        timestamp: Long,
        loud: Boolean,
        steps: List<LogisticsStep>,
    ) {
        val token = simulation.updates.start(planned.identity)
        steps.drop(1).forEachIndexed { index, step ->
            handler.postDelayed({
                if (!simulation.updates.permits(token, isActive(planned.identity))) {
                    simulation.updates.finish(token)
                    return@postDelayed
                }
                runCatching {
                    manager?.notify(
                        planned.identity.tag,
                        planned.identity.id,
                        build(draft, channelId, planned, timestamp, true, step),
                    )
                }.onSuccess {
                    log("update", planned.identity.tag, draft.category.id, verdict(draft, loud), step.status)
                }.onFailure {
                    simulation.updates.finish(token)
                    log("failed", planned.identity.tag, draft.category.id, "FAILED", it.message.orEmpty())
                }
                if (step.complete) simulation.updates.finish(token)
            }, (index + 1) * JOURNEY_INTERVAL_MS)
        }
    }

    private fun isActive(identity: NoticeIdentity): Boolean =
        runCatching {
            manager?.activeNotifications?.any { it.tag == identity.tag && it.id == identity.id } == true
        }.getOrDefault(false)

    private fun build(
        draft: Draft,
        channelId: String,
        planned: PlannedNotice,
        timestamp: Long,
        realistic: Boolean,
        logistics: LogisticsStep? = null,
    ): Notification {
        val text = logistics?.status ?: draft.text
        val builder = Notification.Builder(context, channelId)
            .setSmallIcon(smallIcon(draft.category.id))
            .setColor(accentColor(draft.category.id))
            .setContentTitle(draft.title)
            .setContentText(text)
            .setSubText(draft.category.label)
            .setCategory(systemCategory(draft.category.id))
            .setWhen(timestamp)
            .setShowWhen(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setAutoCancel(true)
            .setContentIntent(openIntent())

        BannerGrouping.groupKeyFor(channelId.endsWith(GeneratorChannels.BANNER_SUFFIX))?.let { group ->
            builder.setGroup(group)
                .setGroupAlertBehavior(Notification.GROUP_ALERT_CHILDREN)
                .setDeleteIntent(BannerDismissReceiver.pendingIntent(context))
        }

        if (realistic) builder.setLargeIcon(avatar(draft.persona, accentColor(draft.category.id)))
        if (logistics != null) {
            builder.setOnlyAlertOnce(true)
                .setStyle(Notification.BigTextStyle().bigText(text))
            if (!logistics.complete) builder.setProgress(100, logistics.progress, false)
            return builder.build()
        }

        when (draft.category.style) {
            NoticeStyle.BASIC -> {
                if (realistic) builder.setStyle(Notification.BigTextStyle().bigText(text))
            }
            NoticeStyle.BIG_TEXT -> builder.setStyle(Notification.BigTextStyle().bigText(text))
            NoticeStyle.MESSAGING -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    val self = Person.Builder().setName("我").setKey("self").build()
                    val style = Notification.MessagingStyle(self)
                        .setGroupConversation(draft.category.id == "group")
                    if (draft.category.id == "group") style.setConversationTitle(draft.persona)
                    planned.messages.forEach { message ->
                        val sender = Person.Builder()
                            .setName(message.sender)
                            .setKey(message.sender)
                            .setIcon(Icon.createWithBitmap(avatar(message.sender, accentColor(draft.category.id))))
                            .build()
                        style.addMessage(message.text, message.timestamp, sender)
                    }
                    builder.setStyle(style)
                } else {
                    val style = Notification.MessagingStyle("我")
                    if (draft.category.id == "group") style.setConversationTitle(draft.persona)
                    planned.messages.forEach { style.addMessage(it.text, it.timestamp, it.sender) }
                    builder.setStyle(style)
                }
                if (realistic) builder.setNumber(planned.messages.size)
            }
        }
        return builder.build()
    }

    private fun openIntent(): PendingIntent = PendingIntent.getActivity(
        context,
        0,
        Intent(context, GeneratorActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun avatar(name: String, color: Int): Bitmap {
        val key = "$name|$color"
        avatars.get(key)?.let { return it }
        val bitmap = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
        canvas.drawCircle(48f, 48f, 48f, paint)
        paint.apply {
            this.color = Color.WHITE
            textSize = 40f
            textAlign = Paint.Align.CENTER
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val label = name.trim().trimStart('【', '[').take(1).ifBlank { "通" }
        canvas.drawText(label, 48f, 48f - (paint.ascent() + paint.descent()) / 2f, paint)
        avatars.put(key, bitmap)
        return bitmap
    }

    private fun smallIcon(id: String): Int = when (id) {
        "chat", "group", "social" -> android.R.drawable.stat_notify_chat
        "code" -> android.R.drawable.ic_lock_lock
        "bank" -> android.R.drawable.ic_dialog_info
        "logistics" -> android.R.drawable.stat_sys_download
        "calendar" -> android.R.drawable.ic_menu_my_calendar
        "promo", "marketing" -> android.R.drawable.ic_menu_today
        "news" -> android.R.drawable.ic_dialog_email
        "game" -> android.R.drawable.ic_media_play
        "spam" -> android.R.drawable.stat_sys_warning
        else -> android.R.drawable.stat_notify_sync
    }

    private fun accentColor(id: String): Int = Color.parseColor(when (id) {
        "chat", "group" -> "#188C68"
        "code", "bank" -> "#3868D9"
        "logistics" -> "#DC791D"
        "calendar" -> "#8658C9"
        "promo", "marketing" -> "#D9536D"
        "spam" -> "#C44C41"
        else -> "#54758C"
    })

    private fun systemCategory(id: String): String = when (id) {
        "chat", "group", "code" -> Notification.CATEGORY_MESSAGE
        "logistics" -> Notification.CATEGORY_PROGRESS
        "calendar" -> Notification.CATEGORY_EVENT
        "promo", "marketing" -> Notification.CATEGORY_PROMO
        "social" -> Notification.CATEGORY_SOCIAL
        "news", "game" -> Notification.CATEGORY_RECOMMENDATION
        "spam" -> Notification.CATEGORY_ERROR
        else -> Notification.CATEGORY_STATUS
    }

    private fun verdict(draft: Draft, loud: Boolean): String = when {
        draft.category.keep -> "keep"
        loud -> "drop-loud"
        else -> "drop"
    }

    private fun log(event: String, tag: String, category: String, verdict: String, detail: String) {
        Log.i(NoticeCorpus.TAG_LOG, "GEN|$event|$tag|$category|$verdict|$detail")
    }

    private fun ensureChannel(category: Category, loud: Boolean, headsUp: Boolean) {
        if (!headsUp && (!loud || category.keep)) return
        manager?.createNotificationChannel(NotificationChannel(
            GeneratorChannels.channelIdFor(category, loud, headsUp),
            GeneratorChannels.nameFor(category, loud, headsUp),
            GeneratorChannels.importanceFor(category, loud, headsUp),
        ))
    }

    companion object {
        private const val JOURNEY_INTERVAL_MS = 2_500L
        // Start in a new range after process death instead of replacing an old gen_chat_1.
        private val SEQUENCE = AtomicInteger(SecureRandom().nextInt(Int.MAX_VALUE - 1))
        // GenReceiver constructs a new Generator for every broadcast. Sharing these is necessary:
        // a CLEAR from that new instance must invalidate callbacks scheduled by an older instance.
        private val simulation = SimulationSession(::nextSequence)
        private val handler by lazy { Handler(Looper.getMainLooper()) }

        private fun nextSequence(): Int = SEQUENCE.updateAndGet { if (it >= Int.MAX_VALUE - 1) 1 else it + 1 }

        fun tagFor(category: Category, sequence: Int): String = GeneratorTags.forCategory(category, sequence)

        fun ensureChannels(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            NoticeCorpus.CATEGORIES.forEach { category ->
                manager.createNotificationChannel(NotificationChannel(
                    GeneratorChannels.channelIdFor(category),
                    GeneratorChannels.nameFor(category),
                    GeneratorChannels.importanceFor(category),
                ))
            }
        }
    }
}
