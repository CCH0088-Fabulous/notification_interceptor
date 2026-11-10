package dev.poc.notifinterceptor.data

import dev.poc.notifinterceptor.domain.ResearchUploadProtocol
import java.net.HttpURLConnection
import java.net.URL

/** No redirects, custom trust manager, cookies or free-text server errors. */
class ResearchHttpSender {
    data class Reply(val code: Int, val body: Map<String, Any?>?)
    @Volatile private var active: HttpURLConnection? = null

    fun cancel() { active?.disconnect() }

    fun send(endpoint: String, token: String, payload: Map<String, Any?>,
             enrollmentKey: String? = null, allowed: () -> Boolean = { true }): Reply {
        val bytes = Json.stringify(payload).toByteArray(Charsets.UTF_8)
        require(bytes.size <= ResearchUploadProtocol.MAX_BYTES)
        val connection = URL(endpoint).openConnection() as HttpURLConnection
        active = connection
        try {
            check(allowed()) { "发送已停止" }
            val deadline = System.nanoTime() + 35_000_000_000L
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15_000; connection.readTimeout = 20_000
            connection.requestMethod = "POST"; connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("User-Agent", "NotifInterceptor-Research/1")
            connection.setRequestProperty("Authorization", "Bearer $token")
            if (enrollmentKey != null) connection.setRequestProperty("X-Research-Enrollment-Key", enrollmentKey)
            connection.setRequestProperty("Idempotency-Key", (payload["batchId"] ?: payload["participantId"]) as String)
            connection.setFixedLengthStreamingMode(bytes.size)
            check(allowed()) { "发送已停止" }
            connection.outputStream.use { check(allowed()); it.write(bytes) }
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val body = stream?.use { input ->
                val out = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(2048)
                while (true) {
                    check(allowed() && System.nanoTime() < deadline) { "发送已停止或超时" }
                    connection.readTimeout = ((deadline - System.nanoTime()) / 1_000_000).coerceIn(1, 20_000).toInt()
                    val count = input.read(buffer)
                    if (count < 0) break
                    require(out.size() + count <= ResearchUploadProtocol.MAX_RESPONSE_BYTES) { "响应过大" }
                    out.write(buffer, 0, count)
                }
                out.toByteArray()
            }
            require(body == null || body.size <= ResearchUploadProtocol.MAX_RESPONSE_BYTES) { "响应过大" }
            return Reply(code, body?.toString(Charsets.UTF_8)?.let(Json::parseObject))
        } finally {
            connection.disconnect()
            if (active === connection) active = null
        }
    }
}
