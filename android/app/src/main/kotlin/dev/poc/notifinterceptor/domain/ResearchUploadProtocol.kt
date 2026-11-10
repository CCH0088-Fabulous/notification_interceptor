package dev.poc.notifinterceptor.domain

/** Immutable, idempotent upload contract. A transport success alone is not an ACK. */
object ResearchUploadProtocol {
    const val MAX_BYTES = 512 * 1024
    const val MAX_RESPONSE_BYTES = 16 * 1024
    const val KIND = "notification_research_batch"
    fun acknowledged(status: Int, batchId: String, response: Map<String, Any?>?): Boolean =
        status in 200..299 && response?.get("acceptedBatchId") == batchId

    fun retryable(status: Int): Boolean = status == 408 || status == 429 || status in 500..599
}
