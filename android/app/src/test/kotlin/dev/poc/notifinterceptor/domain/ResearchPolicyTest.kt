package dev.poc.notifinterceptor.domain

import dev.poc.notifinterceptor.data.Json
import dev.poc.notifinterceptor.data.ResearchSettings
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

class ResearchPolicyTest {
    private fun entry(status: CancelStatus = CancelStatus.PENDING, action: RuleAction = RuleAction.INTERCEPT) = HistoryEntry(
        "event-id", 1_793_000_000_000, testSnapshot(title = "PRIVATE_PERSON", text = "PRIVATE_CONTENT"),
        action, "PRIVATE_RULE", "PRIVATE_NAME", status,
    )

    @Test fun `通知只输出计数 不含正文且存量与取消确认分开`() {
        assertEquals(mapOf("processed" to 1L, "intercept_matched" to 1L), ResearchPolicy.observed(entry(), false))
        val final = ResearchPolicy.observed(entry(CancelStatus.SUCCESS), true)
        assertEquals(1L, final["existing_cancel_success"])
        assertEquals(1L, final["existing_processed"])
        assertFalse(final.containsKey("cancel_success"))
        assertFalse(Json.stringify(final).contains("PRIVATE"))
        assertEquals(mapOf("processed" to 1L, "allow" to 1L), ResearchPolicy.observed(entry(CancelStatus.NOT_ATTEMPTED, RuleAction.ALLOW), false))
    }

    @Test fun `系统汇总单列 演示包不进入真实试用`() {
        val summary = entry().let { it.copy(snapshot = it.snapshot.copy(isGroupSummary = true)) }
        assertEquals(mapOf("summaries_excluded" to 1L), ResearchPolicy.observed(summary, false))
        assertEquals("demo", ResearchPolicy.cohort("pilot", "dev.poc.notifgen"))
        assertEquals("demo", ResearchPolicy.cohort("pilot", "dev.poc.probe"))
        assertEquals("demo", ResearchPolicy.cohort("pilot", "com.android.shell"))
        assertEquals("pilot", ResearchPolicy.cohort("pilot", "com.example.personal"))
    }

    @Test fun `常驻的所有动作与取消结果只记排除诊断 不进入通知处理量`() {
        for (action in RuleAction.entries) {
            for (status in CancelStatus.entries) {
                val ongoing = entry(status, action).let { it.copy(snapshot = it.snapshot.copy(isOngoing = true)) }
                assertFalse(ongoing.snapshot.countsTowardStatistics)
                for (existing in listOf(false, true)) {
                    val observed = ResearchPolicy.observed(ongoing, existing)
                    assertEquals(mapOf("ongoing_excluded" to 1L), observed)
                    assertEquals(observed, ResearchPolicy.validateMetrics(observed))
                }
            }
        }
        val ordinary = entry().snapshot.copy(isClearable = false)
        assertTrue(ordinary.countsTowardStatistics)
        val both = entry().let { it.copy(snapshot = it.snapshot.copy(isOngoing = true, isGroupSummary = true)) }
        assertEquals(mapOf("summaries_excluded" to 1L), ResearchPolicy.observed(both, false))
    }

    @Test fun `结构统计不包含私有词 名称 ID 包名 正则或精确日程`() {
        val rule = testRule("PRIVATE_RULE", packages = listOf("PRIVATE_APP"), keywords = listOf("PRIVATE_PERSON", "PRIVATE_PROJECT"), titleRegex = "PRIVATE_REGEX")
        val output = ResearchPolicy.ruleStructures(RuleSet(rules = listOf(rule, rule.copy(id = "PRIVATE_OTHER"))))
        assertEquals(1, output.size)
        assertEquals(2, output.single()["count"])
        assertEquals("2-5", output.single()["keywordCountBand"])
        assertEquals(true, output.single()["hasRegex"])
        assertFalse(Json.stringify(output).contains("PRIVATE"))
        assertEquals("scene", ResearchPolicy.ruleStructures(RuleSet(rules = listOf(rule.copy(id = "preset:scene:secret:allow")))).single()["kind"])
    }

