package dev.poc.notifinterceptor.domain

import java.time.ZoneId
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/**
 * 规则引擎：按数组顺序求值，**首个命中即返回**。
 *
 * 语义约定（对应 PLAN.md §3.4，由 RuleEngineTest 固化）：
 * 1. 条件组之间：mode=ALL 时为 AND，mode=ANY 时为 OR。
 * 2. 空条件组不参与匹配；完全没有条件的规则永不命中。
 * 3. 正则非法 → 该规则跳过，不阻断后续规则。
 * 4. globalEnabled=false 或自身包名 → 一律放行。
 */
class RuleEngine(private val ownPackage: String) {

    private val regexCache = ConcurrentHashMap<String, CompiledRegex>()

    fun evaluate(
        ruleSet: RuleSet,
        snapshot: NotificationSnapshot,
        nowMillis: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): Decision {
        if (!ruleSet.globalEnabled) {
            return Decision(null, null, RuleAction.ALLOW, REASON_DISABLED)
        }
        if (snapshot.packageName == ownPackage) {
            return Decision(null, null, RuleAction.ALLOW, REASON_SELF)
        }
        for (rule in ruleSet.rules) {
            if (!rule.enabled) continue
            if (!rule.hasAnyCondition()) continue
            val compiled = compile(rule) ?: continue
            if (compiled.matches(snapshot, nowMillis, zone)) {
                return Decision(rule.id, rule.name, rule.action, REASON_RULE)
            }
        }
        return Decision(null, null, ruleSet.defaultAction, REASON_DEFAULT)
    }

    /** 静态校验，供 UI 在保存前提示。 */
    fun validate(ruleSet: RuleSet): List<RuleIssue> {
        val issues = mutableListOf<RuleIssue>()
        val seen = HashSet<String>()
        for (rule in ruleSet.rules) {
            if (rule.id.isBlank()) {
                issues += RuleIssue(rule.id, "id", "规则 id 不能为空")
            } else if (!seen.add(rule.id)) {
                issues += RuleIssue(rule.id, "id", "规则 id 重复")
            }
            if (!rule.hasAnyCondition()) {
                issues += RuleIssue(rule.id, "match", "规则没有任何匹配条件，永远不会命中")
            }
            if (!rule.titleRegex.isNullOrBlank() && compileRegex(rule.titleRegex) == null) {
                issues += RuleIssue(rule.id, "titleRegex", "标题正则无效")
            }
            if (!rule.textRegex.isNullOrBlank() && compileRegex(rule.textRegex) == null) {
                issues += RuleIssue(rule.id, "textRegex", "正文正则无效")
            }
            val quiet = rule.quietHours
            if (quiet != null && quiet.fromMinutes == quiet.toMinutes) {
                issues += RuleIssue(rule.id, "quietHours", "静默时段的起止时间相同，窗口为空")
            }
        }
        return issues
    }

    private fun compile(rule: RuleSpec): CompiledRule? {
        val title = rule.titleRegex?.takeIf { it.isNotBlank() }?.let {
            compileRegex(it) ?: return null
        }
        val text = rule.textRegex?.takeIf { it.isNotBlank() }?.let {
            compileRegex(it) ?: return null
        }
        return CompiledRule(
            spec = rule,
            titleRegex = title,
            textRegex = text,
        )
    }

    private fun compileRegex(pattern: String): Regex? {
        regexCache[pattern]?.let { return it.regex }
        if (pattern.length > MAX_PATTERN_LENGTH) return null
        val compiled = try {
            Regex(pattern)
        } catch (_: Exception) {
            null
        }
        regexCache[pattern] = CompiledRegex(compiled)
        if (regexCache.size > MAX_CACHE_ENTRIES) regexCache.clear()
        return compiled
    }

    private class CompiledRegex(val regex: Regex?)

    private class CompiledRule(
        val spec: RuleSpec,
        val titleRegex: Regex?,
        val textRegex: Regex?,
    ) {
        fun matches(snapshot: NotificationSnapshot, nowMillis: Long, zone: ZoneId): Boolean {
            val groups = ArrayList<Boolean>(7)

            if (spec.packages.any { it.isNotBlank() }) {
                groups += spec.packages.any { it == snapshot.packageName }
            }
            if (spec.keywordsAny.any { it.isNotBlank() }) {
                val haystack = snapshot.searchableText().lowercase(Locale.ROOT)
                groups += spec.keywordsAny
                    .filter { it.isNotBlank() }
                    .any { haystack.contains(it.trim().lowercase(Locale.ROOT)) }
            }
            titleRegex?.let { groups += it.containsMatchIn(snapshot.title.orEmpty()) }
            textRegex?.let {
                val haystack = buildString {
                    append(snapshot.text.orEmpty())
                    append('\n')
                    append(snapshot.bigText.orEmpty())
                }
                groups += it.containsMatchIn(haystack)
            }
            if (spec.channelIds.any { it.isNotBlank() }) {
                groups += snapshot.channelId != null && snapshot.channelId in spec.channelIds
            }
            spec.isOngoing?.let { groups += it == snapshot.isOngoing }
            spec.isClearable?.let { groups += it == snapshot.isClearable }
            spec.quietHours?.let { groups += it.matches(nowMillis, zone) }

            if (groups.isEmpty()) return false
            return if (spec.mode == MatchMode.ALL) groups.all { it } else groups.any { it }
        }
    }

    companion object {
        const val REASON_DISABLED = "disabled"
        const val REASON_SELF = "self"
        const val REASON_RULE = "rule"
        const val REASON_DEFAULT = "default"

        private const val MAX_PATTERN_LENGTH = 200
        private const val MAX_CACHE_ENTRIES = 128
    }
}
