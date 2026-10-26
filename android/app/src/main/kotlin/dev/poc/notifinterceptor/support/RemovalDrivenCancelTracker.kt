package dev.poc.notifinterceptor.support

import dev.poc.notifinterceptor.domain.CancelStatus
import dev.poc.notifinterceptor.domain.CancelTracker
import dev.poc.notifinterceptor.domain.CancelVerifier
import dev.poc.notifinterceptor.domain.HistoryEntry
import dev.poc.notifinterceptor.domain.HistorySink
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor

/**
 * 由 `onNotificationRemoved` 回调驱动的取消确认（方案 A，见 ADR 0008）。
 *
 * 时序：
 *   1. 流水线调用 `cancelNotification` 后立刻 [track]，登记 key → 待确认记录；
 *   2. 系统移除通知时回调 [resolveRemoved]，直接判定 success；
 *   3. 若 [timeoutMillis] 内没有回调（被系统静默拒绝），由 [verifierProvider]
 *      做一次非阻塞复查：通知仍在 → rejected，已不在 → success。
 *
 * 关键点：**确认与落盘都不在取消的关键路径上**。取消线程只做 map 写入，
 * 文件 IO 交给 [executor]，因此"通知从通知栏消失"不再等待历史写盘。
 *
 * [scheduler] 以函数注入，测试里可直接触发超时，无需真实等待。
 */
class RemovalDrivenCancelTracker(
    private val history: HistorySink,
    private val verifierProvider: () -> CancelVerifier?,
    private val executor: Executor,
    private val scheduler: (delayMillis: Long, task: () -> Unit) -> Unit,
    private val timeoutMillis: Long = DEFAULT_TIMEOUT_MS,
    private val onResolved: (HistoryEntry, CancelStatus) -> Unit = { _, _ -> },
) : CancelTracker {

    private val pending = ConcurrentHashMap<String, HistoryEntry>()

    override fun track(key: String, pending: HistoryEntry) {
        this.pending[key] = pending
        scheduler(timeoutMillis) { resolveByTimeout(key) }
    }

    /**
     * 系统回调"通知已移除"。
     *
     * 找不到待确认记录时静默忽略：这说明移除不是我们发起的（用户手动清掉、
     * 应用自己取消），无需回填。若恰好撞上 track 与回调的时序竞争，
     * 超时复查也会给出正确答案，只是晚 [timeoutMillis]。
     *
     * @return 是否命中了一条待确认记录
     */
    fun resolveRemoved(key: String): Boolean {
        val entry = pending.remove(key) ?: return false
        finalize(entry, CancelStatus.SUCCESS)
        return true
    }

    /** 供测试与诊断：当前仍在等待确认的条数。 */
    fun pendingCount(): Int = pending.size

    private fun resolveByTimeout(key: String) {
        val entry = pending.remove(key) ?: return
        val verifier = verifierProvider()
        val status = if (verifier == null) {
            CancelStatus.FAILED
        } else {
            runCatching { verifier.verify(key) }.getOrDefault(CancelStatus.FAILED)
        }
        finalize(entry, status)
    }

    private fun finalize(entry: HistoryEntry, status: CancelStatus) {
        // 落盘在取消线程之外完成：这一步的耗时不再影响通知消失的时间。
        executor.execute {
            val resolved = entry.copy(cancelStatus = status)
            runCatching { history.append(resolved) }
            runCatching { onResolved(entry, status) }
        }
    }

    companion object {
        const val DEFAULT_TIMEOUT_MS = 1_500L
    }
}
