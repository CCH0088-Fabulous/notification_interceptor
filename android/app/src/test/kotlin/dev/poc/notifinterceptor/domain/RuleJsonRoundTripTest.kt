package dev.poc.notifinterceptor.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 用"运行时实际落盘的那份 JSON"验证规则能被加载并命中，
 * 覆盖 Json -> RuleSet -> RuleEngine 的整条链路。
 */
class RuleJsonRoundTripTest {

    private val raw = """
        {"schemaVersion":1,"globalEnabled":true,"defaultAction":"allow","rules":[{"id":"r1","name":"拦截 shell 营销","enabled":true,"action":"intercept","match":{"mode":"all","packages":["com.android.shell"],"keywordsAny":["秒杀"],"channelIds":[],"quietHours":null}}]}
    """.trimIndent()

    @Test
    fun `磁盘上的规则 JSON 可以加载并命中`() {
        val parsed = dev.poc.notifinterceptor.data.Json.parseObject(raw)
        assertTrue("JSON 解析失败", parsed != null)

        val ruleSet = RuleSet.fromMap(parsed!!)
        assertEquals(1, ruleSet.rules.size)
        assertEquals(RuleAction.INTERCEPT, ruleSet.rules.single().action)

        val snapshot = NotificationSnapshot(
            key = "0|com.android.shell|2020|demo_tag|2000",
            id = 2020,
            packageName = "com.android.shell",
            appLabel = "Shell",
            postTime = 1L,
            title = "秒杀提醒",
            text = "限时优惠",
            bigText = null,
            textLines = emptyList(),
            subText = null,
            tickerText = null,
            category = null,
            channelId = "shell_cmd",
            channelName = null,
            groupKey = null,
            isGroupSummary = false,
            isOngoing = false,
            isClearable = true,
            priority = 0,
            progress = -1,
            extras = emptyMap(),
        )

        val decision = RuleEngine("dev.poc.notifinterceptor").evaluate(ruleSet, snapshot)
        assertEquals("r1", decision.ruleId)
        assertEquals(RuleAction.INTERCEPT, decision.action)
    }
}
