package dev.poc.notifinterceptor.listener

import android.content.ComponentName
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import dev.poc.notifinterceptor.bridge.EventDispatcher
import dev.poc.notifinterceptor.domain.CancelStatus
import dev.poc.notifinterceptor.domain.NotificationDeduplicator
import dev.poc.notifinterceptor.domain.NotificationProcessor
import dev.poc.notifinterceptor.support.AppGraph
import dev.poc.notifinterceptor.support.NotificationAccess
import dev.poc.notifinterceptor.support.ServiceCanceller
import dev.poc.notifinterceptor.support.SystemTimeSource
import java.util.UUID

/**
 * 系统绑定入口。回调在主线程，只做快照提取；判定/取消/落盘由
 * [NotificationProcessor] 在 AppGraph.executor 上串行执行。
 *
 * 本类只保留 Android 强耦合部分（生命周期、系统 API），业务流水线见
 * NotificationProcessor，可在纯 JVM 中测试。
 */
class NotificationInterceptorService : NotificationListenerService() {

    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var graph: AppGraph
    private lateinit var snapshotFactory: NotificationSnapshotFactory
    private lateinit var processor: NotificationProcessor
    private val deduplicator = NotificationDeduplicator()

    private val rebindRunnable = Runnable {
        runCatching {
            NotificationListenerService.requestRebind(
                ComponentName(this, NotificationInterceptorService::class.java),
            )
        }
    }

    override fun onCreate() {
        super.onCreate()
        graph = AppGraph.ensure(applicationContext)
        snapshotFactory = NotificationSnapshotFactory(applicationContext, graph.appInfo)
        processor = NotificationProcessor(
            ownPackage = packageName,
            engine = graph.ruleEngine,
            ruleSetProvider = { graph.rules.load() },
            history = graph.historySink,
            canceller = ServiceCanceller(this),
            tracker = graph.cancelTracker,
            time = SystemTimeSource,
            ids = { UUID.randomUUID().toString() },
        )
        graph.listener = this
    }

    override fun onDestroy() {
        if (graph.listener === this) {
            graph.listener = null
        }
        graph.serviceConnected = false
        mainHandler.removeCallbacks(rebindRunnable)
        super.onDestroy()
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        graph.serviceConnected = true
        dispatchStatus()
        // 补一次存量快照，避免"打开界面之前的通知"缺失。
        runCatching { activeNotifications }.getOrNull()?.forEach { handle(it, existing = true) }
    }

    override fun onListenerDisconnected() {
        graph.serviceConnected = false
        dispatchStatus()
        mainHandler.removeCallbacks(rebindRunnable)
        mainHandler.postDelayed(rebindRunnable, REBIND_DELAY_MS)
        super.onListenerDisconnected()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        sbn ?: return
        handle(sbn, existing = false)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        sbn ?: return
        // 取消确认走回调驱动：命中待确认记录就立即回填 success，不再轮询等待。
        if (graph.cancelTracker.resolveRemoved(sbn.key)) {
            EventDispatcher.post(
                mapOf(
                    "type" to EVENT_CANCEL_RESOLVED,
                    "key" to sbn.key,
                    "cancelStatus" to CancelStatus.SUCCESS.wire,
                ),
            )
        }
        EventDispatcher.post(
            mapOf(
                "type" to EVENT_REMOVED,
                "key" to sbn.key,
                "id" to sbn.id,
                "packageName" to sbn.packageName,
                "postTime" to sbn.postTime,
            ),
        )
    }

    private fun handle(sbn: StatusBarNotification, existing: Boolean) {
        val snapshot = runCatching { snapshotFactory.create(sbn) }.getOrNull() ?: return
        // 自身通知直接放行且不入库，防止自触发循环。
        if (snapshot.packageName == packageName) return
        // 系统会在 ranking 变化/重新绑定时重复回调同一通知，去重避免重复判定与入库。
        if (!deduplicator.shouldProcess(snapshot)) return

        graph.executor.execute {
            runCatching {
                val result = processor.process(snapshot) ?: return@runCatching
                Log.i(
                    TAG,
                    "pkg=${snapshot.packageName} action=${result.decision.action.wire} " +
                        "rule=${result.decision.ruleId ?: "-"} cancel=${result.entry.cancelStatus.wire}",
                )
                EventDispatcher.post(
                    mapOf(
                        "type" to EVENT_POSTED,
                        "existing" to existing,
                        "record" to result.entry.toMap(),
                        "decision" to result.decision.toMap(),
                    ),
                )
            }
        }
    }

    /** 供 UI 手动取消。 */
    fun cancelByKey(key: String): Boolean = runCatching {
        cancelNotification(key)
        true
    }.getOrDefault(false)

    private fun dispatchStatus() {
        EventDispatcher.post(
            mapOf(
                "type" to EVENT_STATUS,
                "connected" to graph.serviceConnected,
                "granted" to NotificationAccess.isGranted(applicationContext),
            ),
        )
    }

    companion object {
        private const val TAG = "NotifInterceptor"

        const val EVENT_POSTED = "posted"
        const val EVENT_REMOVED = "removed"
        const val EVENT_STATUS = "statusChanged"

        /** 取消确认完成。Dart 侧当前忽略该事件，历史页打开时会读到最终值。 */
        const val EVENT_CANCEL_RESOLVED = "cancelResolved"

        private const val REBIND_DELAY_MS = 5_000L
    }
}
