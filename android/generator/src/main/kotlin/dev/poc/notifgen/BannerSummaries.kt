package dev.poc.notifgen

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log

/** Maintains one real app group without giving the generator notification-listener access. */
internal class BannerSummaries private constructor(context: Context) {
    private val context = context.applicationContext
    private val manager = this.context.getSystemService(NotificationManager::class.java)
    // Independent from simulation callbacks: stopping sends must still reconcile existing children.
    private val handler = Handler(Looper.getMainLooper())
    private val reconcile = Runnable { refresh() }
    private var lastPlan: BannerSummaryPlan.Upsert? = null

    /** Publish the summary first so a new child is never intentionally posted into an orphan group. */
    fun prepare(child: BannerChild) = refresh(child)

    fun refresh() {
        runCatching { refresh(null) }.onFailure {
            stop()
            Log.w(NoticeCorpus.TAG_LOG, "Unable to reconcile banner group", it)
        }
    }

    fun stop() {
        handler.removeCallbacks(reconcile)
        lastPlan = null
    }

    private fun refresh(pending: BannerChild?) {
        val manager = manager ?: return
        handler.removeCallbacks(reconcile)
        // Android also returns snoozed entries here. They remain posted, unlike dismissed/cancelled
        // entries; no public app API identifies them without notification-listener privileges.
        val active = runCatching { manager.activeNotifications.toList() }.getOrElse {
            Log.w(NoticeCorpus.TAG_LOG, "Unable to read banner group", it)
            return
        }
        val children = active.filter { it.packageName == context.packageName }.map { sbn ->
            val notice = sbn.notification
            BannerChild(
                identity = NoticeIdentity(sbn.tag.orEmpty(), sbn.id),
                title = notice.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty(),
                text = notice.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty(),
                groupKey = notice.group,
                isSummary = notice.flags and Notification.FLAG_GROUP_SUMMARY != 0,
                postedAt = sbn.postTime,
            )
        }
        // A pending replacement must win over its older active snapshot even in the same millisecond.
        val snapshots = if (pending == null) children else
            children.filterNot { it.identity == pending.identity } + pending
        val summaryExists = active.any {
            it.tag == BannerGrouping.SUMMARY_TAG && it.id == BannerGrouping.SUMMARY_ID
        }
        when (val plan = BannerGrouping.plan(snapshots)) {
            BannerSummaryPlan.Cancel -> {
                // Cancelling a summary can cancel children: only do this after observing zero children.
                if (summaryExists) manager.cancel(BannerGrouping.SUMMARY_TAG, BannerGrouping.SUMMARY_ID)
                lastPlan = null
            }
            is BannerSummaryPlan.Upsert -> {
                if (!summaryExists || plan != lastPlan) {
                    manager.createNotificationChannel(NotificationChannel(
                        GeneratorChannels.BANNER_SUMMARY_CHANNEL,
                        "横幅通知汇总",
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply {
                        setSound(null, null)
                        enableVibration(false)
                    })
                    manager.notify(BannerGrouping.SUMMARY_TAG, BannerGrouping.SUMMARY_ID, build(plan))
                    lastPlan = plan
                }
                // getActiveNotifications also reflects removals by the interceptor. Only changed
                // content is notified; this callback neither resends nor caches removed children.
                handler.postDelayed(reconcile, if (pending == null) RECHECK_MS else SETTLE_MS)
            }
        }
    }

    private fun build(plan: BannerSummaryPlan.Upsert): Notification {
        val label = "${plan.childCount} 条通知"
        val inbox = Notification.InboxStyle().setSummaryText(label)
        plan.lines.forEach { inbox.addLine(it) }
        return Notification.Builder(context, GeneratorChannels.BANNER_SUMMARY_CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle("通知生成器 · $label")
            .setContentText(plan.lines.first())
            .setStyle(inbox)
            .setNumber(plan.childCount)
            .setCategory(Notification.CATEGORY_STATUS)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setShowWhen(false)
            .setLocalOnly(true)
            .setGroup(BannerGrouping.GROUP_KEY)
            .setGroupSummary(true)
            .setGroupAlertBehavior(Notification.GROUP_ALERT_CHILDREN)
            .setOnlyAlertOnce(true)
            .setContentIntent(PendingIntent.getActivity(
                context, 0, Intent(context, GeneratorActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ))
            .setDeleteIntent(BannerDismissReceiver.pendingIntent(context))
            .build()
    }

    companion object {
        private const val SETTLE_MS = 1_000L
        private const val RECHECK_MS = 2_500L
        private var instance: BannerSummaries? = null

        // All callers run on the main Looper: Activity, broadcasts and simulation callbacks.
        fun get(context: Context): BannerSummaries = instance ?: BannerSummaries(context).also { instance = it }
    }
}

/** A private PendingIntent callback also reconciles user dismissals after process recreation. */
class BannerDismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_DISMISSED) BannerSummaries.get(context).refresh()
    }

    companion object {
        private const val ACTION_DISMISSED = "dev.poc.notifgen.BANNER_DISMISSED"

        fun pendingIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
            context, 0, Intent(context, BannerDismissReceiver::class.java).setAction(ACTION_DISMISSED),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
