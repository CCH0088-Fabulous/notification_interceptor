package dev.poc.notifinterceptor.domain

/** 单条过滤规则。正则以字符串保存，编译由 [RuleEngine] 负责并缓存。 */
data class RuleSpec(
    val id: String,
    val name: String,
    val enabled: Boolean = true,
    val action: RuleAction = RuleAction.INTERCEPT,
    val mode: MatchMode = MatchMode.ALL,
    val packages: List<String> = emptyList(),
    val keywordsAny: List<String> = emptyList(),
    val titleRegex: String? = null,
    val textRegex: String? = null,
    val channelIds: List<String> = emptyList(),
    val isOngoing: Boolean? = null,
    val isClearable: Boolean? = null,
    val quietHours: QuietHours? = null,
) {
    /** 是否存在至少一个参与匹配的条件组。 */
    fun hasAnyCondition(): Boolean =
        packages.any { it.isNotBlank() } ||
            keywordsAny.any { it.isNotBlank() } ||
            !titleRegex.isNullOrBlank() ||
            !textRegex.isNullOrBlank() ||
            channelIds.any { it.isNotBlank() } ||
            isOngoing != null ||
            isClearable != null ||
            quietHours != null

    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "name" to name,
        "enabled" to enabled,
        "action" to action.wire,
        "match" to buildMap<String, Any?> {
            put("mode", mode.wire)
            put("packages", packages)
            put("keywordsAny", keywordsAny)
            put("titleRegex", titleRegex)
            put("textRegex", textRegex)
            put("channelIds", channelIds)
            put("isOngoing", isOngoing)
            put("isClearable", isClearable)
            put("quietHours", quietHours?.toMap())
        },
    )

    companion object {
        fun fromMap(map: Map<*, *>): RuleSpec {
            val match = (map["match"] as? Map<*, *>) ?: emptyMap<String, Any?>()
            return RuleSpec(
                id = map.str("id").orEmpty(),
                name = map.str("name").orEmpty(),
                enabled = map.bool("enabled") ?: true,
                action = RuleAction.fromWire(map.str("action")),
                mode = MatchMode.fromWire(match.str("mode")),
                packages = match.stringList("packages"),
                keywordsAny = match.stringList("keywordsAny"),
                titleRegex = match.str("titleRegex")?.takeIf { it.isNotBlank() },
                textRegex = match.str("textRegex")?.takeIf { it.isNotBlank() },
                channelIds = match.stringList("channelIds"),
                isOngoing = match.bool("isOngoing"),
                isClearable = match.bool("isClearable"),
                quietHours = QuietHours.fromMap(match["quietHours"] as? Map<*, *>),
            )
        }
    }
}

/** 规则集合，是规则持久化与通道传输的最小单位。 */
data class RuleSet(
    val schemaVersion: Int = CURRENT_SCHEMA_VERSION,
    val globalEnabled: Boolean = true,
    val defaultAction: RuleAction = RuleAction.ALLOW,
    val rules: List<RuleSpec> = emptyList(),
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "schemaVersion" to schemaVersion,
        "globalEnabled" to globalEnabled,
        "defaultAction" to defaultAction.wire,
        "rules" to rules.map { it.toMap() },
    )

    companion object {
        const val CURRENT_SCHEMA_VERSION = 1

        val EMPTY = RuleSet()

        fun fromMap(map: Map<*, *>): RuleSet = RuleSet(
            schemaVersion = map.int("schemaVersion", CURRENT_SCHEMA_VERSION),
            globalEnabled = map.bool("globalEnabled") ?: true,
            defaultAction = RuleAction.fromWire(map.str("defaultAction")),
            rules = (map["rules"] as? List<*>)
                ?.filterIsInstance<Map<*, *>>()
                ?.map { RuleSpec.fromMap(it) }
                ?: emptyList(),
        )
    }
}

internal fun Map<*, *>.stringList(key: String): List<String> =
    (this[key] as? List<*>)?.mapNotNull { (it as? String)?.trim() }?.filter { it.isNotEmpty() }
        ?: emptyList()
