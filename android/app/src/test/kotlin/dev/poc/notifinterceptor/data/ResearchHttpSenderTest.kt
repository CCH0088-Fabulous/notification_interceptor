package dev.poc.notifinterceptor.data

import dev.poc.notifinterceptor.domain.ResearchUploadProtocol
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.io.DataInputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

class ResearchHttpSenderTest {
    // Uses only APIs available on the Android/JVM unit test classpath.
    private data class Request(val headers: Map<String, String>, val body: String)
    private data class Response(val code: Int, val body: String, val headers: String = "")
    private class Server(private val handler: (Request) -> Response) : Closeable {
        private val socket = ServerSocket(0, 10, InetAddress.getByName("127.0.0.1"))
        private val executor = Executors.newSingleThreadExecutor()
        private val failure = AtomicReference<Throwable?>()
        val url get() = "http://127.0.0.1:${socket.localPort}/upload"
        init {
            executor.execute {
                while (!socket.isClosed) {
                    try {
                        socket.accept().use { client ->
                            client.soTimeout = 5000
                            val input = DataInputStream(client.getInputStream())
                            fun line(): String {
                                val text = StringBuilder()
                                while (true) {
                                    val value = input.read()
                                    if (value < 0 || value == 10) return text.toString().trimEnd('\r')
                                    text.append(value.toChar())
                                }
                            }
                            line()
                            val headers = mutableMapOf<String, String>()
                            while (true) {
                                val text = line()
                                if (text.isEmpty()) break
                                headers[text.substringBefore(':').lowercase()] = text.substringAfter(':').trim()
                            }
                            val body = ByteArray(headers["content-length"]!!.toInt())
                            input.readFully(body)
                            val response = handler(Request(headers, body.toString(Charsets.UTF_8)))
                            val bytes = response.body.toByteArray(Charsets.UTF_8)
                            client.getOutputStream().use { out ->
                                out.write(("HTTP/1.1 ${response.code} Test\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n${response.headers}\r\n").toByteArray())
                                out.write(bytes); out.flush()
                            }
                        }
                    } catch (error: Throwable) {
                        if (!socket.isClosed) failure.set(error)
                    }
                }
            }
        }
        override fun close() {
            socket.close(); executor.shutdownNow()
            failure.get()?.let { throw AssertionError("Loopback receiver failed", it) }
        }
    }

    @Test fun `发送固定批次与受限令牌 只有匹配保存确认才完成`() {
        var requests = 0
        Server { request ->
            requests++
            assertEquals("Bearer restricted-token", request.headers["authorization"])
            assertEquals("NotifInterceptor-Research/1", request.headers["user-agent"])
            assertEquals("same-batch", request.headers["idempotency-key"])
            assertEquals("same-batch", Json.parseObject(request.body)!!["batchId"])
            assertFalse(request.body.contains("restricted-token"))
            Response(200, if (requests == 1) "{\"acceptedBatchId\":\"wrong-batch\"}" else "{\"acceptedBatchId\":\"same-batch\"}")
        }.use { server ->
            val sender = ResearchHttpSender()
            val payload = mapOf("batchId" to "same-batch", "hours" to emptyList<Any>())
            val first = sender.send(server.url, "restricted-token", payload)
            assertFalse(ResearchUploadProtocol.acknowledged(first.code, "same-batch", first.body))
            val second = sender.send(server.url, "restricted-token", payload)
            assertTrue(ResearchUploadProtocol.acknowledged(second.code, "same-batch", second.body))
            assertEquals(2, requests)
        }
    }

    @Test fun `重定向不会携带令牌转发到另一个地址`() {
        var requests = 0
        Server { requests++; Response(307, "", "Location: /unexpected\r\n") }.use { server ->
            val reply = ResearchHttpSender().send(server.url, "secret", mapOf("batchId" to "id"))
            assertEquals(307, reply.code)
            assertEquals(1, requests)
            assertFalse(ResearchUploadProtocol.acknowledged(200, "id", null))
            assertFalse(ResearchUploadProtocol.acknowledged(500, "id", mapOf("acceptedBatchId" to "id")))
            assertTrue(ResearchUploadProtocol.retryable(429))
            assertTrue(ResearchUploadProtocol.retryable(503))
            assertFalse(ResearchUploadProtocol.retryable(401))
        }
    }

    @Test fun `响应有界 拒绝过大回执`() {
        Server { Response(200, "A".repeat(ResearchUploadProtocol.MAX_RESPONSE_BYTES + 1)) }.use { server ->
            assertThrows(IllegalArgumentException::class.java) {
                ResearchHttpSender().send(server.url, "secret", mapOf("batchId" to "id"))
            }
        }
    }

    @Test fun `同意撤回检查阻止新请求发出`() {
        var requests = 0
        Server { requests++; Response(200, "{}") }.use { server ->
            assertThrows(IllegalStateException::class.java) {
                ResearchHttpSender().send(server.url, "secret", mapOf("batchId" to "id")) { false }
            }
            assertEquals(0, requests)
        }
    }

    @Test fun `设备登记和统计使用独立凭证 登记不发送通知内容`() {
        Server { request ->
            assertEquals("Bearer install-credential",request.headers["authorization"])
            assertEquals("pilot-build-key",request.headers["x-research-enrollment-key"])
            assertEquals("install-id",request.headers["idempotency-key"])
            assertFalse(request.body.contains("install-credential"))
            assertFalse(request.body.contains("pilot-build-key"))
            Response(200,"{\"enrolledParticipantId\":\"install-id\"}")
        }.use { server ->
            val result = ResearchHttpSender().send(server.url,"install-credential",
                mapOf("schemaVersion" to 1,"participantId" to "install-id","consentVersion" to 1),"pilot-build-key")
            assertTrue(dev.poc.notifinterceptor.domain.ResearchEnrollmentProtocol.acknowledged(result.code,"install-id",result.body))
        }
    }
}
