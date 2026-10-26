package dev.poc.notifinterceptor.domain

/** 一条命中记录，写入历史。schemaVersion 固定随 RuleSet 一起演进。 */
data class HistoryEntry(
    val id: String,
    val timestamp: Long,
    val snapshot: NotificationSnapshot,
    val action: RuleAction,
    val matchedRuleId: String?,
    val matchedRuleName: String?,
    val cancelStatus: CancelStatus,
    val note: String? = null,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "timestamp" to timestamp,
        "snapshot" to snapshot.toMap(),
        "action" to action.wire,
        "matchedRuleId" to matchedRuleId,
        "matchedRuleName" to matchedRuleName,
        "cancelStatus" to cancelStatus.wire,
        "note" to note,
    )

    companion object {
        fun fromMap(map: Map<*, *>): HistoryEntry? {
            val snapshotMap = map["snapshot"] as? Map<*, *> ?: return null
            val snapshot = NotificationSnapshot.fromMap(snapshotMap)
            if (snapshot.key.isBlank() && snapshot.packageName.isBlank()) return null
            return HistoryEntry(
                id = map.str("id").orEmpty(),
                timestamp = map.long("timestamp"),
                snapshot = snapshot,
                action = RuleAction.fromWire(map.str("action")),
                matchedRuleId = map.str("matchedRuleId"),
                matchedRuleName = map.str("matchedRuleName"),
                cancelStatus = CancelStatus.fromWire(map.str("cancelStatus")),
                note = map.str("note"),
            )
        }
    }
}
