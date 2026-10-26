package dev.poc.notifinterceptor.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 处理流水线的 JVM 测试：用 fake 替身模拟“系统拒绝取消”“取消调用失败”
 * 等真实世界里最难复现的情况。
 */
class NotificationProcessorTest {

    private val history = mutableListOf<HistoryEntry>()
    private val cancelledKeys = mutableListOf<String>()
    private val tracked = mutableListOf<HistoryEntry>()
    private var cancellerResult = true
    private var trackerThrows = false

    private fun processor(
        ruleSet: RuleSet,
        ownPackage: String = OWN_PACKAGE,
    ): NotificationProcessor = NotificationProcessor(
        ownPackage = ownPackage,
        engine = RuleEngine(ownPackage),
        ruleSetProvider = { ruleSet },
        history = { history.add(it) },
        canceller = { key ->
            cancelledKeys.add(key)
            cancellerResult
        },
        tracker = { _, pending ->
            if (trackerThrows) error("boom")
            tracked.add(pending)
        },
        time = { NOW },
        ids = { "fixed-id" },
    )

    @Test
    fun `命中拦截时取消并登记待确认，不阻塞等待结果`() {
        val result = processor(
            RuleSet(rules = listOf(testRule("r1", packages = listOf("com.demo.shop")))),
        ).process(testSnapshot())

        assertTrue(result!!.decision.shouldIntercept)
        assertEquals(listOf("0|com.demo.shop|1|null|10001"), cancelledKeys)
        // 关键：流水线不再返回 success/rejected，只返回 pending，确认交给 tracker。
        assertEquals(CancelStatus.PENDING, result.entry.cancelStatus)
        assertEquals("fixed-id", result.entry.id)
        assertEquals(NOW, result.entry.timestamp)
        assertEquals(1, tracked.size)
        // 确认前不写历史，避免同一条通知出现两条记录。
        assertTrue(history.isEmpty())
    }

    @Test
    fun `取消调用本身失败时立即记录 failed 且不登记待确认`() {
        cancellerResult = false

        val result = processor(
            RuleSet(rules = listOf(testRule("r1", packages = listOf("com.demo.shop")))),
        ).process(testSnapshot())!!

        assertEquals(CancelStatus.FAILED, result.entry.cancelStatus)
        assertTrue(tracked.isEmpty())
        assertEquals(1, history.size)
    }

    @Test
    fun `登记待确认抛异常时降级为乐观记录而不是崩溃`() {
        trackerThrows = true

        val result = processor(
            RuleSet(rules = listOf(testRule("r1", packages = listOf("com.demo.shop")))),
        ).process(testSnapshot())!!

        assertEquals(CancelStatus.PENDING, result.entry.cancelStatus)
        assertEquals(1, history.size)
    }

    @Test
    fun `放行时不调用取消`() {
        val result = processor(RuleSet()).process(testSnapshot())!!

        assertEquals(RuleAction.ALLOW, result.entry.action)
        assertEquals(CancelStatus.NOT_ATTEMPTED, result.entry.cancelStatus)
        assertTrue(cancelledKeys.isEmpty())
        assertTrue(tracked.isEmpty())
    }

    @Test
    fun `仅记录动作不取消但入库`() {
        val result = processor(
            RuleSet(rules = listOf(testRule("log", action = RuleAction.LOG_ONLY, packages = listOf("com.demo.shop")))),
        ).process(testSnapshot())!!

        assertEquals(RuleAction.LOG_ONLY, result.entry.action)
        assertTrue(cancelledKeys.isEmpty())
        assertTrue(tracked.isEmpty())
        assertEquals(1, history.size)
    }

    @Test
    fun `自身包名被跳过且不写历史`() {
        val result = processor(
            RuleSet(rules = listOf(testRule("r1", packages = listOf(OWN_PACKAGE)))),
            ownPackage = OWN_PACKAGE,
        ).process(testSnapshot(packageName = OWN_PACKAGE))

        assertNull(result)
        assertTrue(history.isEmpty())
        assertTrue(cancelledKeys.isEmpty())
    }

    @Test
    fun `全局关闭时记录放行且不取消`() {
        val result = processor(
            RuleSet(
                globalEnabled = false,
                rules = listOf(testRule("r1", packages = listOf("com.demo.shop"))),
            ),
        ).process(testSnapshot())!!

        assertEquals(RuleAction.ALLOW, result.entry.action)
        assertEquals(RuleEngine.REASON_DISABLED, result.decision.reason)
        assertEquals(CancelStatus.NOT_ATTEMPTED, result.entry.cancelStatus)
        assertFalse(cancelledKeys.isNotEmpty())
    }

    @Test
    fun `首条命中决定动作，后续规则不参与`() {
        val result = processor(
            RuleSet(
                rules = listOf(
                    testRule("allow-first", action = RuleAction.ALLOW, packages = listOf("com.demo.shop")),
                    testRule("intercept-second", packages = listOf("com.demo.shop")),
                ),
            ),
        ).process(testSnapshot())!!

        assertEquals("allow-first", result.entry.matchedRuleId)
        assertEquals(CancelStatus.NOT_ATTEMPTED, result.entry.cancelStatus)
        assertTrue(cancelledKeys.isEmpty())
    }

    companion object {
        private const val OWN_PACKAGE = "dev.poc.notifinterceptor"
        private const val NOW = 1_790_000_000_000L
    }
}
