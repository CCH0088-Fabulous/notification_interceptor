package dev.poc.notifinterceptor.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

class RuleSetComparisonTest {
    private val zone = ZoneId.of("Asia/Shanghai")
    private val comparison = RuleSetComparison(RuleEngine("dev.poc.notifinterceptor"))

    private fun sample(
        id: String,
        time: String = "2026-11-06T23:00:00",
        title: String = "促销提醒",
        pkg: String = "com.demo.shop",
    ): Map<String, Any?> = mapOf(
        "entryId" to id,
        "timestamp" to LocalDateTime.parse(time).atZone(zone).toInstant().toEpochMilli(),
        "record" to testSnapshot(title = title, packageName = pkg).toMap(),
    )

    @Suppress("UNCHECKED_CAST")
    private fun rows(result: Map<String, Any?>): List<Map<String, Any?>> =
        result["rows"] as List<Map<String, Any?>>

    private fun actions(result: Map<String, Any?>, side: String): List<String> =
        rows(result).map { (it[side] as Map<*, *>)["action"] as String }

    @Test
    fun `回放使用每条历史时间 跨夜按开始日匹配且保留原顺序`() {
        val candidate = RuleSet(rules = listOf(testRule(
            id = "friday-night", keywords = listOf("促销"),
            quietHours = QuietHours(22 * 60, 8 * 60, setOf(5)),
        )))
        val result = comparison.compare(
            RuleSet.EMPTY.toMap(), candidate.toMap(), listOf(
                sample("a", "2026-11-06T21:59:00"),
                sample("b", "2026-11-06T22:00:00"),
                sample("c", "2026-11-07T07:59:00"),
                sample("d", "2026-11-07T08:00:00"),
                sample("e", "2026-11-07T23:00:00"),
            ), zone, evaluatedAt = 1234L,
        )
        assertEquals(listOf("a", "b", "c", "d", "e"), rows(result).map { it["entryId"] })
        assertEquals(List(5) { "allow" }, actions(result, "before"))
        assertEquals(listOf("allow", "intercept", "intercept", "allow", "allow"), actions(result, "after"))
        assertEquals("Asia/Shanghai", result["zoneId"])
        assertEquals(1234L, result["evaluatedAt"])
    }

    @Test
    fun `应用范围与词条件是AND 且保留优先 两侧规则独立求值`() {
        val base = RuleSet(defaultAction = RuleAction.LOG_ONLY)
        val candidate = RuleSet(rules = listOf(
            testRule("keep", action = RuleAction.ALLOW,
                packages = listOf("com.demo.shop"), keywords = listOf("验证码")),
            testRule("drop", packages = listOf("com.demo.shop"), keywords = listOf("优惠")),
        ))
        val result = comparison.compare(base.toMap(), candidate.toMap(), listOf(
            sample("drop", title = "今日优惠"),
            sample("other-app", title = "今日优惠", pkg = "com.other.app"),
            sample("keep", title = "优惠验证码"),
            sample("unmatched", title = "普通消息"),
        ), zone)
        assertEquals(List(4) { "log_only" }, actions(result, "before"))
        assertEquals(listOf("intercept", "allow", "allow", "allow"), actions(result, "after"))
        assertEquals("keep", (rows(result)[2]["after"] as Map<*, *>)["ruleId"])
    }

    @Test
    fun `全局关闭与自身通知遵守真实引擎规则`() {
        val on = RuleSet(rules = listOf(testRule("all", keywords = listOf("促销"))))
        val off = on.copy(globalEnabled = false)
        val result = comparison.compare(off.toMap(), on.toMap(), listOf(
            sample("normal"), sample("self", pkg = "dev.poc.notifinterceptor"),
        ), zone)
        assertEquals(listOf("allow", "allow"), actions(result, "before"))
        assertEquals(listOf("intercept", "allow"), actions(result, "after"))
        assertEquals("disabled", (rows(result)[0]["before"] as Map<*, *>)["reason"])
        assertEquals("self", (rows(result)[1]["after"] as Map<*, *>)["reason"])
    }