    @Test fun `仅调试固定回环支持明文 目的地不能夹带凭据或查询`() {
        assertEquals("https://research.example/upload", ResearchPolicy.endpoint(" https://research.example/upload ", false))
        assertEquals("http://10.0.2.2:8765/upload", ResearchPolicy.endpoint("http://10.0.2.2:8765/upload", true))
        listOf("http://research.example/upload", "https://user:secret@example.com/upload", "https://example.com/?token=secret", "https://example.com/#secret", "file:///tmp/x", "https://example.com:0/x").forEach {
            assertThrows(IllegalArgumentException::class.java) { ResearchPolicy.endpoint(it, true) }
        }
        assertThrows(IllegalArgumentException::class.java) { ResearchPolicy.endpoint("http://127.0.0.1/upload", false) }
    }

    @Test fun `事件白名单和数值边界阻止自由文本及负数`() {
        assertThrows(IllegalArgumentException::class.java) { ResearchPolicy.validateMetrics(mapOf("PRIVATE_PERSON" to 1)) }
        assertThrows(IllegalArgumentException::class.java) { ResearchPolicy.validateMetrics(mapOf("processed" to -1)) }
        assertEquals(emptyMap<String, Long>(), ResearchPolicy.validateMetrics(mapOf("processed" to 0)))
    }

    @Test fun `单调计时跨小时切片保留时区及精确总量`() {
        val end = Instant.parse("2026-11-09T01:00:10Z").toEpochMilli()
        val slices = ResearchPolicy.durationSlices(end, 20_000, ZoneId.of("Asia/Shanghai"))
        assertEquals(2, slices.size)
        assertEquals(listOf(10_000L, 10_000L), slices.map { it.second.second })
        assertTrue(slices.all { it.second.first == 480 })
        assertEquals(ResearchPolicy.HOUR_MS, slices[1].first - slices[0].first)
        assertThrows(IllegalArgumentException::class.java) { ResearchPolicy.durationSlices(end, 90_001, ZoneId.of("UTC")) }
        assertTrue(ResearchPolicy.durationSlices(end, 0, ZoneId.of("UTC")).isEmpty())
    }

    @Test fun `规则变更计数区分新增删除条件变化与单独开关`() {
        val before = RuleSet(rules = listOf(testRule("edited"), testRule("toggle"), testRule("removed")))
        val after = RuleSet(globalEnabled = false, rules = listOf(testRule("edited", keywords = listOf("private")), testRule("toggle", enabled = false), testRule("added")))
        val counts = ResearchPolicy.rulesChanged(before, after)
        listOf("rules_added", "rules_removed", "rules_modified", "rules_toggled", "global_toggled").forEach { assertEquals(1L, counts[it]) }
    }

    @Test fun `公开配置从不返回原令牌或密文`() {
        val output = ResearchSettings(token = "PRIVATE_SECRET").publicMap()
        assertEquals(true, output["hasToken"])
        assertFalse(output.containsKey("token"))
        assertFalse(output.containsKey("encryptedToken"))
        assertFalse(Json.stringify(output).contains("PRIVATE_SECRET"))
    }

    @Test fun `观察钩子先于取消确认 且钩子失败不影响过滤`() {
        val order = mutableListOf<String>()
        val processor = NotificationProcessor("self", RuleEngine("self"), { RuleSet(rules = listOf(testRule("drop", keywords = listOf("标题")))) },
            history = {}, canceller = { true }, tracker = { _, _ -> order.add("track") },
            time = { 123 }, ids = { "id" }, onObserved = { _, existing -> order.add("observed:$existing"); error("observer failed") })
        assertEquals(CancelStatus.PENDING, processor.process(testSnapshot(), existing = true)!!.entry.cancelStatus)
        assertEquals(listOf("observed:true", "track"), order)
    }
}
