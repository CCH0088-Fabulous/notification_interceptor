package dev.poc.notifinterceptor.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

class RuleEngineTest {

    private val zone = ZoneId.of("Asia/Shanghai")
    private val engine = RuleEngine(OWN_PACKAGE)

    @Test
    fun `a4 首个命中的规则生效，后续规则不再求值`() {
        val ruleSet = RuleSet(
            rules = listOf(
                rule(id = "allow-chat", action = RuleAction.ALLOW, packages = listOf("com.demo.chat")),
                rule(id = "block-all", action = RuleAction.INTERCEPT, packages = listOf("com.demo.chat")),
            ),
        )

        val decision = engine.evaluate(ruleSet, snapshot(packageName = "com.demo.chat"), NOW, zone)

        assertEquals("allow-chat", decision.ruleId)
        assertEquals(RuleAction.ALLOW, decision.action)
        assertEquals(RuleEngine.REASON_RULE, decision.reason)
    }

    @Test
    fun `a4 没有任何条件的规则永不命中`() {
        val ruleSet = RuleSet(rules = listOf(rule(id = "empty", action = RuleAction.INTERCEPT)))

        val decision = engine.evaluate(ruleSet, snapshot(), NOW, zone)

        assertNull(decision.ruleId)
        assertEquals(RuleAction.ALLOW, decision.action)
        assertEquals(RuleEngine.REASON_DEFAULT, decision.reason)
    }

    @Test
    fun `a4 非法正则会跳过该规则并继续匹配后续规则`() {
        val ruleSet = RuleSet(
            rules = listOf(
                rule(id = "broken", action = RuleAction.INTERCEPT, titleRegex = "(["),
                rule(id = "valid", action = RuleAction.INTERCEPT, keywords = listOf("秒杀")),
            ),
        )

        val decision = engine.evaluate(ruleSet, snapshot(title = "今日秒杀"), NOW, zone)

        assertEquals("valid", decision.ruleId)
        assertTrue(engine.validate(ruleSet).any { it.ruleId == "broken" && it.field == "titleRegex" })
    }

    @Test
    fun `全局开关关闭时一律放行`() {
        val ruleSet = RuleSet(
            globalEnabled = false,
            rules = listOf(rule(id = "block", action = RuleAction.INTERCEPT, packages = listOf("com.demo.shop"))),
        )

        val decision = engine.evaluate(ruleSet, snapshot(packageName = "com.demo.shop"), NOW, zone)

        assertEquals(RuleAction.ALLOW, decision.action)
        assertEquals(RuleEngine.REASON_DISABLED, decision.reason)
    }

    @Test
    fun `自身包名一律放行`() {
        val ruleSet = RuleSet(
            rules = listOf(rule(id = "block", action = RuleAction.INTERCEPT, packages = listOf(OWN_PACKAGE))),
        )

        val decision = engine.evaluate(ruleSet, snapshot(packageName = OWN_PACKAGE), NOW, zone)

        assertEquals(RuleAction.ALLOW, decision.action)
        assertEquals(RuleEngine.REASON_SELF, decision.reason)
    }

    @Test
    fun `关键词匹配不区分大小写且覆盖大文本`() {
        val ruleSet = RuleSet(
            rules = listOf(rule(id = "promo", action = RuleAction.INTERCEPT, keywords = listOf("Limited Offer"))),
        )

        val decision = engine.evaluate(
            ruleSet,
            snapshot(bigText = "今天有限时 LIMITED OFFER 活动"),
            NOW,
            zone,
        )

        assertEquals("promo", decision.ruleId)
    }

    @Test
    fun `mode=any 时任一条件组命中即匹配`() {
        val ruleSet = RuleSet(
            rules = listOf(
                rule(
                    id = "any",
                    action = RuleAction.INTERCEPT,
                    mode = MatchMode.ANY,
                    packages = listOf("com.demo.shop"),
                    keywords = listOf("不存在的词"),
                ),
            ),
        )

        val decision = engine.evaluate(ruleSet, snapshot(packageName = "com.demo.shop"), NOW, zone)

        assertEquals("any", decision.ruleId)
    }

    @Test
    fun `mode=all 时任一条件组不满足则不匹配`() {
        val ruleSet = RuleSet(
            rules = listOf(
                rule(
                    id = "all",
                    action = RuleAction.INTERCEPT,
                    packages = listOf("com.demo.shop"),
                    keywords = listOf("不存在的词"),
                ),
            ),
        )

        val decision = engine.evaluate(ruleSet, snapshot(packageName = "com.demo.shop"), NOW, zone)

        assertNull(decision.ruleId)
        assertEquals(RuleAction.ALLOW, decision.action)
    }

    @Test
    fun `按渠道与 ongoing 过滤`() {
        val ruleSet = RuleSet(
            rules = listOf(
                rule(
                    id = "channel",
                    action = RuleAction.INTERCEPT,
                    channelIds = listOf("marketing"),
                    isOngoing = false,
                ),
            ),
        )

        assertTrue(
            engine.evaluate(
                ruleSet,
                snapshot(channelId = "marketing", isOngoing = false),
                NOW,
                zone,
            ).shouldIntercept,
        )
        assertFalse(
            engine.evaluate(
                ruleSet,
                snapshot(channelId = "marketing", isOngoing = true),
                NOW,
                zone,
            ).shouldIntercept,
        )
    }

