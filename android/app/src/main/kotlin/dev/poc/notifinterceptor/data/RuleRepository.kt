package dev.poc.notifinterceptor.data

import dev.poc.notifinterceptor.domain.RuleEngine
import dev.poc.notifinterceptor.domain.RuleIssue
import dev.poc.notifinterceptor.domain.RuleSet
import java.io.File

/** 规则与全局开关的持久化。整包覆盖写，读取失败时回退空规则集。 */
class RuleRepository(directory: File, private val engine: RuleEngine) {

    private val store = JsonStore(File(directory, "rules.json"))

    @Volatile
    private var cached: RuleSet? = null

    @Volatile
    private var cachedModifiedAt: Long = -1L

    @Synchronized
    fun load(): RuleSet {
        val modifiedAt = if (store.file.exists()) store.file.lastModified() else 0L
        val current = cached
        // 文件被外部修改（导入/恢复/调试）时丢弃缓存，避免规则不生效。
        if (current != null && modifiedAt == cachedModifiedAt) return current
        val text = store.readText()
        val parsed = text?.let { Json.parseObject(it) }
        val ruleSet = if (parsed == null) {
            if (!text.isNullOrBlank()) store.quarantine()
            RuleSet.EMPTY
        } else {
            runCatching { RuleSet.fromMap(parsed) }.getOrElse {
                store.quarantine()
                RuleSet.EMPTY
            }
        }
        cached = ruleSet
        cachedModifiedAt = modifiedAt
        return ruleSet
    }

    @Synchronized
    fun save(ruleSet: RuleSet): RuleSet {
        store.writeText(Json.stringify(ruleSet.toMap()))
        cached = ruleSet
        cachedModifiedAt = store.file.lastModified()
        return ruleSet
    }

    fun validate(ruleSet: RuleSet): List<RuleIssue> = engine.validate(ruleSet)
}
