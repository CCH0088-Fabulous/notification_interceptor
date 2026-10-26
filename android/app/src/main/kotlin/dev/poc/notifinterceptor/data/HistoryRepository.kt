package dev.poc.notifinterceptor.data

import dev.poc.notifinterceptor.domain.HistoryEntry
import dev.poc.notifinterceptor.domain.HistorySink
import dev.poc.notifinterceptor.domain.RuleAction
import java.io.File

/**
 * 历史记录：JSONL 追加写 + 内存环形缓冲。
 * 超过 [maxEntries] 时整体重写文件，保留最新的 N 条。
 */
class HistoryRepository(
    directory: File,
    private val maxEntries: Int = DEFAULT_MAX_ENTRIES,
) : HistorySink {
    private val file = File(directory, "history.jsonl")
    private val lock = Any()
    private val entries = ArrayDeque<HistoryEntry>()
    private var loaded = false

    override fun append(entry: HistoryEntry) {
        synchronized(lock) {
            ensureLoaded()
            entries.addLast(entry)
            runCatching {
                file.parentFile?.mkdirs()
                file.appendText(Json.stringify(entry.toMap()) + "\n")
            }
            trimLocked()
        }
    }

    fun query(
        limit: Int = 100,
        offset: Int = 0,
        packageName: String? = null,
        action: RuleAction? = null,
        sinceMillis: Long? = null,
    ): List<HistoryEntry> = synchronized(lock) {
        ensureLoaded()
        entries.asSequence()
            .filter { packageName.isNullOrBlank() || it.snapshot.packageName == packageName }
            .filter { action == null || it.action == action }
            .filter { sinceMillis == null || it.timestamp >= sinceMillis }
            .sortedByDescending { it.timestamp }
            .drop(offset.coerceAtLeast(0))
            .take(limit.coerceIn(1, maxEntries))
            .toList()
    }

    fun count(): Int = synchronized(lock) {
        ensureLoaded()
        entries.size
    }

    fun clear() {
        synchronized(lock) {
            entries.clear()
            loaded = true
            runCatching {
                if (file.exists()) file.writeText("")
            }
        }
    }

    fun seenPackages(): List<String> = synchronized(lock) {
        ensureLoaded()
        entries.asSequence()
            .map { it.snapshot.packageName }
            .filter { it.isNotBlank() }
            .distinct()
            .sorted()
            .toList()
    }

    fun stats(): Map<String, Any?> = synchronized(lock) {
        ensureLoaded()
        val byAction = entries.groupingBy { it.action.wire }.eachCount()
        val byPackage = entries.groupingBy { it.snapshot.packageName }
            .eachCount()
            .entries
            .sortedByDescending { it.value }
            .take(10)
            .associate { it.key to it.value }
        mapOf(
            "total" to entries.size,
            "byAction" to byAction,
            "topPackages" to byPackage,
        )
    }

    fun exportJson(): String = synchronized(lock) {
        ensureLoaded()
        Json.stringify(entries.sortedByDescending { it.timestamp }.map { it.toMap() })
    }

    /** 供历史页做二次检索的包名+应用名列表。 */
    fun exportEntries(): List<HistoryEntry> = synchronized(lock) {
        ensureLoaded()
        entries.toList()
    }

    private fun ensureLoaded() {
        if (loaded) return
        loaded = true
        if (!file.exists()) return
        val parsed = runCatching { file.readLines() }.getOrElse { emptyList() }
        for (line in parsed) {
            if (line.isBlank()) continue
            val map = Json.parseObject(line) ?: continue
            HistoryEntry.fromMap(map)?.let { entries.addLast(it) }
        }
        trimLocked()
    }

    private fun trimLocked() {
        if (entries.size <= maxEntries) return
        while (entries.size > maxEntries) {
            entries.removeFirst()
        }
        runCatching {
            val content = entries.joinToString(separator = "\n", postfix = "\n") {
                Json.stringify(it.toMap())
            }
            file.writeText(content)
        }
    }

    companion object {
        const val DEFAULT_MAX_ENTRIES = 1000
    }
}