    @Test
    fun `动作不变但命中规则改变也保留完整结果`() {
        val base = RuleSet(rules = listOf(testRule("old", keywords = listOf("促销"))))
        val candidate = RuleSet(rules = listOf(testRule("new", keywords = listOf("促销"))))
        val result = comparison.compare(base.toMap(), candidate.toMap(), listOf(sample("same-action")), zone)
        val row = rows(result).single()
        assertEquals("intercept", (row["before"] as Map<*, *>)["action"])
        assertEquals("intercept", (row["after"] as Map<*, *>)["action"])
        assertEquals("old", (row["before"] as Map<*, *>)["ruleId"])
        assertEquals("new", (row["after"] as Map<*, *>)["ruleId"])
    }

    @Test
    fun `无效正则按实际引擎跳过 并返回两侧告警`() {
        val base = RuleSet(rules = listOf(testRule("bad-old", titleRegex = "[")))
        val candidate = RuleSet(rules = listOf(
            testRule("bad-new", textRegex = "["),
            testRule("drop", keywords = listOf("促销")),
        ))
        val result = comparison.compare(base.toMap(), candidate.toMap(), listOf(sample("valid")), zone)
        assertEquals(listOf("allow"), actions(result, "before"))
        assertEquals(listOf("intercept"), actions(result, "after"))
        assertEquals("bad-old", ((result["baseIssues"] as List<*>).single() as Map<*, *>)["ruleId"])
        assertEquals("bad-new", ((result["candidateIssues"] as List<*>).single() as Map<*, *>)["ruleId"])
    }

    @Test
    fun `空样本可以比较 上限1000且通知更新可重复key`() {
        val empty = comparison.compare(RuleSet.EMPTY.toMap(), RuleSet.EMPTY.toMap(), emptyList<Any>(), zone)
        assertTrue(rows(empty).isEmpty())
        val samples = (1..1000).map { sample("record_$it") }
        val result = comparison.compare(RuleSet.EMPTY.toMap(), RuleSet.EMPTY.toMap(), samples, zone)
        assertEquals(1000, rows(result).size)
        assertThrows(IllegalArgumentException::class.java) {
            comparison.compare(RuleSet.EMPTY.toMap(), RuleSet.EMPTY.toMap(), samples + sample("over"), zone)
        }
    }

    @Test
    fun `重复样本标识 非法时间 空通知身份和系统汇总整体拒绝`() {
        val normal = sample("x")
        val summary = normal + ("record" to (testSnapshot().toMap() + ("isGroupSummary" to true)))
        val invalid = listOf(
            listOf(normal, normal),
            listOf(normal + ("timestamp" to 0L)),
            listOf(normal + ("timestamp" to 1.5)),
            listOf(normal + ("timestamp" to "not-time")),
            listOf(normal + ("entryId" to " ")),
            listOf(normal + ("record" to (testSnapshot().toMap() + ("key" to "")))),
            listOf(normal + ("record" to (testSnapshot().toMap() + ("packageName" to "")))),
            listOf(summary),
            listOf("not-an-object"),
        )
        for (samples in invalid) {
            assertThrows(IllegalArgumentException::class.java) {
                comparison.compare(RuleSet.EMPTY.toMap(), RuleSet.EMPTY.toMap(), samples, zone)
            }
        }
    }

    @Test
    fun `无效规则结构与未来版本拒绝而不是静默替换成默认动作`() {
        val base = RuleSet.EMPTY.toMap()
        for (invalid in listOf(
            base + ("schemaVersion" to 2),
            base + ("globalEnabled" to "true"),
            base + ("defaultAction" to "unknown"),
            base + ("rules" to listOf("bad")),
            base + ("rules" to listOf(testRule("x").toMap() + ("action" to "unknown"))),
        )) {
            assertThrows(IllegalArgumentException::class.java) {
                comparison.compare(base, invalid, listOf(sample("x")), zone)
            }
        }
    }
}
