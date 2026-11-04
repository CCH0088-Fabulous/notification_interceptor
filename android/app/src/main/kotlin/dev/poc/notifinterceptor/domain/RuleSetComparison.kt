package dev.poc.notifinterceptor.domain

import java.time.ZoneId

/** Pure read-only replay. This class has no repository or notification service. */
class RuleSetComparison(private val engine: RuleEngine) {

    fun compare(
        baseRuleSet: Map<*, *>,
        candidateRuleSet: Map<*, *>,
        samples: List<*>,
        zone: ZoneId = ZoneId.systemDefault(),
        evaluatedAt: Long = System.currentTimeMillis(),
    ): Map<String, Any?> {
        require(samples.size <= MAX_SAMPLES) { "批量对比最多支持 $MAX_SAMPLES 条记录" }
        val base = parseRuleSet(baseRuleSet, "当前规则")
        val candidate = parseRuleSet(candidateRuleSet, "候选规则")
        val ids = mutableSetOf<String>()
        // Validate every sample before evaluating any, avoiding partial reports.
        val parsed = samples.mapIndexed { index, raw ->
            val sample = raw as? Map<*, *>
                ?: throw IllegalArgumentException("第 ${index + 1} 条样本格式无效")
            val id = requiredText(sample["entryId"], "样本标识", 200)
            require(ids.add(id)) { "样本标识重复：$id" }
            val timestamp = sample["timestamp"]
            require(timestamp is Number && timestamp.toLong() in 1L..MAX_TIMESTAMP &&
                timestamp.toDouble() == timestamp.toLong().toDouble()) { "样本时间无效" }
            val record = sample["record"] as? Map<*, *>
                ?: throw IllegalArgumentException("样本缺少通知记录")
            requiredText(record["key"], "通知标识", 4096)
            requiredText(record["packageName"], "应用包名", 255)
            require(record["isGroupSummary"] == null || record["isGroupSummary"] is Boolean) {
                "通知汇总标记无效"
            }
            val snapshot = NotificationSnapshot.fromMap(record)
            require(!snapshot.isGroupSummary) { "请排除系统分组汇总后再对比" }
            Sample(id, timestamp.toLong(), snapshot)
        }
        val rows = parsed.map { sample ->
            check(!Thread.currentThread().isInterrupted) { "批量对比已取消，请重试" }
            mapOf(
                "entryId" to sample.id,
                "before" to engine.evaluate(base, sample.record, sample.timestamp, zone).toMap(),
                "after" to engine.evaluate(candidate, sample.record, sample.timestamp, zone).toMap(),
            )
        }
        return mapOf(
            "rows" to rows,
            "evaluatedAt" to evaluatedAt,
            "zoneId" to zone.id,
            // Invalid regex and empty conditions are skipped by the same engine
            // as live handling; keep its warnings visible instead of inventing
            // a different evaluation policy for comparisons.
            "baseIssues" to engine.validate(base).map { it.toMap() },
            "candidateIssues" to engine.validate(candidate).map { it.toMap() },
        )
    }

    private fun parseRuleSet(raw: Map<*, *>, label: String): RuleSet {
        val version = raw["schemaVersion"]
        require(version is Number && version.toDouble() == RuleSet.CURRENT_SCHEMA_VERSION.toDouble()) {
            "$label 的版本无效"
        }
        require(raw["globalEnabled"] is Boolean) { "$label 的全局开关无效" }
        require(RuleAction.entries.any { it.wire == raw["defaultAction"] }) { "$label 的默认动作无效" }
        val rules = raw["rules"] as? List<*>
            ?: throw IllegalArgumentException("$label 缺少规则列表")
        rules.forEach { item ->
            val rule = item as? Map<*, *>
                ?: throw IllegalArgumentException("$label 含无效规则")
            require(rule["id"] is String && rule["name"] is String && rule["enabled"] is Boolean) {
                "$label 的规则字段无效"
            }
            require(RuleAction.entries.any { it.wire == rule["action"] }) { "$label 的规则动作无效" }
            val match = rule["match"] as? Map<*, *>
                ?: throw IllegalArgumentException("$label 的匹配条件无效")
            require(MatchMode.entries.any { it.wire == match["mode"] }) { "$label 的组合方式无效" }
            for (key in listOf("packages", "keywordsAny", "channelIds")) {
                val values = match[key]
                require(values is List<*> && values.all { it is String }) { "$label 的 $key 无效" }
            }
            for (key in listOf("titleRegex", "textRegex")) {
                require(match[key] == null || match[key] is String) { "$label 的 $key 无效" }
            }
            for (key in listOf("isOngoing", "isClearable")) {
                require(match[key] == null || match[key] is Boolean) { "$label 的 $key 无效" }
            }
            val quiet = match["quietHours"]
            if (quiet != null) {
                require(quiet is Map<*, *> && QuietHours.parse(quiet["from"] as? String) != null &&
                    QuietHours.parse(quiet["to"] as? String) != null) { "$label 的时段无效" }
                val days = quiet["days"]
                require(days is List<*> && days.isNotEmpty() && days.all { day ->
                    day is Number && day.toDouble() == day.toInt().toDouble() && day.toInt() in 1..7
                }) { "$label 的生效日期无效" }
            }
        }
        return RuleSet.fromMap(raw)
    }

    private fun requiredText(raw: Any?, label: String, maximum: Int): String {
        val text = raw as? String ?: throw IllegalArgumentException("$label 无效")
        require(text.isNotBlank() && text.length <= maximum) { "$label 无效" }
        return text
    }

    private data class Sample(val id: String, val timestamp: Long, val record: NotificationSnapshot)

    companion object {
        const val MAX_SAMPLES = 1000
        private const val MAX_TIMESTAMP = 8_640_000_000_000_000L
    }
}
