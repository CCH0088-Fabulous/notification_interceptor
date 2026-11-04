package dev.poc.notifinterceptor.domain

import dev.poc.notifinterceptor.data.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.LocalDateTime
import java.time.ZoneId

/** Runs the exact rules produced by Dart against the real background engine. */
class PresetRuleContractTest {
    private val zone = ZoneId.of("Asia/Shanghai")
    private val engine = RuleEngine("dev.poc.notifinterceptor")
    private val rules by lazy {
        var current: File? = File(System.getProperty("user.dir")).absoluteFile
        var fixture: File? = null
        repeat(6) {
            val candidate = current?.resolve("test/fixtures/preset_rules_v1.json")
            if (candidate?.isFile == true) fixture = candidate
            current = current?.parentFile
        }
        RuleSet.fromMap(Json.parseObject(requireNotNull(fixture).readText())!!)
    }

    private fun evaluate(time: String, text: String, pkg: String = "com.demo.shop"): Decision =
        engine.evaluate(
            rules,
            testSnapshot(packageName = pkg, title = text, text = "正文"),
            LocalDateTime.parse(time).atZone(zone).toInstant().toEpochMilli(),
            zone,
        )

    @Test
    fun `Friday night scene remains active Saturday morning and stops at exclusive boundary`() {
        assertTrue(engine.validate(rules).isEmpty())
        assertEquals(RuleAction.ALLOW, evaluate("2026-11-06T21:59:00", "促销").action)
        assertEquals(RuleAction.INTERCEPT, evaluate("2026-11-06T22:00:00", "促销").action)
        assertEquals(RuleAction.INTERCEPT, evaluate("2026-11-07T07:59:00", "直播").action)
        assertEquals(RuleAction.ALLOW, evaluate("2026-11-07T08:00:00", "直播").action)
        assertEquals(RuleAction.ALLOW, evaluate("2026-11-07T23:00:00", "促销").action)
    }

    @Test
    fun `scope is AND and urgent exception wins even when a block word also occurs`() {
        assertEquals(RuleAction.ALLOW, evaluate("2026-11-06T23:00:00", "普通消息").action)
        assertEquals(RuleAction.ALLOW, evaluate("2026-11-06T23:00:00", "促销", "com.other.app").action)
        val urgent = evaluate("2026-11-06T23:00:00", "紧急促销")
        assertEquals(RuleAction.ALLOW, urgent.action)
        assertEquals("preset:scene:fixture_sleep:allow", urgent.ruleId)
        assertEquals("preset:scene:fixture_sleep:intercept", evaluate("2026-11-06T23:00:00", "促销").ruleId)
    }
}
