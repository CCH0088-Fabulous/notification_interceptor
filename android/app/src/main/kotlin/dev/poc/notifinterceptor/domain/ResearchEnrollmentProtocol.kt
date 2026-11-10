package dev.poc.notifinterceptor.domain

import java.security.SecureRandom
import java.util.Base64

/** A random per-install credential is persisted before enrollment and safely retried. */
object ResearchEnrollmentProtocol {
    fun newCredential(): String = Base64.getUrlEncoder().withoutPadding()
        .encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) })

    fun endpoint(upload: String, debug: Boolean): String {
        val checked = ResearchPolicy.endpoint(upload, debug)
        require(checked.endsWith("/api/research/upload")) { "内测接收地址需以 /api/research/upload 结尾" }
        return checked.removeSuffix("/upload") + "/enroll"
    }

    fun acknowledged(status: Int, participant: String, body: Map<String, Any?>?): Boolean =
        status in 200..299 && body?.get("enrolledParticipantId") == participant
}
