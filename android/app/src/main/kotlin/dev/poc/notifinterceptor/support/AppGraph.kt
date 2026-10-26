package dev.poc.notifinterceptor.support

import android.content.Context
import dev.poc.notifinterceptor.data.AppInfoResolver
import dev.poc.notifinterceptor.data.HistoryRepository
import dev.poc.notifinterceptor.data.RuleRepository
import dev.poc.notifinterceptor.domain.RuleEngine
import dev.poc.notifinterceptor.listener.NotificationInterceptorService
import dev.poc.notifinterceptor.support.RemovalDrivenCancelTracker
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * 进程级依赖装配。监听服务与 UI 共用同一份仓储与引擎实例，
 * 保证"Activity 被销毁后规则仍然生效"。
 */
object AppGraph {

    @Volatile
    private var initialized = false

    lateinit var context: Context
        private set

    lateinit var executor: ExecutorService
        private set

    /**
     * 历史落盘专用线程。写盘（实测 ~115 ms/条）不再占用通知处理队列，
     * 否则批量投递会把写盘时间累积成排队时延。
     */
    lateinit var ioExecutor: ExecutorService
        private set

    /** 对外的历史仓储（UI 读取、清空、导出都走它）。 */
    lateinit var history: HistoryRepository
        private set

    /** 供监听服务使用的异步落盘包装，顺序由 [ioExecutor] 保证。 */
    lateinit var historySink: AsyncHistorySink
        private set

    /** 取消超时复查的定时器。单独一个线程，避免与处理队列互相阻塞。 */
    lateinit var scheduler: ScheduledExecutorService
        private set

    lateinit var cancelTracker: RemovalDrivenCancelTracker
        private set

    lateinit var ruleEngine: RuleEngine
        private set

    lateinit var rules: RuleRepository
        private set

    lateinit var appInfo: AppInfoResolver
        private set

    @Volatile
    var serviceConnected: Boolean = false

    @Volatile
    var listener: NotificationInterceptorService? = null

    fun ensure(context: Context): AppGraph {
        if (initialized) return this
        synchronized(this) {
            if (initialized) return this
            val app = context.applicationContext
            this.context = app
            executor = Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "notif-intercept-worker").apply { isDaemon = true }
            }
            ruleEngine = RuleEngine(app.packageName)
            rules = RuleRepository(app.filesDir, ruleEngine)
            history = HistoryRepository(app.filesDir)
            ioExecutor = Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "notif-history-io").apply { isDaemon = true }
            }
            historySink = AsyncHistorySink(history, ioExecutor)
            appInfo = AppInfoResolver(app)
            scheduler = Executors.newSingleThreadScheduledExecutor { runnable ->
                Thread(runnable, "notif-cancel-timeout").apply { isDaemon = true }
            }
            cancelTracker = RemovalDrivenCancelTracker(
                // 已在 ioExecutor 上执行，直接写仓储，避免二次派发。
                history = history,
                // 服务绑定前拿不到 activeNotifications，因此延后取。
                verifierProvider = { listener?.let { ImmediateCancelVerifier(it) } },
                executor = ioExecutor,
                scheduler = { delay, task ->
                    scheduler.schedule(task, delay, TimeUnit.MILLISECONDS)
                },
            )
            initialized = true
        }
        return this
    }
}
