package dev.poc.notifinterceptor.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

/**
 * 随机化测试：真实设备上的通知内容不可预测，这里用固定种子生成
 * 大量畸形输入（空标题、超长文本、正则元字符、重复 id、非法正则），
 * 断言引擎“永不抛异常、结果确定、安全边界不被突破”。
 */
class RuleEngineStressTest {

    private val random = Random(20261017L)

    @Test
    fun `随机规则与快照永不抛异常且结果确定`() {
        repeat(500) { iteration ->
            val ruleSet = randomRuleSet()
            val snapshot = randomSnapshot()

            val first = engine.evaluate(ruleSet, snapshot, NOW, zone)
            val second = engine.evaluate(ruleSet, snapshot, NOW, zone)

            assertEquals("第 $iteration 轮结果不稳定", first, second)
        }
    }

    @Test
    fun `全局关闭时任何随机规则都放行`() {
        repeat(200) {
            val ruleSet = randomRuleSet().copy(globalEnabled = false)
            val decision = engine.evaluate(ruleSet, randomSnapshot(), NOW, zone)
            assertEquals(RuleAction.ALLOW, decision.action)
            assertEquals(RuleEngine.REASON_DISABLED, decision.reason)
        }
    }

    @Test
    fun `自身包名在任意随机规则下都放行`() {
        repeat(200) {
            val ruleSet = randomRuleSet()
            val decision = engine.evaluate(
                ruleSet,
                randomSnapshot().copy(packageName = OWN_PACKAGE),
                NOW,
                zone,
            )
            assertEquals(RuleAction.ALLOW, decision.action)
            // 全局关闭的优先级高于“自身包名”，两者都放行但原因不同。
            val expectedReason =
                if (ruleSet.globalEnabled) RuleEngine.REASON_SELF else RuleEngine.REASON_DISABLED
            assertEquals(expectedReason, decision.reason)
        }
    }

    @Test
    fun `超长文本与正则元字符不会导致匹配异常`() {
        val ruleSet = RuleSet(
            rules = listOf(
                testRule(
                    "meta",
                    keywords = listOf(".*", "(", "[", "\\", "$^"),
                    titleRegex = ".*",
                    textRegex = "[\\s\\S]*",
                ),
            ),
        )
        val snapshot = testSnapshot(
            title = "(".repeat(500),
            text = "[".repeat(1000),
            bigText = "x".repeat(10_000),
        )

        val decision = engine.evaluate(ruleSet, snapshot, NOW, zone)

        assertFalse(decision.reason.isEmpty())
        assertTrue(engine.validate(ruleSet).isEmpty())
    }

    private fun randomRuleSet(): RuleSet {
        val rules = (0 until random.nextInt(0, 5)).map { index ->
            testRule(
                id = if (random.nextInt(10) == 0) "dup" else "r$index",
                action = RuleAction.entries[random.nextInt(RuleAction.entries.size)],
                mode = MatchMode.entries[random.nextInt(MatchMode.entries.size)],
                packages = randomStrings(listOf("com.demo.shop", OWN_PACKAGE, "")),
                keywords = randomStrings(listOf("秒杀", "促销", "", " ", ".*")),
                titleRegex = randomRegex(),
                textRegex = randomRegex(),
                channelIds = randomStrings(listOf("marketing", "default")),
                isOngoing = listOf(null, true, false)[random.nextInt(3)],
                isClearable = listOf(null, true, false)[random.nextInt(3)],
                enabled = random.nextInt(5) != 0,
            )
        }
        return RuleSet(
            globalEnabled = random.nextInt(10) != 0,
            defaultAction = RuleAction.entries[random.nextInt(RuleAction.entries.size)],
            rules = rules,
        )
    }

    private fun randomSnapshot(): NotificationSnapshot = testSnapshot(
        packageName = listOf("com.demo.shop", OWN_PACKAGE, "com.other")[random.nextInt(3)],
        title = listOf(null, "", "秒杀提醒", "(".repeat(50))[random.nextInt(4)],
        text = listOf(null, "", "限时优惠", "x".repeat(2000))[random.nextInt(4)],
        bigText = if (random.nextBoolean()) "红包大放送" else null,
        channelId = listOf(null, "marketing", "default")[random.nextInt(3)],
        isOngoing = random.nextBoolean(),
        isClearable = random.nextBoolean(),
    )

    private fun randomStrings(pool: List<String>): List<String> =
        (0 until random.nextInt(0, 4)).map { pool[random.nextInt(pool.size)] }

    private fun randomRegex(): String? = listOf(
        null,
        "优惠|限时",
        "([",
        "",
        "a".repeat(300),
        ".*",
    )[random.nextInt(6)]

    companion object {
        private const val OWN_PACKAGE = "dev.poc.notifinterceptor"
        private const val NOW = 1_790_000_000_000L
        private val zone = java.time.ZoneId.of("Asia/Shanghai")
        private val engine = RuleEngine(OWN_PACKAGE)
    }
}
