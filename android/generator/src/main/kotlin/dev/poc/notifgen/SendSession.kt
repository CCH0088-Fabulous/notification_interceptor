package dev.poc.notifgen

enum class SendMode { SINGLE, BATCH, CONTINUOUS }

/** One press of Send takes a snapshot shared by every notification in that run. */
class SendConfiguration(
    val mode: SendMode,
    val count: Int = 10,
    val intervalMs: Long = 2_500L,
    categoryIds: Set<String>,
    val loud: Boolean = false,
    val realistic: Boolean = false,
    val headsUp: Boolean = false,
) {
    val categoryIds: Set<String> = categoryIds.toSet()
    val targetCount: Int? = when (mode) {
        SendMode.SINGLE -> 1
        SendMode.BATCH -> count
        SendMode.CONTINUOUS -> null
    }

    init {
        require(this.categoryIds.isNotEmpty()) { "至少选择一类通知后才能发送。" }
        require(mode != SendMode.BATCH || count in 1..100) { "发送数量请输入 1 至 100 的整数。" }
        require(mode == SendMode.SINGLE || intervalMs > 0) { "发送间隔必须大于零。" }
    }
}

data class SendRun(val id: Long, val configuration: SendConfiguration)

/** Pure scheduling state. A stale Runnable can never continue a stopped or replaced run. */
class SendSession {
    private var nextId = 0L
    var activeRun: SendRun? = null
        private set
    var sentCount: Int = 0
        private set

    val isRunning: Boolean get() = activeRun != null
    val remainingCount: Int? get() = activeRun?.configuration?.targetCount?.minus(sentCount)

    fun start(configuration: SendConfiguration): SendRun {
        val run = SendRun(++nextId, configuration)
        activeRun = run
        sentCount = 0
        return run
    }

    fun isActive(run: SendRun): Boolean = activeRun?.id == run.id

    /** Returns true only when this run still needs a next notification. */
    fun recordSent(run: SendRun): Boolean {
        if (!isActive(run)) return false
        sentCount++
        if (run.configuration.targetCount?.let { sentCount >= it } == true) {
            activeRun = null
            return false
        }
        return true
    }

    fun stop() {
        activeRun = null
    }
}
