package dev.poc.notifinterceptor.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayInputStream

class PresetTransferContentTest {
    @Test
    fun `中文UTF8和可选BOM无损读取`() {
        val json = "{\"name\":\"工作与睡眠\"}"
        assertEquals(json, PresetTransferContent.read(ByteArrayInputStream(json.toByteArray(Charsets.UTF_8))))
        assertEquals(json, PresetTransferContent.read(ByteArrayInputStream(("\uFEFF" + json).toByteArray(Charsets.UTF_8))))
        assertEquals(json, String(PresetTransferContent.encode(json), Charsets.UTF_8))
    }

    @Test
    fun `超限导入导出与坏UTF8拒绝而不截断文字`() {
        val oversize = ByteArray(PresetTransferContent.MAX_BYTES + 1) { 'a'.code.toByte() }
        assertThrows(IllegalArgumentException::class.java) {
            PresetTransferContent.read(ByteArrayInputStream(oversize))
        }
        assertThrows(IllegalArgumentException::class.java) {
            PresetTransferContent.encode("词".repeat(PresetTransferContent.MAX_BYTES / 3 + 1))
        }
        assertThrows(IllegalArgumentException::class.java) {
            PresetTransferContent.read(ByteArrayInputStream(byteArrayOf(0xc3.toByte(), 0x28)))
        }
        assertThrows(IllegalArgumentException::class.java) { PresetTransferContent.encode(" ") }
    }

    @Test
    fun `对比导出可使用8MiB限制且默认预设限制仍为2MiB`() {
        val content = "a".repeat(PresetTransferContent.MAX_BYTES + 1)
        assertThrows(IllegalArgumentException::class.java) { PresetTransferContent.encode(content) }
        assertEquals(content.length, PresetTransferContent.encode(content, 8 * 1024 * 1024).size)
        val error = assertThrows(IllegalArgumentException::class.java) {
            PresetTransferContent.encode("a".repeat(8 * 1024 * 1024 + 1), 8 * 1024 * 1024)
        }
        assertTrue(error.message.orEmpty().contains("8 MiB"))
    }
}
