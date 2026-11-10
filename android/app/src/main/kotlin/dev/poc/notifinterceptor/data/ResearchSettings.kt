package dev.poc.notifinterceptor.data

import dev.poc.notifinterceptor.domain.ResearchPolicy

data class ResearchSettings(
    val enabled: Boolean = false,
    val ruleStructures: Boolean = false,
    val autoUpload: Boolean = false,
    val wifiOnly: Boolean = true,
    val cohort: String = "pilot",
    val endpoint: String = "",
    val token: String = "",
    val participantId: String = "",
    val consentAt: Long = 0,
    val revision: Long = 0,
    val pilotPending: Boolean = false,
    val pilotEnrolled: Boolean = false,
    val endedAt: Long = 0,
    val acceptedDisclosureVersion: Int = 0,
) {
    fun publicMap(): Map<String, Any> = mapOf(
        "enabled" to enabled, "ruleStructures" to ruleStructures, "autoUpload" to autoUpload,
        "wifiOnly" to wifiOnly, "cohort" to cohort, "endpoint" to endpoint,
        "hasToken" to (token.isNotEmpty() && !pilotPending), "participantId" to participantId,
        "pilotPending" to pilotPending, "pilotEnrolled" to pilotEnrolled,
        "consentAt" to consentAt, "revision" to revision,
        "disclosureVersion" to ResearchPolicy.DISCLOSURE_VERSION,
        "endedAt" to endedAt, "acceptedDisclosureVersion" to acceptedDisclosureVersion,
    )
}
