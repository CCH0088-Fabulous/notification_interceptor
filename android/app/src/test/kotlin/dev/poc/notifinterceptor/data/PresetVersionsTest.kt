package dev.poc.notifinterceptor.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class PresetVersionsTest {
    @get:Rule
    val directory = TemporaryFolder()

    private fun preset(id: String = "preset_1", name: String = "过滤促销"): Map<String, Any?> = mapOf(
        "id" to id, "name" to name, "kind" to "keywords",
        "keywords" to listOf("秒杀", "优惠"), "allowKeywords" to listOf("验证码"),
        "packages" to listOf("com.demo.shop"), "quietHours" to null,
    )

    private fun input(vararg presets: Map<String, Any?>): Map<String, Any?> =
        mapOf("schemaVersion" to 1, "presets" to presets.toList())

    private fun current(vararg presets: Map<String, Any?>): Map<String, Any?> =
        mapOf("schemaVersion" to 2, "presets" to presets.toList(), "versions" to emptyList<Any>())

    @Suppress("UNCHECKED_CAST")
    private fun versions(library: Map<String, Any?>) = library["versions"] as List<Map<String, Any?>>

    @Test
    fun `v1读取兼容但不改文件 首次保存原子迁移到v2`() {
        val original = Json.stringify(input(preset()))
        val file = File(directory.root, "presets.json").apply { writeText(original) }
        val repo = PresetRepository(directory.root)
        assertEquals(current(preset()), repo.load())
        assertEquals(original, file.readText())
        repo.save(input(preset()))
        // org.json omits null map values on disk; the repository normalizes
        // optional fields when reading the migrated library.
        assertEquals(2, Json.parseObject(file.readText())!!["schemaVersion"])
        assertEquals(current(preset()), repo.load())
        assertEquals(original, File(directory.root, "presets.json.bak").readText())
    }

    @Test
    fun `修改和删除归档旧定义 相同内容保存不会添加历史`() {
        val repo = PresetRepository(directory.root) { 1793800000000L }
        val original = preset()
        val edited = preset(name = "新词表")
        assertTrue(versions(repo.save(input(original))).isEmpty())
        val first = versions(repo.save(input(edited))).single()
        assertEquals(original, first["preset"])
        assertEquals("修改前", first["label"])
        assertEquals(1793800000000L, first["createdAt"])
        assertEquals(1, versions(repo.save(input(edited))).size)
        val deleted = repo.save(input())
        assertEquals(emptyList<Any>(), deleted["presets"])
        assertEquals(edited, versions(deleted).first()["preset"])
        assertEquals("删除前", versions(deleted).first()["label"])
    }

    @Test
    fun `手动命名快照持久化且不会修改当前词库`() {
        val repo = PresetRepository(directory.root) { 1793800000001L }
        repo.save(input(preset()))
        val saved = repo.saveVersion("preset_1", "演示前")
        assertEquals(listOf(preset()), saved["presets"])
        assertEquals("演示前", versions(saved).single()["label"])
        assertEquals(saved, PresetRepository(directory.root).load())
        assertThrows(IllegalArgumentException::class.java) { repo.saveVersion("missing") }
        assertThrows(IllegalArgumentException::class.java) { repo.saveVersion("preset_1", "x".repeat(61)) }
        assertEquals(saved, repo.load())
    }

    @Test
    fun `回退旧定义会归档回退前版本 再次删除仍可恢复`() {
        val repo = PresetRepository(directory.root)
        val original = preset()
        val edited = preset() + ("keywords" to listOf("直播"))
        repo.save(input(original))
        repo.save(input(edited))
        val restored = repo.save(input(original))
        assertEquals(edited, versions(restored).first()["preset"])
        assertEquals(original, (restored["presets"] as List<*>).single())
        repo.save(input())
        assertEquals(original, versions(repo.load()).first()["preset"])
    }

    @Test
    fun `历史最多保留最新20条且来路历史不能覆盖本地记录`() {
        var tick = 1793800000000L
        val repo = PresetRepository(directory.root) { tick++ }
        repo.save(input(preset()))
        repeat(25) { repo.saveVersion("preset_1", "版本$it") }
        val history = versions(repo.load())
        assertEquals(20, history.size)
        assertEquals("版本24", history.first()["label"])
        assertEquals("版本5", history.last()["label"])
        assertEquals(20, history.map { it["id"] }.toSet().size)
        val saved = repo.save(current(preset()) + ("versions" to listOf("untrusted")))
        assertEquals(history, versions(saved))
    }

    @Test
    fun `坏版本元数据和非法编码均保留原文件`() {
        val file = File(directory.root, "presets.json")
        val validVersion = mapOf("id" to "version_1", "createdAt" to 1L,
            "label" to "快照", "preset" to preset())
        val invalid = listOf(
            validVersion + ("createdAt" to 0L),
            validVersion + ("createdAt" to 8_640_000_000_000_001L),
            validVersion + ("label" to " "),
            validVersion + ("preset" to mapOf("id" to "bad")),
            validVersion + ("id" to "bad.id"),
        )
        val repo = PresetRepository(directory.root)
        for (entry in invalid) {
            val raw = Json.stringify(current(preset()) + ("versions" to listOf(entry)))
            file.writeText(raw)
            assertThrows(IllegalArgumentException::class.java) { repo.load() }
            assertThrows(IllegalArgumentException::class.java) { repo.save(input()) }
            assertEquals(raw, file.readText())
        }
        val bytes = "{\"schemaVersion\":1,\"presets\":[".toByteArray() + byteArrayOf(0xc3.toByte(), 0x28)
        file.writeBytes(bytes)
        assertThrows(IllegalStateException::class.java) { repo.load() }
        assertTrue(bytes.contentEquals(file.readBytes()))
    }

    @Test
    fun `写入失败不会改变当前库或旧版本`() {
        val repo = PresetRepository(directory.root)
        repo.save(input(preset()))
        repo.saveVersion("preset_1")
        val before = File(directory.root, "presets.json").readText()
        File(directory.root, "presets.json.tmp").mkdir()
        assertThrows(java.io.FileNotFoundException::class.java) {
            repo.save(input(preset(name = "无法写入")))
        }
        assertEquals(before, File(directory.root, "presets.json").readText())
        assertEquals(1, versions(repo.load()).size)
    }

    @Test
    fun `当前词库超过2MiB拒绝而不是生成无法分享的备份`() {
        val repo = PresetRepository(directory.root)
        repo.save(input(preset()))
        val before = repo.load()
        val large = (1..100).map { index -> preset("p_$index") + mapOf(
            "keywords" to (1..100).map { "$it" + "词".repeat(95) },
            "allowKeywords" to (1..100).map { "$it" + "留".repeat(95) },
        ) }
        assertThrows(IllegalArgumentException::class.java) {
            repo.save(mapOf("schemaVersion" to 1, "presets" to large))
        }
        assertEquals(before, repo.load())
    }
}
