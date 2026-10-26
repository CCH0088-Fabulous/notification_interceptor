package dev.poc.notifinterceptor.domain

import java.time.Instant
import java.time.ZoneId

/**
 * 静默时段。天数采用 ISO 规则：1=周一 … 7=周日，跨天区间按**起始日**判断。
 */
data class QuietHours(
    val fromMinutes: Int,
    val toMinutes: Int,
    val days: Set<Int>,
) {
    init {
        require(fromMinutes in 0 until MINUTES_PER_DAY) { "fromMinutes 越界" }
        require(toMinutes in 0 until MINUTES_PER_DAY) { "toMinutes 越界" }
        require(days.all { it in 1..7 }) { "days 必须是 1..7" }
    }

    val isCrossMidnight: Boolean get() = fromMinutes > toMinutes

    fun matches(nowMillis: Long, zone: ZoneId = ZoneId.systemDefault()): Boolean {
        if (days.isEmpty()) return false
        if (fromMinutes == toMinutes) return false

        val now = Instant.ofEpochMilli(nowMillis).atZone(zone)
        val minute = now.hour * 60 + now.minute

        if (!isCrossMidnight) {
            return minute in fromMinutes until toMinutes && now.dayOfWeek.value in days
        }
        // 跨天：当前时间在起点之后时归属今天，否则归属昨天。
        val startDay = if (minute >= fromMinutes) {
            now.dayOfWeek.value
        } else {
            now.minusDays(1).dayOfWeek.value
        }
        val inWindow = minute >= fromMinutes || minute < toMinutes
        return inWindow && startDay in days
    }

    fun toMap(): Map<String, Any?> = mapOf(
        "from" to formatMinutes(fromMinutes),
        "to" to formatMinutes(toMinutes),
        "days" to days.sorted(),
    )

    companion object {
        const val MINUTES_PER_DAY = 24 * 60

        fun parse(value: String?): Int? {
            if (value.isNullOrBlank()) return null
            val parts = value.trim().split(":")
            if (parts.size != 2) return null
            val hour = parts[0].toIntOrNull() ?: return null
            val minute = parts[1].toIntOrNull() ?: return null
            if (hour !in 0..23 || minute !in 0..59) return null
            return hour * 60 + minute
        }

        fun formatMinutes(total: Int): String =
            "%02d:%02d".format(total / 60, total % 60)

        fun fromMap(map: Map<*, *>?): QuietHours? {
            if (map == null) return null
            val from = parse(map["from"] as? String) ?: return null
            val to = parse(map["to"] as? String) ?: return null
            val days = (map["days"] as? List<*>)
                ?.mapNotNull { (it as? Number)?.toInt() }
                ?.filter { it in 1..7 }
                ?.toSet()
                ?: (1..7).toSet()
            if (days.isEmpty()) return null
            return QuietHours(from, to, days)
        }
    }
}
