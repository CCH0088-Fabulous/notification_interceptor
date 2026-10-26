package dev.poc.notifinterceptor.domain

/** 历史落盘接口。domain 不依赖文件系统，便于用内存实现做单测。 */
fun interface HistorySink {
    fun append(entry: HistoryEntry)
}

/** 取消通知的外设接口。返回 false 表示调用本身失败（不是被系统拒绝）。 */
fun interface NotificationCanceller {
    fun cancel(key: String): Boolean
}

/** 取消后的效果校验。真实实现会延迟查询活动通知，测试用固定返回值。 */
fun interface CancelVerifier {
    fun verify(key: String): CancelStatus
}

/**
 * 取消请求发出后的确认环节。
 *
 * `cancelNotification` 是异步的：调用返回只代表请求被系统接受，通知是否真的消失
 * 要等 `onNotificationRemoved` 回调。把确认放在处理流水线里同步等待，会让"通知消失"
 * 与"记录完成"互相拖累（实测多付 250 ms/条，批量场景再被串行放大）。
 *
 * 因此流水线只负责**发出请求并登记**，确认与落盘交给 [CancelTracker]。
 */
fun interface CancelTracker {
    /** 登记一条"已发出取消请求、尚未确认"的记录。 */
    fun track(key: String, pending: HistoryEntry)
}

fun interface TimeSource {
    fun now(): Long
}

fun interface IdFactory {
    fun next(): String
}

data class ProcessResult(
    val entry: HistoryEntry,
    val decision: Decision,
)

/**
 * 单条通知的完整处理流程：判定 → 取消 → 登记待确认 → 落盘。
 *
 * 这里刻意不依赖 `android.*`、线程与真实文件：
 * - 线程调度留在 Service；
 * - 取消通过 [NotificationCanceller] 注入，确认通过 [CancelTracker] 注入；
 * - 时间与 id 通过 [TimeSource] / [IdFactory] 注入，保证测试可断言。
 */
class NotificationProcessor(
    private val ownPackage: String,
    private val engine: RuleEngine,
    private val ruleSetProvider: () -> RuleSet,
    private val history: HistorySink,
    private val canceller: NotificationCanceller,
    private val tracker: CancelTracker,
    private val time: TimeSource,
    private val ids: IdFactory,
) {

    /** @return null 表示该通知被跳过（自身包名），不写历史。 */
    fun process(snapshot: NotificationSnapshot): ProcessResult? {
        if (snapshot.packageName == ownPackage) return null

        val ruleSet = ruleSetProvider()
        val decision = engine.evaluate(ruleSet, snapshot)

        if (!decision.shouldIntercept) {
            val entry = buildEntry(snapshot, decision, CancelStatus.NOT_ATTEMPTED)
            history.append(entry)
            return ProcessResult(entry, decision)
        }

        val requested = runCatching { canceller.cancel(snapshot.key) }.getOrDefault(false)
        if (!requested) {
            val entry = buildEntry(snapshot, decision, CancelStatus.FAILED)
            history.append(entry)
            return ProcessResult(entry, decision)
        }

        // 取消已发出，但尚未确认。先给调用方一个即时结果，历史等确认后再补写。
        val pending = buildEntry(snapshot, decision, CancelStatus.PENDING)
        val tracked = runCatching { tracker.track(snapshot.key, pending) }.isSuccess
        if (!tracked) {
            // 无法登记时退化为乐观记录，避免这条通知既没取消记录也查不到去向。
            history.append(pending)
        }
        return ProcessResult(pending, decision)
    }

    private fun buildEntry(
        snapshot: NotificationSnapshot,
        decision: Decision,
        cancelStatus: CancelStatus,
    ): HistoryEntry = HistoryEntry(
        id = ids.next(),
        timestamp = time.now(),
        snapshot = snapshot,
        action = decision.action,
        matchedRuleId = decision.ruleId,
        matchedRuleName = decision.ruleName,
        cancelStatus = cancelStatus,
    )
}
