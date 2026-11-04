package dev.poc.notifinterceptor.data

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/** Bounded UTF-8 transfer, independent of Android's document-provider API. */
object PresetTransferContent {
    const val MAX_BYTES = 2 * 1024 * 1024

    fun read(input: InputStream): String {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            require(output.size() + count <= MAX_BYTES) { "预设文件不能超过 2 MiB" }
            output.write(buffer, 0, count)
        }
        return decode(output.toByteArray())
    }

    fun decode(bytes: ByteArray): String {
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return runCatching { decoder.decode(ByteBuffer.wrap(bytes)).toString() }
            .getOrElse { throw IllegalArgumentException("请选择 UTF-8 编码的 JSON 文件", it) }
            .removePrefix("\uFEFF")
    }

    fun encode(content: String, maxBytes: Int = MAX_BYTES): ByteArray {
        require(maxBytes > 0) { "导出大小限制无效" }
        val bytes = content.toByteArray(Charsets.UTF_8)
        require(bytes.size <= maxBytes) {
            "导出文件不能超过 ${maxBytes / (1024 * 1024)} MiB"
        }
        require(content.isNotBlank()) { "导出内容不能为空" }
        return bytes
    }
}
