package dev.poc.notifinterceptor.data

import android.content.Context
import dev.poc.notifinterceptor.domain.ResearchPolicy
import java.io.File
import java.io.FilterOutputStream
import java.io.OutputStream
import java.io.OutputStreamWriter
import java.io.Writer
import java.security.MessageDigest
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

object ResearchArchive {
    const val MAX_JSON_BYTES = 64 * 1024 * 1024
    const val MAX_ZIP_BYTES = 24 * 1024 * 1024
    const val ENTRY = "research.json"

    fun eventId(participant: String, local: String): String {
        val bytes = MessageDigest.getInstance("SHA-256").digest("$participant|$local".toByteArray(Charsets.UTF_8))
        val hex = "0123456789abcdef"
        return buildString(64) { bytes.forEach { append(hex[(it.toInt() and 255) shr 4]); append(hex[it.toInt() and 15]) } }
    }

    private class Limited(output: OutputStream) : FilterOutputStream(output) {
        private var count = 0L
        override fun write(bytes: ByteArray, offset: Int, length: Int) {
            check(count + length <= MAX_JSON_BYTES) { "数据文件超过导出容量，原始数据仍保留，请联系研究者" }
            out.write(bytes, offset, length); count += length
        }
        override fun write(value: Int) { write(byteArrayOf(value.toByte()), 0, 1) }
    }

    fun create(context: Context, settings: ResearchSettings, appVersion: String, sdk: Int, failures: Long,
               snapshot: (Writer, Map<String, Any?>) -> Unit): File {
        val directory = File(context.cacheDir, "research-shares").apply { mkdirs() }
        directory.listFiles()?.filter { it.name.endsWith(".part") && it.isFile }?.forEach { it.delete() }
        val stamp = LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss"))
        val id = UUID.randomUUID().toString()
        val destination = File(directory, "research_${settings.participantId.take(8)}_${stamp}_${id.take(8)}.zip")
        val temporary = File(directory, destination.name + ".part")
        val now = System.currentTimeMillis()
        val metadata = mapOf(
            "schemaVersion" to 1, "kind" to "notification_research_export", "exportId" to id,
            "participantId" to settings.participantId, "createdAt" to now,
            "consent" to mapOf("version" to settings.acceptedDisclosureVersion, "acceptedAt" to settings.consentAt,
                "ruleStructures" to settings.ruleStructures, "configurationRevision" to settings.revision),
            "app" to mapOf("version" to appVersion, "androidApi" to sdk),
            "scope" to mapOf("unit" to "processing_event", "historyIndependent" to true,
                "foregroundAndCoverage" to "observed_only", "retentionDays" to 30),
            "period" to mapOf("startedAt" to settings.consentAt, "endedAt" to settings.endedAt),
            "retention" to mapOf("eventDays" to if (settings.acceptedDisclosureVersion < 2) 7 else 14, "hourDays" to 30, "eventLimit" to ResearchPolicy.EVENT_LIMIT,
                "hourLimit" to ResearchPolicy.HOUR_LIMIT, "databaseMaxBytes" to ResearchPolicy.DATABASE_MAX_BYTES),
            "captureFailuresSinceProcessStart" to failures,
        )
        try {
            ZipOutputStream(temporary.outputStream().buffered()).use { zip ->
                zip.putNextEntry(ZipEntry(ENTRY))
                val writer = OutputStreamWriter(Limited(zip), Charsets.UTF_8).buffered()
                snapshot(writer, metadata)
                writer.flush()
                zip.closeEntry()
            }
            check(temporary.length() <= MAX_ZIP_BYTES) { "导出文件过大，原始数据仍保留，请联系研究者" }
            check(temporary.renameTo(destination)) { "文件未生成，请重试；原始数据仍保留" }
            // Share targets may read asynchronously; retain recent completed files.
            directory.listFiles()?.filter { it != destination && it.extension == "zip" }
                ?.sortedByDescending { it.lastModified() }?.drop(2)?.forEach { it.delete() }
            return destination
        } finally { temporary.delete() }
    }
}
