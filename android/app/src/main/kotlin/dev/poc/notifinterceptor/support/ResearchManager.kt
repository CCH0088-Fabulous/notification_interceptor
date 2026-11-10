package dev.poc.notifinterceptor.support

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.content.pm.ApplicationInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.SystemClock
import dev.poc.notifinterceptor.BuildConfig
import dev.poc.notifinterceptor.data.ResearchHttpSender
import dev.poc.notifinterceptor.data.ResearchSettings
import dev.poc.notifinterceptor.data.ResearchSettingsStore
import dev.poc.notifinterceptor.data.ResearchStore
import dev.poc.notifinterceptor.domain.CancelStatus
import dev.poc.notifinterceptor.domain.HistoryEntry
import dev.poc.notifinterceptor.domain.ResearchPolicy
import dev.poc.notifinterceptor.domain.ResearchEnrollmentProtocol
import dev.poc.notifinterceptor.domain.ResearchUploadProtocol
import dev.poc.notifinterceptor.domain.RuleSet
import java.time.Instant
import java.time.ZoneId
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.FutureTask
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock

/** Process-scoped, consent-gated telemetry. Failures never escape capture methods. */
class ResearchManager(private val context: Context) {
    private val settingsStore = ResearchSettingsStore(context)
    private val store = ResearchStore(context)
    private val sender = ResearchHttpSender()
    private val captureFailures = AtomicLong()
    private val writer = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(4096), { task -> Thread(task, "research-ledger").apply { isDaemon = true } })
    private val configurationLock = Any()
    private val clockLock = Any()
    private val uploadLock = ReentrantLock()
    private val debug = context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
    private val offlineOnly = !BuildConfig.RESEARCH_ONLINE_ENABLED
    private val defaultCohort = if (Build.FINGERPRINT.startsWith("generic") || Build.HARDWARE in setOf("ranchu", "goldfish")) "demo" else "pilot"
    private val pilotAvailable get() = !offlineOnly && BuildConfig.RESEARCH_PILOT_KEY.matches(Regex("[A-Za-z0-9_-]{43}")) &&
        runCatching { ResearchEnrollmentProtocol.endpoint(BuildConfig.RESEARCH_PILOT_ENDPOINT, debug) }.isSuccess
    @Volatile private var settingsError: String? = null
    @Volatile private var settings = runCatching { settingsStore.load(defaultCohort) }.getOrElse {
        settingsError = "研究设置无法读取；采集与发送已关闭。可退出并清除本机研究数据后重试。"
        ResearchSettings(cohort = defaultCohort)
    }
    private var foreground = false
    private var connected = false
    private var globalEnabled = false
    private var lastElapsed = 0L
    private var lastWall = 0L

    init {
        // A process killed after revocation must not leave its previous ledger visible.
        if (offlineOnly && (settings.autoUpload || settings.token.isNotEmpty() || settings.endpoint.isNotEmpty())) {
            settings = settings.copy(autoUpload = false, token = "", endpoint = "", pilotPending = false, pilotEnrolled = false)
            runCatching { settingsStore.save(settings) }
        }
        writer.execute { if (!settings.enabled && settings.participantId.isEmpty() && settingsError == null) runCatching { store.clear() } }
        // Persisted jobs survive a cold process start. Replacing one here could
        // cancel the JobService that is currently constructing this manager.
        if (!settings.enabled || !settings.autoUpload || settingsError != null) runCatching { schedule() }
    }

    @Suppress("DEPRECATION")
    private val appVersion: String get() = context.packageManager.getPackageInfo(context.packageName, 0).let { "${it.versionName}+${it.versionCode}" }

    fun status(): Map<String, Any?> = synchronized(configurationLock) {
        flush()
        val config = settings
        mapOf(
            "configuration" to config.publicMap(), "statistics" to store.status(System.currentTimeMillis(), if (config.acceptedDisclosureVersion < 2) 7 else 14),
            "captureFailures" to captureFailures.get(), "settingsError" to settingsError,
            "debugLoopbackAllowed" to debug,
            "offlineMode" to offlineOnly,
            "pilotAvailable" to pilotAvailable,
            "pilotEndpoint" to if (pilotAvailable) BuildConfig.RESEARCH_PILOT_ENDPOINT else "",
            "backgroundScheduled" to (context.getSystemService(JobScheduler::class.java).getPendingJob(JOB_ID) != null),
        )
    }

    fun configure(raw: Map<*, *>, currentRules: RuleSet): Map<String, Any?> = synchronized(configurationLock) {
        check(settingsError == null) { settingsError!! }
        val old = settings
        require((raw["expectedRevision"] as? Number)?.toLong() == old.revision) { "研究配置已变化，请刷新后重试" }
        fun flag(key: String, default: Boolean): Boolean = if (raw.containsKey(key)) raw[key] as? Boolean
            ?: throw IllegalArgumentException("研究开关格式错误") else default
        val enabled = flag("enabled", old.enabled)
        require(!enabled || old.endedAt == 0L) { "本轮已结束，请先分享并删除旧数据，再开始新一轮" }
        if (!enabled && old.participantId.isNotEmpty()) {
            require(raw["ruleStructures"] == false && !raw.containsKey("enabled")) { "请使用结束记录，或单独删除研究数据" }
            val next = old.copy(ruleStructures = false, revision = old.revision + 1)
            settingsStore.save(next)
            settings = next
            store.invalidateQueue(removeProfiles = true)
            return status()
        }
        require(enabled || old.participantId.isEmpty()) { "请使用结束记录，或单独删除研究数据" }
        val structures = enabled && flag("ruleStructures", old.ruleStructures)
        val automatic = !offlineOnly && enabled && flag("autoUpload", old.autoUpload)
        val endpoint = if (offlineOnly) "" else ResearchPolicy.endpoint((raw["endpoint"] as? String) ?: old.endpoint, debug)
        val cohort = (raw["cohort"] as? String) ?: old.cohort
        ResearchPolicy.cohort(cohort)
        val providedToken = raw["token"] as? String
        val token = if (!enabled || offlineOnly) "" else if (!providedToken.isNullOrBlank()) providedToken.trim()
            else if (endpoint == old.endpoint) old.token else ""
        require(token.length <= 4096 && token.all { it.code in 33..126 }) { "上传令牌需为不含空格的 ASCII 字符，最多 4096 字符" }
        if (enabled && !old.enabled) require(raw["disclosureAccepted"] == ResearchPolicy.DISCLOSURE_VERSION) { "请先阅读并确认参与使用研究" }
        if (structures && !old.ruleStructures) require(raw["ruleDisclosureAccepted"] == ResearchPolicy.DISCLOSURE_VERSION) { "请单独确认规则结构统计" }
        if (automatic && (!old.autoUpload || endpoint != old.endpoint)) {
            require(raw["uploadDisclosureAccepted"] == ResearchPolicy.DISCLOSURE_VERSION) { "请确认后台自动上传及接收地址" }
        }
        val sameCredential = enabled && endpoint == old.endpoint && token == old.token
        val pending = sameCredential && old.pilotPending
        require(!automatic || (endpoint.isNotEmpty() && token.isNotEmpty() && !pending)) { "请先完成内测设备连接或保存有效上传配置" }
        val next = ResearchSettings(
            enabled, structures, automatic, flag("wifiOnly", old.wifiOnly), cohort, endpoint, token,
            if (enabled) old.participantId.ifEmpty { UUID.randomUUID().toString() } else "",
            if (enabled) old.consentAt.takeIf { it > 0 } ?: System.currentTimeMillis() else 0,
            old.revision + 1,
            pilotPending = pending,
            pilotEnrolled = sameCredential && old.pilotEnrolled,
            endedAt = old.endedAt,
            acceptedDisclosureVersion = if (enabled && !old.enabled) ResearchPolicy.DISCLOSURE_VERSION else old.acceptedDisclosureVersion,
        )
        // Persist before publishing. A failure keeps the previous consent authoritative.
        settingsStore.save(next)
        settings = next
        sender.cancel()
        flush()
        if (!enabled) store.clear() else store.invalidateQueue(removeProfiles = !structures)
        synchronized(clockLock) { lastElapsed = SystemClock.elapsedRealtime(); lastWall = System.currentTimeMillis() }
        if (structures) store.setProfiles(ResearchPolicy.ruleStructures(currentRules), System.currentTimeMillis())
        runCatching { schedule() }.onFailure { store.failure(null, "系统后台任务暂未登记，请重新保存或手动同步") }
        status()
    }

    fun clear(): Map<String, Any?> = synchronized(configurationLock) {
        val next = ResearchSettings(cohort = defaultCohort, revision = settings.revision + 1)
        // Immediate in-memory gate also covers corrupt/undecryptable old settings.
        settings = next
        sender.cancel()
        context.getSystemService(JobScheduler::class.java).cancel(JOB_ID)
        flush()
        store.clear()
        java.io.File(context.cacheDir, "research-shares").listFiles()?.filter { it.isFile }?.forEach { it.delete() }
        settingsStore.delete()
        settingsStore.save(next)
        settingsError = null
        status()
    }

    fun end(expectedRevision: Long): Map<String, Any?> = synchronized(configurationLock) {
        check(settingsError == null && settings.enabled) { "当前没有正在记录的内测" }
        require(settings.revision == expectedRevision) { "研究设置已变化，请刷新后重试" }
        checkpoint(); flush()
        val next = settings.copy(enabled = false, autoUpload = false, token = "", endpoint = "",
            pilotPending = false, pilotEnrolled = false, endedAt = System.currentTimeMillis(), revision = settings.revision + 1)
        settingsStore.save(next)
        settings = next
        sender.cancel()
        store.invalidateQueue(removeProfiles = false)
        schedule()
        status()
    }

    fun prepareArchive(): java.io.File = synchronized(configurationLock) {
        check(settingsError == null && settings.participantId.isNotEmpty()) { "请先开始参与内测" }
        checkpoint(); flush()
        val file = dev.poc.notifinterceptor.data.ResearchArchive.create(context, settings, appVersion, Build.VERSION.SDK_INT,
            captureFailures.get()) { output, metadata -> store.writeArchive(output, metadata, System.currentTimeMillis()) }
        store.markArchivePrepared(System.currentTimeMillis())
        file
    }

    fun action(action: String) {
        require(action in ResearchPolicy.actions) { "研究操作不在白名单中" }
        count(mapOf("action_$action" to 1L))
    }

    fun count(values: Map<String, Long>) {
        val config = settings
        if (!config.enabled || settingsError != null) return
        val now = System.currentTimeMillis()
        val safe = ResearchPolicy.validateMetrics(values)
        val zone = ZoneId.systemDefault()
        val bucket = Math.floorDiv(now, ResearchPolicy.HOUR_MS) * ResearchPolicy.HOUR_MS
        val offset = zone.rules.getOffset(Instant.ofEpochMilli(now)).totalSeconds / 60
        capture(config) { store.record(UUID.randomUUID().toString(), now, bucket, offset, config.cohort, safe) }
    }

    fun observed(entry: HistoryEntry, existing: Boolean) {
        val config = settings
        if (!config.enabled || entry.timestamp < config.consentAt) return
        // Extract whitelisted primitives now; no notification text/key/package is queued.
        val metrics = ResearchPolicy.observed(entry, existing)
        val cohort = ResearchPolicy.cohort(config.cohort, entry.snapshot.packageName)
        val id = "notification:${entry.id}"
        val at = entry.timestamp
        val bucket = Math.floorDiv(at, ResearchPolicy.HOUR_MS) * ResearchPolicy.HOUR_MS
        val offset = ZoneId.systemDefault().rules.getOffset(Instant.ofEpochMilli(at)).totalSeconds / 60
        capture(config) { store.record(id, at, bucket, offset, cohort, metrics, existing) }
    }

    fun resolved(entry: HistoryEntry, status: CancelStatus) {
        val config = settings
        if (!config.enabled || entry.timestamp < config.consentAt || entry.snapshot.isGroupSummary) return
        val id = entry.id
        capture(config) {
            val observed = store.observation("notification:$id") ?: return@capture
            val prefix = if (observed.existing) "existing_" else ""
            store.record("resolved:$id", System.currentTimeMillis(), observed.bucket, observed.offset,
                observed.cohort, mapOf(prefix + ResearchPolicy.outcome(status) to 1L))
        }
    }

    fun rulesChanged(before: RuleSet, after: RuleSet) {
        count(ResearchPolicy.rulesChanged(before, after))
        setGlobalEnabled(after.globalEnabled)
        val config = settings
        if (config.enabled && config.ruleStructures) {
            val sanitized = ResearchPolicy.ruleStructures(after)
            capture(config) { store.setProfiles(sanitized, System.currentTimeMillis()) }
        }
    }

    fun setForeground(value: Boolean) = synchronized(clockLock) {
        checkpoint()
        if (value && !foreground) count(mapOf("foreground_sessions" to 1L))
        foreground = value
    }

    fun setConnected(value: Boolean) = synchronized(clockLock) {
        checkpoint()
        if (connected != value) count(mapOf((if (value) "listener_connections" else "listener_disconnects") to 1L))
        connected = value
    }

    fun setGlobalEnabled(value: Boolean) = synchronized(clockLock) { checkpoint(); globalEnabled = value }

    /** Handler checkpoints don't wake a sleeping phone. Late intervals become gaps. */
    fun checkpoint() = synchronized(clockLock) {
        val now = System.currentTimeMillis()
        val elapsed = SystemClock.elapsedRealtime()
        val delta = elapsed - lastElapsed
        val wallDelta = now - lastWall
        val config = settings
        if (lastElapsed != 0L && delta > 0 && config.enabled) {
            if (delta > ResearchPolicy.MAX_CONFIRMED_INTERVAL_MS || kotlin.math.abs(wallDelta - delta) > 5_000) {
                count(mapOf("observation_gap_ms" to delta.coerceAtMost(7 * ResearchPolicy.DAY_MS)))
            } else {
                val active = buildMap<String, Long> {
                    if (foreground) put("foreground_ms", 1)
                    if (globalEnabled) put("engine_enabled_observed_ms", 1)
                    if (connected) put("listener_connected_observed_ms", 1)
                }
                if (active.isNotEmpty()) {
                    ResearchPolicy.durationSlices(now, delta, ZoneId.systemDefault()).forEach { (bucket, segment) ->
                        val values = active.mapValues { segment.second }
                        capture(config) { store.record(UUID.randomUUID().toString(), now, bucket, segment.first, config.cohort, values) }
                    }
                }
            }
        }
        lastWall = now; lastElapsed = elapsed
    }

    fun preview(): Map<String, Any?>? = synchronized(configurationLock) {
        check(settings.enabled && settingsError == null) { "请先参与使用研究" }
        checkpoint(); flush()
        store.prepare(settings, appVersion, Build.VERSION.SDK_INT, System.currentTimeMillis())
    }

    fun sync(manual: Boolean, disclosureAccepted: Int = 0): Map<String, Any?> {
        check(!offlineOnly) { "本安装包使用离线文件回收，不进行联网发送" }
        if (!uploadLock.tryLock()) return result("已有发送任务，请稍后查看状态", false)
        var batchId: String? = null
        var generation = -1L
        try {
            val config = settings
            generation = config.revision
            check(config.enabled && settingsError == null) { "请先参与使用研究" }
            check(if (manual) disclosureAccepted == ResearchPolicy.DISCLOSURE_VERSION else config.autoUpload) { "未同意本次发送" }
            check(config.endpoint.isNotEmpty() && config.token.isNotEmpty() && !config.pilotPending) { "请先完成设备连接或保存接收配置" }
            ResearchPolicy.endpoint(config.endpoint, debug)
            if (!networkAllowed(config.wifiOnly)) {
                store.failure(null, if (config.wifiOnly) "等待不计费网络（通常为 Wi-Fi）" else "等待网络连接")
                return result("网络条件尚未满足，数据仍在本机", true)
            }
            val payload = preview() ?: return result("没有待发送的统计", false)
            // Scope/destination can change between snapshot preparation and transport.
            check(settings.enabled && settings.revision == generation && !Thread.currentThread().isInterrupted) { "配置已变化，发送已取消" }
            batchId = payload["batchId"] as String
            val reply = sender.send(config.endpoint, config.token, payload) {
                settings.enabled && settings.revision == generation && !Thread.currentThread().isInterrupted
            }
            synchronized(configurationLock) {
                if (!settings.enabled || settings.revision != generation) return result("配置已变化，旧任务不再确认或重试", false)
                if (ResearchUploadProtocol.acknowledged(reply.code, batchId, reply.body)) {
                    store.acknowledge(payload, System.currentTimeMillis())
                    return result("接收端已确认保存批次", false, true)
                }
                val message = if (reply.code in 200..299) "接收端缺少匹配的批次确认，保留待发数据" else "接收端返回 HTTP ${reply.code}，保留待发数据"
                store.failure(batchId, message)
                return result(message, ResearchUploadProtocol.retryable(reply.code))
            }
        } catch (_: Exception) {
            val message = if (!settings.enabled || (generation >= 0 && settings.revision != generation)) "发送已停止" else "发送未完成，请检查接收配置、网络和证书；待发数据保留"
            if (settings.enabled && settings.revision == generation) runCatching { store.failure(batchId, message) }
            return result(message, settings.enabled && settings.revision == generation)
        } finally { uploadLock.unlock() }
    }

    fun cancelUpload() { sender.cancel() }

    fun enroll(expectedRevision: Long): Map<String, Any?> {
        check(uploadLock.tryLock()) { "已有连接或发送任务，请稍后重试" }
        var generation = -1L
        try {
            val config = synchronized(configurationLock) {
                val old = settings
                check(old.enabled && settingsError == null) { "请先同意参与使用研究" }
                check(old.revision == expectedRevision) { "配置已变化，请刷新后重试" }
                check(pilotAvailable) { "此安装包未配置内测接收方" }
                if (old.pilotEnrolled) return status()
                if (old.pilotPending && old.endpoint != BuildConfig.RESEARCH_PILOT_ENDPOINT) {
                    store.failure(null, "内测接收方已变更，请退出研究并重新加入以确认新接收方")
                    return status()
                }
                check(old.token.isEmpty() || old.pilotPending) { "已有手动上传配置，请继续使用该配置" }
                checkpoint(); flush()
                val next = old.copy(endpoint = BuildConfig.RESEARCH_PILOT_ENDPOINT,
                    token = old.token.ifEmpty { ResearchEnrollmentProtocol.newCredential() },
                    pilotPending = true, pilotEnrolled = false, revision = old.revision + 1)
                settingsStore.save(next)
                settings = next
                sender.cancel()
                store.invalidateQueue(removeProfiles = !next.ruleStructures)
                next
            }
            generation = config.revision
            if (!networkAllowed(false)) {
                store.failure(null, "等待网络以连接内测设备，无需填写账号或令牌")
                return status()
            }
            val reply = sender.send(ResearchEnrollmentProtocol.endpoint(config.endpoint, debug), config.token,
                mapOf("schemaVersion" to 1, "participantId" to config.participantId,
                    "consentVersion" to ResearchPolicy.DISCLOSURE_VERSION), BuildConfig.RESEARCH_PILOT_KEY) {
                settings.enabled && settings.revision == generation && !Thread.currentThread().isInterrupted
            }
            synchronized(configurationLock) {
                if (!settings.enabled || settings.revision != generation) return status()
                if (ResearchEnrollmentProtocol.acknowledged(reply.code, config.participantId, reply.body)) {
                    checkpoint(); flush()
                    val next = settings.copy(pilotPending = false, pilotEnrolled = true, revision = settings.revision + 1)
                    settingsStore.save(next)
                    settings = next
                    store.invalidateQueue(removeProfiles = !next.ruleStructures)
                    store.failure(null, "内测设备已连接，上传权限独立保存")
                } else {
                    store.failure(null, when (reply.code) {
                        401 -> "内测安装包配置不匹配，请联系研究方"
                        403 -> "新设备登记已关闭，或本安装权限已撤销，请联系研究方"
                        409 -> "内测名额已满或编号冲突，请联系研究方"
                        else -> "设备连接尚未确认，请稍后重试；编号与凭证已安全保留"
                    })
                }
            }
            return status()
        } catch (_: Exception) {
            synchronized(configurationLock) {
                if (settings.enabled && generation == settings.revision) {
                    store.failure(null, "设备连接未完成，请稍后重试；无需重新填写配置")
                }
            }
            return status()
        } finally { uploadLock.unlock() }
    }

    private fun result(message: String, retry: Boolean, sent: Boolean = false): Map<String, Any?> = mapOf("message" to message, "retry" to retry, "sent" to sent)

    private fun networkAllowed(wifiOnly: Boolean): Boolean {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val capabilities = manager.getNetworkCapabilities(manager.activeNetwork) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            (!wifiOnly || capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED))
    }

    private fun capture(config: ResearchSettings, work: () -> Unit) {
        if (!config.enabled || settingsError != null) return
        try {
            writer.execute {
                if (!settings.enabled || settings.revision != config.revision || settingsError != null) return@execute
                runCatching(work).onFailure { captureFailures.incrementAndGet() }
            }
        } catch (_: RejectedExecutionException) { captureFailures.incrementAndGet() }
    }

    private fun flush() {
        val fence = FutureTask { Unit }
        check(writer.queue.offer(fence, 5, TimeUnit.SECONDS)) { "研究写入队列繁忙，请稍后重试" }
        fence.get(10, TimeUnit.SECONDS)
    }

    fun ensureBackgroundScheduled() { runCatching { schedule(replace = false) } }

    private fun schedule(replace: Boolean = true) {
        val scheduler = context.getSystemService(JobScheduler::class.java)
        val config = settings
        if (offlineOnly || !config.enabled || !config.autoUpload || settingsError != null) { scheduler.cancel(JOB_ID); return }
        if (!replace && scheduler.getPendingJob(JOB_ID) != null) return
        scheduler.cancel(JOB_ID)
        val job = JobInfo.Builder(JOB_ID, ComponentName(context, ResearchUploadJobService::class.java))
            .setPersisted(true).setPeriodic(4 * ResearchPolicy.HOUR_MS)
            .setRequiredNetworkType(if (config.wifiOnly) JobInfo.NETWORK_TYPE_UNMETERED else JobInfo.NETWORK_TYPE_ANY)
            .setRequiresBatteryNotLow(true).setBackoffCriteria(30_000, JobInfo.BACKOFF_POLICY_EXPONENTIAL).build()
        check(scheduler.schedule(job) == JobScheduler.RESULT_SUCCESS) { "无法登记后台发送任务" }
    }

    companion object { const val JOB_ID = 0x524553 }
}
