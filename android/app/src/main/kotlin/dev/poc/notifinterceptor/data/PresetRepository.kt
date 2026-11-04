package dev.poc.notifinterceptor.data

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/**
 * 用户预设库独立于正在执行的 rules.json。坏文件不会被当作空库覆盖，
 * 写入采用同目录临时文件与原子替换；成功前保留旧文件和最近一次备份。
 */
class PresetRepository(
    directory: File,
    private val now: () -> Long = System::currentTimeMillis,
) {

    private val file = File(directory, "presets.json")

    @Synchronized
    fun load(): Map<String, Any?> {
        if (!file.exists()) return library(emptyList(), emptyList())
        require(file.isFile) { "预设存储不是文件" }
        require(file.length() <= MAX_BYTES) { "预设库过大，无法读取" }
        val text = runCatching { PresetTransferContent.decode(file.readBytes()) }
            .getOrElse { throw IllegalStateException("预设库编码损坏，原文件已保留", it) }
        val parsed = Json.parseObject(text)
            ?: throw IllegalStateException("预设库损坏，原文件已保留")
        return validateStoredLibrary(parsed)
    }

    @Synchronized
    fun save(raw: Map<*, *>): Map<String, Any?> {
        requireSupportedVersion(raw["schemaVersion"])
        val presets = validatePresets(raw["presets"])
        checkCurrentSize(presets)
        // Read and validate the complete old store before changing anything.
        // Incoming version history is deliberately never imported or trusted.
        val previous = load()
        val oldPresets = storedMaps(previous["presets"])
        val oldVersions = storedMaps(previous["versions"])
        val nextById = presets.associateBy { it["id"] }
        val archived = oldPresets.mapNotNull { old ->
            val replacement = nextById[old["id"]]
            if (replacement == old) null else version(
                old,
                if (replacement == null) "删除前" else "修改前",
            )
        }
        return write(library(presets, (archived + oldVersions).take(MAX_VERSIONS)))
    }

    /** A named checkpoint only adds history; it never changes active rules. */
    @Synchronized
    fun saveVersion(presetId: String, label: String? = null): Map<String, Any?> {
        val previous = load()
        val presets = storedMaps(previous["presets"])
        val preset = presets.firstOrNull { it["id"] == presetId }
            ?: throw IllegalArgumentException("预设已不存在，请重新读取")
        val name = label?.trim()?.takeIf { it.isNotEmpty() } ?: "手动快照"
        requiredText(name, "版本名称", 60)
        val versions = (listOf(version(preset, name)) + storedMaps(previous["versions"]))
            .take(MAX_VERSIONS)
        return write(library(presets, versions))
    }

    private fun write(validated: Map<String, Any?>): Map<String, Any?> {
        val encoded = Json.stringify(validated)
        require(encoded.toByteArray(Charsets.UTF_8).size <= MAX_BYTES) { "预设库过大，无法保存" }
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, "${file.name}.tmp")
        try {
            temp.outputStream().use { stream ->
                stream.write(encoded.toByteArray(Charsets.UTF_8))
                stream.fd.sync()
            }
            if (file.exists()) {
                val backupTemp = File(file.parentFile, "${file.name}.bak.tmp")
                try {
                    file.copyTo(backupTemp, overwrite = true)
                    atomicReplace(backupTemp, File(file.parentFile, "${file.name}.bak"))
                } finally {
                    backupTemp.delete()
                }
            }
            atomicReplace(temp, file)
        } finally {
            temp.delete()
        }
        return validated
    }

    private fun atomicReplace(source: File, destination: File) {
        Files.move(
            source.toPath(), destination.toPath(),
            StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING,
        )
    }

    private fun requireSupportedVersion(version: Any?): Int {
        require(version is Number && version.toDouble() in listOf(1.0, SCHEMA_VERSION.toDouble())) {
            "不支持的预设版本，原文件已保留"
        }
        return version.toInt()
    }

    private fun validateStoredLibrary(raw: Map<*, *>): Map<String, Any?> {
        val schema = requireSupportedVersion(raw["schemaVersion"])
        val presets = validatePresets(raw["presets"])
        checkCurrentSize(presets)
        val versions = if (schema == 1) {
            require(raw["versions"] == null) { "旧版预设库包含未知历史，原文件已保留" }
            emptyList()
        } else {
            validateVersions(raw["versions"])
        }
        return library(presets, versions)
    }

    private fun validatePresets(raw: Any?): List<Map<String, Any?>> {
        val presets = raw as? List<*>
            ?: throw IllegalArgumentException("预设列表缺失")
        require(presets.size <= MAX_PRESETS) { "最多保存 $MAX_PRESETS 个预设" }
        val ids = mutableSetOf<String>()
        return presets.map { item ->
            val normalized = validatePreset(item)
            require(ids.add(normalized["id"] as String)) { "预设 id 重复" }
            normalized
        }
    }

    private fun validatePreset(item: Any?): Map<String, Any?> {
        val preset = item as? Map<*, *> ?: throw IllegalArgumentException("预设格式无效")
        val id = requiredText(preset["id"], "预设 id", 80)
        require(id.matches(Regex("[A-Za-z0-9_-]+"))) { "预设 id 无效" }
        val name = requiredText(preset["name"], "预设名称", 60)
        val kind = preset["kind"] as? String
        require(kind == "keywords" || kind == "scene") { "预设类型无效" }
        val keywords = stringList(preset["keywords"], "过滤词")
        require(keywords.isNotEmpty()) { "至少填写一个过滤词" }
        val allowKeywords = stringList(preset["allowKeywords"], "优先保留词")
        val packages = stringList(preset["packages"], "应用范围")
        require(packages.all { it.matches(Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")) }) {
            "应用包名格式不正确"
        }
        val quiet = preset["quietHours"]
        require(kind == "scene" || quiet == null) { "关键词预设不支持时段" }
        return mapOf(
            "id" to id,
            "name" to name,
            "kind" to kind,
            "keywords" to keywords,
            "allowKeywords" to allowKeywords,
            "packages" to packages,
            "quietHours" to quiet?.let { validateHours(it) },
        )
    }

    private fun validateVersions(raw: Any?): List<Map<String, Any?>> {
        val versions = raw as? List<*> ?: throw IllegalArgumentException("版本记录缺失")
        require(versions.size <= MAX_VERSIONS) { "版本记录超过上限" }
        val ids = mutableSetOf<String>()
        return versions.map { item ->
            val value = item as? Map<*, *> ?: throw IllegalArgumentException("版本记录格式无效")
            val id = requiredText(value["id"], "版本 id", 120)
            require(id.matches(Regex("[A-Za-z0-9_-]+"))) {
                "版本 id 无效"
            }
            require(ids.add(id)) { "版本 id 重复" }
            val createdAt = value["createdAt"]
            require(createdAt is Number && createdAt.toLong() in 1L..MAX_TIMESTAMP &&
                createdAt.toDouble() == createdAt.toLong().toDouble()) { "版本时间无效" }
            mapOf(
                "id" to id,
                "createdAt" to createdAt.toLong(),
                "label" to requiredText(value["label"], "版本名称", 60),
                "preset" to validatePreset(value["preset"]),
            )
        }
    }

    private fun version(preset: Map<String, Any?>, label: String): Map<String, Any?> {
        val createdAt = now()
        check(createdAt in 1L..MAX_TIMESTAMP) { "无法读取版本保存时间" }
        return mapOf(
            "id" to UUID.randomUUID().toString(),
            "createdAt" to createdAt,
            "label" to label,
            "preset" to preset,
        )
    }

    private fun checkCurrentSize(presets: List<Map<String, Any?>>) {
        val content = mapOf("schemaVersion" to 1, "presets" to presets)
        require(Json.stringify(content).toByteArray(Charsets.UTF_8).size <= MAX_CURRENT_BYTES) {
            "当前预设总大小超过 2 MiB，无法完整导出"
        }
    }

    private fun library(
        presets: List<Map<String, Any?>>,
        versions: List<Map<String, Any?>>,
    ): Map<String, Any?> = mapOf(
        "schemaVersion" to SCHEMA_VERSION,
        "presets" to presets,
        "versions" to versions,
    )

    @Suppress("UNCHECKED_CAST")
    private fun storedMaps(value: Any?): List<Map<String, Any?>> = value as List<Map<String, Any?>>

    private fun validateHours(raw: Any): Map<String, Any?> {
        val hours = raw as? Map<*, *> ?: throw IllegalArgumentException("场景时段格式无效")
        val from = hours["from"] as? String
        val to = hours["to"] as? String
        val pattern = Regex("(?:[01][0-9]|2[0-3]):[0-5][0-9]")
        require(from != null && to != null && pattern.matches(from) && pattern.matches(to)) {
            "场景时间必须为 HH:mm"
        }
        require(from != to) { "场景起止时间不能相同" }
        val days = hours["days"] as? List<*> ?: throw IllegalArgumentException("场景星期缺失")
        require(days.isNotEmpty() && days.size <= 7) { "至少选择一个生效日" }
        val normalizedDays = days.map { day ->
            require(day is Number && day.toDouble() == day.toInt().toDouble() && day.toInt() in 1..7) {
                "场景星期必须在 1 到 7 之间"
            }
            day.toInt()
        }
        require(normalizedDays.distinct().size == normalizedDays.size) { "场景星期重复" }
        return mapOf("from" to from, "to" to to, "days" to normalizedDays.sorted())
    }

    private fun stringList(raw: Any?, label: String, maxLength: Int = 100): List<String> {
        val values = raw as? List<*> ?: throw IllegalArgumentException("${label}格式无效")
        require(values.size <= MAX_WORDS) { "$label 最多 $MAX_WORDS 项" }
        return values.map { requiredText(it, label, maxLength) }.distinct()
    }

    private fun requiredText(raw: Any?, label: String, max: Int): String {
        val text = raw as? String ?: throw IllegalArgumentException("$label 必须为文本")
        require(text.isNotBlank() && text.length <= max && text == text.trim()) { "$label 不能为空且最多 $max 字符" }
        return text
    }

    companion object {
        const val SCHEMA_VERSION = 2
        const val MAX_VERSIONS = 20
        private const val MAX_PRESETS = 100
        private const val MAX_WORDS = 100
        private const val MAX_CURRENT_BYTES = 2 * 1024 * 1024
        private const val MAX_BYTES = 8 * 1024 * 1024
        private const val MAX_TIMESTAMP = 8_640_000_000_000_000L
    }
}
