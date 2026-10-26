package dev.poc.notifinterceptor.support

import dev.poc.notifinterceptor.domain.CancelStatus
import dev.poc.notifinterceptor.domain.HistoryEntry
import dev.poc.notifinterceptor.domain.RuleAction
import dev.poc.notifinterceptor.domain.testSnapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.Executor

class AsyncHistorySinkTest {

    private val written = mutableListOf<HistoryEntry>()

    private fun sink(failOnWrite: Boolean = false): AsyncHistorySink = AsyncHistorySink(
        delegate = { entry ->
            if (failOnWrite) error("disk full")
            written.add(entry)
        },
        executor = Executor { it.run() },
    )

    private fun entry(id: String): HistoryEntry = HistoryEntry(
        id = id,
        timestamp = 1_790_000_000_000L,
        snapshot = testSnapshot(),
        action = RuleAction.INTERCEPT,
        matchedRuleId = "r1",
        matchedRuleName = null,
        cancelStatus = CancelStatus.SUCCESS,
    )

    @Test
    fun `写入按提交顺序落到下游`() {
        val sink = sink()
        sink.append(entry("a"))
        sink.append(entry("b"))
        sink.append(entry("c"))

        assertEquals(listOf("a", "b", "c"), written.map { it.id })
    }

    @Test
    fun `下游写盘异常不会抛回调用线程`() {
        val sink = sink(failOnWrite = true)

        // 写盘失败只应丢掉这条记录，不能让通知处理线程崩溃。
        sink.append(entry("a"))

        assertTrue(written.isEmpty())
    }
}
