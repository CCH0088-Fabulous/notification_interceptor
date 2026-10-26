package dev.poc.notifinterceptor.support

import dev.poc.notifinterceptor.domain.CancelStatus
import dev.poc.notifinterceptor.domain.CancelVerifier
import dev.poc.notifinterceptor.domain.HistoryEntry
import dev.poc.notifinterceptor.domain.RuleAction
import dev.poc.notifinterceptor.domain.testSnapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.Executor

/**
 * 取消确认（方案 A）的纯 JVM 测试。
 *
 * 三个必须覆盖的时序：回调先到、超时后复查、以及复查给出拒绝。
 */
class RemovalDrivenCancelTrackerTest {

    private val completed = mutableListOf<HistoryEntry>()
    private val resolutions = mutableListOf<Pair<String, CancelStatus>>()
    private val scheduled = mutableListOf<Pair<Long, () -> Unit>>()
    private var verifierResult: CancelStatus = CancelStatus.REJECTED
    private var verifierCalls = 0
    private var hasVerifier = true

    private fun tracker(): RemovalDrivenCancelTracker = RemovalDrivenCancelTracker(
        history = { completed.add(it) },
        verifierProvider = {
            if (!hasVerifier) {
                null
            } else {
                CancelVerifier { _ ->
                    verifierCalls++
                    verifierResult
                }
            }
        },
        executor = Executor { it.run() },
        scheduler = { delay, task -> scheduled.add(delay to task) },
        onResolved = { entry, status -> resolutions.add(entry.id to status) },
    )

    private fun pendingEntry(key: String = KEY, id: String = "id-1"): HistoryEntry = HistoryEntry(
        id = id,
        timestamp = NOW,
        snapshot = testSnapshot(),
        action = RuleAction.INTERCEPT,
        matchedRuleId = "r1",
        matchedRuleName = null,
        cancelStatus = CancelStatus.PENDING,
    )

    @Test
    fun `系统回调移除时立即回填 success 且不再走超时`() {
        val tracker = tracker()
        tracker.track(KEY, pendingEntry())

        assertTrue(tracker.resolveRemoved(KEY))
        assertEquals(CancelStatus.SUCCESS, completed.single().cancelStatus)
        assertEquals("id-1" to CancelStatus.SUCCESS, resolutions.single())
        assertEquals(0, tracker.pendingCount())
        assertEquals(0, verifierCalls)
    }

    @Test
    fun `超时后单次复查发现已移除则记为 success`() {
        verifierResult = CancelStatus.SUCCESS
        val tracker = tracker()
        tracker.track(KEY, pendingEntry())

        scheduled.single().second.invoke()

        assertEquals(1, verifierCalls)
        assertEquals(CancelStatus.SUCCESS, completed.single().cancelStatus)
        assertEquals(0, tracker.pendingCount())
    }

    @Test
    fun `超时后复查发现通知仍在则记为 rejected`() {
        verifierResult = CancelStatus.REJECTED
        val tracker = tracker()
        tracker.track(KEY, pendingEntry())

        scheduled.single().second.invoke()

        assertEquals(CancelStatus.REJECTED, completed.single().cancelStatus)
        assertEquals(CancelStatus.REJECTED, resolutions.single().second)
    }

    @Test
    fun `拿不到服务时超时降级为 failed 而不是卡住`() {
        hasVerifier = false
        val tracker = tracker()
        tracker.track(KEY, pendingEntry())

        scheduled.single().second.invoke()

        assertEquals(0, verifierCalls)
        assertEquals(CancelStatus.FAILED, completed.single().cancelStatus)
    }

    @Test
    fun `复查抛异常时降级为 failed`() {
        val tracker = RemovalDrivenCancelTracker(
            history = { completed.add(it) },
            verifierProvider = { CancelVerifier { _ -> error("boom") } },
            executor = Executor { it.run() },
            scheduler = { _, task -> scheduled.add(0L to task) },
        )
        tracker.track(KEY, pendingEntry())

        scheduled.single().second.invoke()

        assertEquals(CancelStatus.FAILED, completed.single().cancelStatus)
    }

    @Test
    fun `回调与超时重复触发时只落盘一次`() {
        val tracker = tracker()
        tracker.track(KEY, pendingEntry())

        tracker.resolveRemoved(KEY)
        scheduled.single().second.invoke()

        assertEquals(1, completed.size)
        assertEquals(0, verifierCalls)
    }

    @Test
    fun `未登记过的 key 被移除时静默忽略`() {
        val tracker = tracker()

        assertFalse(tracker.resolveRemoved("0|com.demo.shop|9|null|10001"))

        assertTrue(completed.isEmpty())
        assertTrue(resolutions.isEmpty())
    }

    @Test
    fun `超时时间使用默认的一秒半`() {
        val tracker = tracker()
        tracker.track(KEY, pendingEntry())

        assertEquals(RemovalDrivenCancelTracker.DEFAULT_TIMEOUT_MS, scheduled.single().first)
    }

    companion object {
        private const val KEY = "0|com.demo.shop|1|null|10001"
        private const val NOW = 1_790_000_000_000L
    }
}
