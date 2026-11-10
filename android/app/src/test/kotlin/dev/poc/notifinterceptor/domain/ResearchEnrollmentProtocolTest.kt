package dev.poc.notifinterceptor.domain

import org.junit.Assert.*
import org.junit.Test

class ResearchEnrollmentProtocolTest {
    @Test fun `凭证随机独立 回执必须匹配编号和成功状态`() {
        val credentials = (1..100).map { ResearchEnrollmentProtocol.newCredential() }
        assertEquals(100, credentials.toSet().size)
        assertTrue(credentials.all { it.matches(Regex("[A-Za-z0-9_-]{43}")) })
        assertTrue(ResearchEnrollmentProtocol.acknowledged(200,"install",mapOf("enrolledParticipantId" to "install")))
        assertFalse(ResearchEnrollmentProtocol.acknowledged(200,"install",mapOf("enrolledParticipantId" to "other")))
        assertFalse(ResearchEnrollmentProtocol.acknowledged(403,"install",mapOf("enrolledParticipantId" to "install")))
        assertFalse(ResearchEnrollmentProtocol.acknowledged(200,"install",null))
    }

    @Test fun `登记只使用同接收方 不跟随远端提供的地址`() {
        assertEquals("https://example.test/prefix/api/research/enroll",
            ResearchEnrollmentProtocol.endpoint("https://example.test/prefix/api/research/upload",false))
        assertEquals("http://10.0.2.2:8765/api/research/enroll",
            ResearchEnrollmentProtocol.endpoint("http://10.0.2.2:8765/api/research/upload",true))
        for (endpoint in listOf("http://10.0.2.2:8765/api/research/upload", "https://example.test/other", "https://user:pw@example.test/api/research/upload")) {
            assertThrows(IllegalArgumentException::class.java) { ResearchEnrollmentProtocol.endpoint(endpoint,false) }
        }
    }
}
