package dev.poc.notifinterceptor.domain

/**
 * 同一 key 的重复回调去重。
 *
 * 系统在 ranking 变化、重新绑定监听器、分组重排时会对**已经存在的通知**
 * 再次调用 onNotificationPosted。若不去重，会出现重复判定、重复入库，
 * 以及"旧通知重新处理"导致的历史与延迟统计失真。
 *
 * 判定依据：key 相同且内容签名一致 → 视为同一次投递。
 * 内容变化（更新通知）或 postTime 变化（重新发出）仍会正常处理。
 */
class NotificationDeduplicator(private val maxEntries: Int = DEFAULT_CAPACITY) {

    private val seen = object : LinkedHashMap<String, String>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>): Boolean =
            size > maxEntries
    }

    /** @return true 表示需要走后续判定；false 表示是同一次投递的重复回调。 */
    @Synchronized
    fun shouldProcess(snapshot: NotificationSnapshot): Boolean {
        val signature = signatureOf(snapshot)
        if (seen[snapshot.key] == signature) return false
        seen[snapshot.key] = signature
        return true
    }

    @Synchronized
    fun clear() = seen.clear()

    private fun signatureOf(snapshot: NotificationSnapshot): String = buildString {
        append(snapshot.postTime)
        append('|')
        append(snapshot.title)
        append('|')
        append(snapshot.text)
        append('|')
        append(snapshot.bigText)
        append('|')
        append(snapshot.textLines.joinToString("\u0001"))
        append('|')
        append(snapshot.channelId)
        append('|')
        append(snapshot.isOngoing)
        append('|')
        append(snapshot.isClearable)
    }

    companion object {
        const val DEFAULT_CAPACITY = 256
    }
}
