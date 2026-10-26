package dev.poc.notifinterceptor.data

import java.io.File

/**
 * 极简文件存储：先写临时文件再 rename，避免进程被杀导致半截文件。
 * 损坏的旧文件会保留为 .bak 便于排查，而不是静默丢弃。
 */
class JsonStore(val file: File) {

    fun readText(): String? = if (file.exists()) runCatching { file.readText() }.getOrNull() else null

    fun writeText(content: String) {
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, "${file.name}.tmp")
        temp.writeText(content)
        if (file.exists()) {
            file.copyTo(File(file.parentFile, "${file.name}.bak"), overwrite = true)
        }
        if (!temp.renameTo(file)) {
            file.writeText(content)
            temp.delete()
        }
    }

    fun quarantine() {
        if (file.exists()) {
            file.copyTo(File(file.parentFile, "${file.name}.bak"), overwrite = true)
            file.delete()
        }
    }
}
