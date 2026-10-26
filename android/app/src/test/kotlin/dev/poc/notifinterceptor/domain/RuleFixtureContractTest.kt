package dev.poc.notifinterceptor.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * 契约测试：Kotlin 必须能读懂 Dart 测试所用的同一份 JSON 固件。
 * 任一端改了字段名而另一端没跟上，这里会先失败。
 */
class RuleFixtureContractTest {

    private val fixtures: File by lazy { requireNotNull(locateFixtures()) { "找不到 test/fixtures" } }

    @Test
    fun `Dart 侧规则固件可被 Kotlin 解析且语义一致`() {
        val text = File(fixtures, "rule_set_v1.json").readText()
        val map = Json.parseObject(text)
        assertNotNull("固件不是合法 JSON", map)

        val ruleSet = RuleSet.fromMap(map!!)

        assertEquals(RuleSet.CURRENT_SCHEMA_VERSION, ruleSet.schemaVersion)
        assertTrue(ruleSet.globalEnabled)
        assertEquals(RuleAction.ALLOW, ruleSet.defaultAction)
        assertEquals(1, ruleSet.rules.size)

        val rule = ruleSet.rules[0]
        assertEquals("r1", rule.id)
        assertEquals(RuleAction.INTERCEPT, rule.action)
        assertEquals(MatchMode.ALL, rule.mode)
        assertEquals(listOf("com.example.shop"), rule.packages)
        assertEquals(listOf("秒杀", "红包"), rule.keywordsAny)
        assertEquals("优惠|限时", rule.titleRegex)
        assertEquals(listOf("marketing"), rule.channelIds)
        assertEquals(false, rule.isOngoing)
        assertEquals(true, rule.isClearable)
        assertEquals(22 * 60, rule.quietHours?.fromMinutes)
        assertEquals(8 * 60, rule.quietHours?.toMinutes)
        assertEquals((1..7).toSet(), rule.quietHours?.days)
    }

    @Test
    fun `固件解析后再次序列化结果稳定`() {
        val ruleSet = RuleSet.fromMap(
            Json.parseObject(File(fixtures, "rule_set_v1.json").readText())!!,
        )

        val once = Json.stringify(ruleSet.toMap())
        val twice = Json.stringify(RuleSet.fromMap(Json.parseObject(once)!!).toMap())

        assertEquals(once, twice)
    }

    @Test
    fun `历史固件可被 Kotlin 解析`() {
        val entry = HistoryEntry.fromMap(
            Json.parseObject(File(fixtures, "history_entry_v1.json").readText())!!,
        )

        assertNotNull("历史固件解析失败", entry)
        assertEquals(RuleAction.INTERCEPT, entry!!.action)
        assertEquals(CancelStatus.SUCCESS, entry.cancelStatus)
        assertEquals("com.example.shop", entry.snapshot.packageName)
        assertEquals("屏蔽电商营销", entry.matchedRuleName)
    }

    private fun locateFixtures(): File? {
        var current: File? = File(System.getProperty("user.dir")).absoluteFile
        repeat(6) {
            val candidate = current?.resolve("test/fixtures")
            if (candidate?.isDirectory == true) return candidate
            current = current?.parentFile
        }
        return null
    }

    private object Json {
        fun parseObject(text: String): Map<String, Any?>? =
            dev.poc.notifinterceptor.data.Json.parseObject(text)

        fun stringify(value: Any?): String = dev.poc.notifinterceptor.data.Json.stringify(value)
    }
}
