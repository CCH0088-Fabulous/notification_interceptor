package dev.poc.notifinterceptor.domain

/**
 * 通知的不可变快照。只保留规则引擎与 UI 需要的字段，extras 仅用于调试展示。
 */
data class NotificationSnapshot(
    val key: String,
    val id: Int,
    val packageName: String,
    val appLabel: String?,
    val postTime: Long,
    val title: String?,
    val text: String?,
    val bigText: String?,
    val textLines: List<String>,
    val subText: String?,
    val tickerText: String?,
    val category: String?,
    val channelId: String?,
    val channelName: String?,
    val groupKey: String?,
    val isGroupSummary: Boolean,
    val isOngoing: Boolean,
    val isClearable: Boolean,
    val priority: Int,
    val progress: Int,
    val extras: Map<String, String>,
) {
    /** 关键词与正则匹配的搜索文本，顺序固定以便测试。 */
    fun searchableText(): String = buildString {
        append(title.orEmpty())
        append('\n')
        append(text.orEmpty())
        append('\n')
        append(bigText.orEmpty())
        append('\n')
        append(subText.orEmpty())
        append('\n')
        append(textLines.joinToString("\n"))
    }

    fun toMap(): Map<String, Any?> = mapOf(
        "key" to key,
        "id" to id,
        "packageName" to packageName,
        "appLabel" to appLabel,
        "postTime" to postTime,
        "title" to title,
        "text" to text,
        "bigText" to bigText,
        "textLines" to textLines,
        "subText" to subText,
        "tickerText" to tickerText,
        "category" to category,
        "channelId" to channelId,
        "channelName" to channelName,
        "groupKey" to groupKey,
        "isGroupSummary" to isGroupSummary,
        "isOngoing" to isOngoing,
        "isClearable" to isClearable,
        "priority" to priority,
        "progress" to progress,
        "extras" to extras,
    )

    companion object {
        fun fromMap(map: Map<*, *>): NotificationSnapshot = NotificationSnapshot(
            key = map.str("key").orEmpty(),
            id = map.int("id"),
            packageName = map.str("packageName").orEmpty(),
            appLabel = map.str("appLabel"),
            postTime = map.long("postTime"),
            title = map.str("title"),
            text = map.str("text"),
            bigText = map.str("bigText"),
            textLines = (map["textLines"] as? List<*>)?.mapNotNull { it as? String } ?: emptyList(),
            subText = map.str("subText"),
            tickerText = map.str("tickerText"),
            category = map.str("category"),
            channelId = map.str("channelId"),
            channelName = map.str("channelName"),
            groupKey = map.str("groupKey"),
            isGroupSummary = map["isGroupSummary"] as? Boolean ?: false,
            isOngoing = map["isOngoing"] as? Boolean ?: false,
            isClearable = map["isClearable"] as? Boolean ?: true,
            priority = map.int("priority"),
            progress = map.int("progress", -1),
            extras = (map["extras"] as? Map<*, *>)?.entries
                ?.mapNotNull { entry -> (entry.key as? String)?.let { it to entry.value.toString() } }
                ?.toMap() ?: emptyMap(),
        )
    }
}

internal fun Map<*, *>.str(key: String): String? = this[key] as? String

internal fun Map<*, *>.int(key: String, fallback: Int = 0): Int =
    (this[key] as? Number)?.toInt() ?: fallback

internal fun Map<*, *>.long(key: String, fallback: Long = 0L): Long =
    (this[key] as? Number)?.toLong() ?: fallback

internal fun Map<*, *>.bool(key: String): Boolean? = this[key] as? Boolean
