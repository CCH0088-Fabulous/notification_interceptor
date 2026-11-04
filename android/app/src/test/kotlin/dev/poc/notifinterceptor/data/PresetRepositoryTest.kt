package dev.poc.notifinterceptor.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class PresetRepositoryTest {

    @get:Rule
    val directory = TemporaryFolder()

    private fun preset(id: String = "preset_1", kind: String = "keywords"): Map<String, Any?> = mapOf(
        "id" to id,
        "name" to "过滤促销",
        "kind" to kind,
        "keywords" to listOf("秒杀", "优惠"),
        "allowKeywords" to listOf("验证码"),
        "packages" to listOf("com.demo.shop"),
        "quietHours" to null,
    )

    private fun library(vararg presets: Map<String, Any?>): Map<String, Any?> =
        mapOf("schemaVersion" to 2, "presets" to presets.toList(), "versions" to emptyList<Any>())

    @Test
    fun `不存在的预设库返回空列表而不创建文件`() {
        assertEquals(library(), PresetRepository(directory.root).load())
        assertFalse(File(directory.root, "presets.json").exists())
    }

    @Test
    fun `跨天场景完整持久化并能由新仓储实例读取`() {
        val scene = preset(kind = "scene") + ("quietHours" to mapOf(
            "from" to "22:00", "to" to "08:00", "days" to listOf(1, 2, 3, 4, 5),
        ))
        val expected = library(scene)
        PresetRepository(directory.root).save(expected)
        assertEquals(expected, PresetRepository(directory.root).load())
    }

    @Test
    fun `保存新版本时保留上一版本备份而不触碰执行规则`() {
        val rules = File(directory.root, "rules.json").apply { writeText("unchanged rules") }
        val repo = PresetRepository(directory.root)
        repo.save(library(preset()))
        val original = File(directory.root, "presets.json").readText()
        repo.save(library())
        assertEquals(original, File(directory.root, "presets.json.bak").readText())
        assertEquals(emptyList<Any>(), repo.load()["presets"])
        assertEquals(1, (repo.load()["versions"] as List<*>).size)
        assertEquals("unchanged rules", rules.readText())
        assertFalse(File(directory.root, "presets.json.tmp").exists())
    }

    @Test
    fun `损坏文件读取报错且保存不会覆盖原内容`() {
        val file = File(directory.root, "presets.json").apply { writeText("broken json {") }
        val repo = PresetRepository(directory.root)
        assertThrows(IllegalStateException::class.java) { repo.load() }
        assertThrows(IllegalStateException::class.java) { repo.save(library(preset())) }
        assertEquals("broken json {", file.readText())
    }

    @Test
    fun `未来版本读取报错并保留原文件`() {
        val raw = "{\"schemaVersion\":3,\"presets\":[]}"
        val file = File(directory.root, "presets.json").apply { writeText(raw) }
        val repo = PresetRepository(directory.root)
        assertThrows(IllegalArgumentException::class.java) { repo.load() }
        assertThrows(IllegalArgumentException::class.java) { repo.save(library()) }
        assertEquals(raw, file.readText())
    }

    @Test
    fun `重复 id 和空过滤词保存失败且旧库不变`() {
        val repo = PresetRepository(directory.root)
        val expected = library(preset())
        repo.save(expected)
        assertThrows(IllegalArgumentException::class.java) { repo.save(library(preset(), preset())) }
        assertThrows(IllegalArgumentException::class.java) {
            repo.save(library(preset() + ("keywords" to emptyList<String>())))
        }
        assertEquals(expected, repo.load())
    }

    @Test
    fun `非法或空时段拒绝写入`() {
        val repo = PresetRepository(directory.root)
        for (hours in listOf(
            mapOf("from" to "25:00", "to" to "08:00", "days" to listOf(1)),
            mapOf("from" to "22:00", "to" to "22:00", "days" to listOf(1)),
            mapOf("from" to "22:00", "to" to "08:00", "days" to emptyList<Int>()),
            mapOf("from" to "22:00", "to" to "08:00", "days" to listOf(8)),
        )) {
            assertThrows(IllegalArgumentException::class.java) {
                repo.save(library(preset(kind = "scene") + ("quietHours" to hours)))
            }
        }
        assertFalse(File(directory.root, "presets.json").exists())
    }

    @Test
    fun `文本条数和长度有限制且不允许未知类型`() {
        val repo = PresetRepository(directory.root)
        for (invalid in listOf(
            preset() + ("name" to "a".repeat(61)),
            preset() + ("keywords" to List(101) { "word_$it" }),
            preset() + ("keywords" to listOf("a".repeat(101))),
            preset() + ("id" to "invalid.id"),
            preset() + ("packages" to listOf("invalid_package")),
            preset(kind = "unknown"),
        )) {
            assertThrows(IllegalArgumentException::class.java) { repo.save(library(invalid)) }
        }
        assertTrue(repo.load()["presets"] == emptyList<Any>())
    }
}