    @Test
    fun `静默时段跨界判定按起始日计算`() {
        val quiet = QuietHours(fromMinutes = 22 * 60, toMinutes = 8 * 60, days = (1..7).toSet())

        // 2026-10-17 是周六（ISO 6），23:30 命中
        assertTrue(quiet.matches(millisOf(2026, 10, 17, 23, 30), zone))
        // 次日 02:00 属于周五（ISO 5）发起的窗口，仍然命中
        assertTrue(quiet.matches(millisOf(2026, 10, 18, 2, 0), zone))
        // 中午不命中
        assertFalse(quiet.matches(millisOf(2026, 10, 17, 12, 0), zone))
    }

    @Test
    fun `静默时段只包含指定起始日`() {
        val quiet = QuietHours(fromMinutes = 22 * 60, toMinutes = 8 * 60, days = setOf(6))

        assertTrue(quiet.matches(millisOf(2026, 10, 17, 23, 0), zone))  // 周六起点，命中
        assertTrue(quiet.matches(millisOf(2026, 10, 18, 2, 0), zone))   // 周日凌晨，起点仍是周六
        assertFalse(quiet.matches(millisOf(2026, 10, 18, 23, 0), zone)) // 周日起点不在集合内
    }

    @Test
    fun `静默时段同日起止视为空窗口`() {
        val quiet = QuietHours(fromMinutes = 60, toMinutes = 60, days = (1..7).toSet())
        assertFalse(quiet.matches(millisOf(2026, 10, 17, 1, 30), zone))
        assertTrue(engine.validate(RuleSet(rules = listOf(rule(id = "q", quiet = quiet)))).any {
            it.field == "quietHours"
        })
    }

    @Test
    fun `默认动作在无规则命中时生效`() {
        val ruleSet = RuleSet(defaultAction = RuleAction.LOG_ONLY)

        val decision = engine.evaluate(ruleSet, snapshot(), NOW, zone)

        assertEquals(RuleAction.LOG_ONLY, decision.action)
        assertEquals(RuleEngine.REASON_DEFAULT, decision.reason)
    }

    @Test
    fun `规则集合可以完成 map 往返`() {
        val original = RuleSet(
            rules = listOf(
                rule(
                    id = "r1",
                    action = RuleAction.INTERCEPT,
                    packages = listOf("com.demo.shop"),
                    keywords = listOf("秒杀"),
                    titleRegex = "优惠",
                    channelIds = listOf("marketing"),
                    quiet = QuietHours(22 * 60, 8 * 60, setOf(1, 2, 3)),
                ),
            ),
        )

        val restored = RuleSet.fromMap(original.toMap())

        assertEquals(original, restored)
        assertEquals(RuleSet.CURRENT_SCHEMA_VERSION, restored.schemaVersion)
    }

    @Test
    fun `历史记录可以完成 map 往返`() {
        val entry = HistoryEntry(
            id = "h1",
            timestamp = NOW,
            snapshot = snapshot(packageName = "com.demo.shop"),
            action = RuleAction.INTERCEPT,
            matchedRuleId = "r1",
            matchedRuleName = "屏蔽营销",
            cancelStatus = CancelStatus.SUCCESS,
        )

        val restored = HistoryEntry.fromMap(entry.toMap())

        assertEquals(entry, restored)
    }

    @Test
    fun `损坏的历史记录返回 null 而不是抛异常`() {
        assertNull(HistoryEntry.fromMap(mapOf("timestamp" to 1)))
    }

    private fun rule(
        id: String,
        action: RuleAction = RuleAction.INTERCEPT,
        mode: MatchMode = MatchMode.ALL,
        packages: List<String> = emptyList(),
        keywords: List<String> = emptyList(),
        titleRegex: String? = null,
        channelIds: List<String> = emptyList(),
        isOngoing: Boolean? = null,
        quiet: QuietHours? = null,
    ) = RuleSpec(
        id = id,
        name = id,
        action = action,
        mode = mode,
        packages = packages,
        keywordsAny = keywords,
        titleRegex = titleRegex,
        channelIds = channelIds,
        isOngoing = isOngoing,
        quietHours = quiet,
    )

    private fun snapshot(
        packageName: String = "com.demo.shop",
        title: String? = "标题",
        text: String? = "正文",
        bigText: String? = null,
        channelId: String? = "default",
        isOngoing: Boolean = false,
        isClearable: Boolean = true,
    ) = NotificationSnapshot(
        key = "0|$packageName|1|null|10001",
        id = 1,
        packageName = packageName,
        appLabel = "演示",
        postTime = NOW,
        title = title,
        text = text,
        bigText = bigText,
        textLines = emptyList(),
        subText = null,
        tickerText = null,
        category = "msg",
        channelId = channelId,
        channelName = "默认",
        groupKey = null,
        isGroupSummary = false,
        isOngoing = isOngoing,
        isClearable = isClearable,
        priority = 0,
        progress = -1,
        extras = emptyMap(),
    )

    private fun millisOf(year: Int, month: Int, day: Int, hour: Int, minute: Int): Long =
        LocalDateTime.of(year, month, day, hour, minute)
            .atZone(zone)
            .toInstant()
            .toEpochMilli()

    companion object {
        private const val OWN_PACKAGE = "dev.poc.notifinterceptor"
        private val NOW = 1_760_000_000_000L
    }
}
