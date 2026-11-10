package dev.poc.notifinterceptor.domain

import java.net.URI
import java.time.Instant
import java.time.ZoneId

/** The only event/metric vocabulary accepted by the research sender. No free text. */
object ResearchPolicy {
    const val DISCLOSURE_VERSION = 2
    const val EVENT_RETENTION_DAYS = 14
    const val HOUR_RETENTION_DAYS = 30
    const val EVENT_LIMIT = 50_000
    const val HOUR_LIMIT = 4096
    const val DATABASE_MAX_BYTES = 64L * 1024 * 1024
    const val HOUR_MS = 3_600_000L
    const val DAY_MS = 24 * HOUR_MS
    const val MAX_CONFIRMED_INTERVAL_MS = 90_000L
    val actions = setOf(
        "page_feed", "page_rules", "page_history", "page_settings", "open_presets",
        "open_comparison", "comparison_completed", "scene_switch", "scene_end",
        "preset_apply", "preset_restore", "preset_import", "preset_export",
    )
    val metrics = setOf(
        "foreground_sessions", "foreground_ms", "engine_enabled_observed_ms",
        "listener_connected_observed_ms", "observation_gap_ms", "listener_connections",
        "listener_disconnects", "processed", "allow", "log_only", "intercept_matched",
        "cancel_success", "cancel_failed", "cancel_rejected", "cancel_unconfirmed",
        "existing_processed", "existing_allow", "existing_log_only", "existing_intercept_matched",
        "existing_cancel_success", "existing_cancel_failed", "existing_cancel_rejected",
        "existing_cancel_unconfirmed", "summaries_excluded", "ongoing_excluded", "rules_saved", "rules_added",
        "rules_removed", "rules_modified", "rules_toggled", "global_toggled", "presets_saved",
        "preset_version_saved", "history_cleared", "history_exported", "manual_cancel_requested",
        "retention_dropped_events", "retention_dropped_hours", "retention_dropped_batches",
    ) + actions.map { "action_$it" }

    fun validateMetrics(values: Map<String, Long>): Map<String, Long> {
        require(values.isNotEmpty() && values.keys.all { it in metrics }) { "研究事件不在白名单中" }
        require(values.values.all { it in 0..(7 * DAY_MS) }) { "研究计数超出范围" }
        return values.filterValues { it > 0 }
    }

    fun endpoint(value: String, debug: Boolean): String {
        val text = value.trim()
        if (text.isEmpty()) return ""
        require(text.length <= 2048) { "接收地址过长" }
        val uri = runCatching { URI(text) }.getOrElse { throw IllegalArgumentException("接收地址格式无效") }
        val loopback = debug && uri.scheme == "http" &&
            uri.host in setOf("127.0.0.1", "localhost", "10.0.2.2")
        require((uri.scheme == "https" || loopback) && !uri.host.isNullOrBlank() &&
            uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null &&
            uri.port in -1..65535 && uri.port != 0) {
            "使用完整 HTTPS 接收地址，不含账号、查询参数或片段；调试版仅额外支持本机测试地址"
        }
        return uri.toASCIIString()
    }

    fun cohort(selected: String, packageName: String? = null): String {
        require(selected in setOf("pilot", "demo")) { "研究分组无效" }
        return if (packageName in setOf("dev.poc.notifgen", "dev.poc.probe", "com.android.shell")) "demo" else selected
    }

    fun observed(entry: HistoryEntry, existing: Boolean): Map<String, Long> {
        if (entry.snapshot.isGroupSummary) return mapOf("summaries_excluded" to 1L)
        if (entry.snapshot.isOngoing) return mapOf("ongoing_excluded" to 1L)
        val prefix = if (existing) "existing_" else ""
        val values = mutableMapOf("${prefix}processed" to 1L)
        values[prefix + when (entry.action) {
            RuleAction.ALLOW -> "allow"
            RuleAction.LOG_ONLY -> "log_only"
            RuleAction.INTERCEPT -> "intercept_matched"
        }] = 1
        if (entry.action == RuleAction.INTERCEPT && entry.cancelStatus != CancelStatus.PENDING) {
            values[prefix + outcome(entry.cancelStatus)] = 1
        }
        return validateMetrics(values)
    }

    fun outcome(status: CancelStatus): String = when (status) {
        CancelStatus.SUCCESS -> "cancel_success"
        CancelStatus.REJECTED -> "cancel_rejected"
        CancelStatus.FAILED -> "cancel_failed"
        else -> "cancel_unconfirmed"
    }

    /** Only coarse counts/booleans/enums; never ids, names, terms, regexes or packages. */
    fun ruleStructures(rules: RuleSet): List<Map<String, Any>> = rules.rules.map { rule ->
        mapOf(
            "kind" to when {
                rule.id.startsWith("preset:scene:") -> "scene"
                rule.id.startsWith("preset:keywords:") -> "keywords"
                else -> "manual_or_legacy"
            },
            "action" to rule.action.wire,
            "enabled" to rule.enabled,
            "mode" to rule.mode.wire,
            "keywordCountBand" to countBand(rule.keywordsAny.size),
            "applicationCountBand" to countBand(rule.packages.size),
            "hasRegex" to (!rule.titleRegex.isNullOrBlank() || !rule.textRegex.isNullOrBlank()),
            "hasChannelCondition" to rule.channelIds.isNotEmpty(),
            "hasSchedule" to (rule.quietHours != null),
        )
    }.groupingBy { it }.eachCount().map { (structure, count) -> structure + ("count" to count) }

    private fun countBand(count: Int): String = when (count) {
        0 -> "0"
        1 -> "1"
        in 2..5 -> "2-5"
        in 6..20 -> "6-20"
        else -> "21+"
    }

    fun rulesChanged(before: RuleSet, after: RuleSet): Map<String, Long> {
        val old = before.rules.associateBy { it.id }
        val next = after.rules.associateBy { it.id }
        return validateMetrics(mapOf(
            "rules_saved" to 1L,
            "rules_added" to next.keys.count { it !in old }.toLong(),
            "rules_removed" to old.keys.count { it !in next }.toLong(),
            "rules_toggled" to next.values.count { old[it.id]?.let { previous -> previous.enabled != it.enabled } == true }.toLong(),
            "rules_modified" to next.values.count { old[it.id]?.let { previous -> previous.copy(enabled = it.enabled) != it } == true }.toLong(),
            "global_toggled" to if (before.globalEnabled != after.globalEnabled) 1L else 0L,
        ))
    }

    fun durationSlices(endWall: Long, elapsedMs: Long, zone: ZoneId): List<Pair<Long, Pair<Int, Long>>> {
        require(elapsedMs in 0..MAX_CONFIRMED_INTERVAL_MS)
        var cursor = endWall - elapsedMs
        val slices = mutableListOf<Pair<Long, Pair<Int, Long>>>()
        while (cursor < endWall) {
            val bucket = Math.floorDiv(cursor, HOUR_MS) * HOUR_MS
            val end = minOf(endWall, bucket + HOUR_MS)
            val offset = zone.rules.getOffset(Instant.ofEpochMilli(cursor)).totalSeconds / 60
            slices.add(bucket to (offset to (end - cursor)))
            cursor = end
        }
        return slices
    }
}
