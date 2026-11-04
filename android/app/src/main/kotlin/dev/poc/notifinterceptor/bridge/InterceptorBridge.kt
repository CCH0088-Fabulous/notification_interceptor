package dev.poc.notifinterceptor.bridge

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import dev.poc.notifinterceptor.domain.NotificationSnapshot
import dev.poc.notifinterceptor.domain.RuleAction
import dev.poc.notifinterceptor.domain.RuleSet
import dev.poc.notifinterceptor.domain.RuleSetComparison
import dev.poc.notifinterceptor.listener.NotificationInterceptorService
import dev.poc.notifinterceptor.listener.NotificationSnapshotFactory
import dev.poc.notifinterceptor.support.AppGraph
import dev.poc.notifinterceptor.support.NotificationAccess
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Dart ↔ Kotlin 唯一入口。只做参数校验、编排与异常翻译，不含业务判定。
 */
class InterceptorBridge(
    context: Context,
    messenger: BinaryMessenger,
    activity: Activity? = null,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val appContext = context.applicationContext
    private val graph = AppGraph.ensure(appContext)
    private val snapshotFactory = NotificationSnapshotFactory(appContext, graph.appInfo)

    private val methodChannel = MethodChannel(messenger, CHANNEL_NAME)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL_NAME)
    private val documents = activity?.let(::PresetDocumentPicker)
    private val comparison = RuleSetComparison(graph.ruleEngine)
    private val comparisonExecutor = Executors.newSingleThreadExecutor { work ->
        Thread(work, "notif-rule-comparison").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())
    private var comparisonResult: MethodChannel.Result? = null
    private var disposed = false

    fun register() {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    fun dispose() {
        disposed = true
        comparisonResult?.error(ERROR_COMPARISON, "页面已关闭，批量对比已取消", null)
        comparisonResult = null
        comparisonExecutor.shutdownNow()
        documents?.dispose()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        EventDispatcher.attach(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == METHOD_COMPARE_RULE_SETS) {
            compareRuleSets(call, result)
            return
        }
        if (call.method == METHOD_IMPORT_PRESET_FILE || call.method == METHOD_EXPORT_PRESET_FILE ||
            call.method == METHOD_EXPORT_COMPARISON_FILE) {
            runCatching {
                val picker = documents ?: throw IllegalStateException("当前页面不能打开文件选择器")
                if (call.method == METHOD_IMPORT_PRESET_FILE) {
                    picker.importFile(result)
                } else {
                    val content = call.argument<String>("content")
                        ?: throw IllegalArgumentException("缺少导出内容")
                    picker.exportFile(content, call.argument<String>("fileName"), result,
                        maxBytes = if (call.method == METHOD_EXPORT_COMPARISON_FILE) {
                            MAX_COMPARISON_BYTES
                        } else {
                            dev.poc.notifinterceptor.data.PresetTransferContent.MAX_BYTES
                        })
                }
            }.onFailure { result.error(ERROR_INTERNAL, it.message ?: "无法打开文件选择器", null) }
            return
        }
        runCatching { dispatch(call) }
            .onSuccess { result.success(it) }
            .onFailure { error ->
                result.error(
                    ERROR_INTERNAL,
                    error.message ?: error::class.java.simpleName,
                    null,
                )
            }
    }

    private fun dispatch(call: MethodCall): Any? = when (call.method) {
        METHOD_GET_STATUS -> getStatus()
        METHOD_OPEN_ACCESS_SETTINGS -> openAccessSettings()
        METHOD_REQUEST_REBIND -> requestRebind()
        METHOD_GET_RULES -> mapOf("ruleSet" to graph.rules.load().toMap())
        METHOD_SAVE_RULES -> saveRules(call)
        METHOD_GET_PRESETS -> graph.presets.load()
        METHOD_SAVE_PRESETS -> savePresets(call)
        METHOD_SAVE_PRESET_VERSION -> savePresetVersion(call)
        METHOD_EVALUATE_SAMPLE -> evaluateSample(call)
        METHOD_GET_HISTORY -> getHistory(call)
        METHOD_CLEAR_HISTORY -> clearHistory()
        METHOD_GET_STATS -> graph.history.stats()
        METHOD_GET_ACTIVE_NOTIFICATIONS -> activeNotifications()
        METHOD_CANCEL -> cancel(call)
        METHOD_GET_SEEN_PACKAGES -> graph.history.seenPackages()
        METHOD_EXPORT_HISTORY -> graph.history.exportJson()
        else -> throw IllegalArgumentException("未知方法: ${call.method}")
    }

    private fun getStatus(): Map<String, Any?> {
        val ruleSet = graph.rules.load()
        return mapOf(
            "granted" to NotificationAccess.isGranted(appContext),
            "connected" to graph.serviceConnected,
            "sdkInt" to Build.VERSION.SDK_INT,
            "ownPackage" to appContext.packageName,
            "historyCount" to graph.history.count(),
            "ruleCount" to ruleSet.rules.size,
            "globalEnabled" to ruleSet.globalEnabled,
            "issues" to graph.ruleEngine.validate(ruleSet).map { it.toMap() },
            "serviceComponent" to ComponentName(
                appContext,
                NotificationInterceptorService::class.java,
            ).flattenToString(),
        )
    }

    private fun openAccessSettings(): Boolean {
        appContext.startActivity(NotificationAccess.settingsIntent())
        return true
    }

    private fun requestRebind(): Map<String, Any?> {
        NotificationListenerServiceCompat.requestRebind(appContext)
        return mapOf(
            "granted" to NotificationAccess.isGranted(appContext),
            "connected" to graph.serviceConnected,
        )
    }

    private fun saveRules(call: MethodCall): Map<String, Any?> {
        val raw = call.argument<Any?>("ruleSet") as? Map<*, *>
            ?: throw IllegalArgumentException("缺少 ruleSet")
        val ruleSet = RuleSet.fromMap(raw)
        val saved = graph.rules.save(ruleSet)
        return mapOf(
            "ruleSet" to saved.toMap(),
            "issues" to graph.rules.validate(saved).map { it.toMap() },
        )
    }

    private fun savePresets(call: MethodCall): Map<String, Any?> {
        val library = call.argument<Any?>("library") as? Map<*, *>
            ?: throw IllegalArgumentException("缺少 library")
        return graph.presets.save(library)
    }

    private fun savePresetVersion(call: MethodCall): Map<String, Any?> {
        val id = call.argument<String>("presetId")
            ?: throw IllegalArgumentException("缺少 presetId")
        return graph.presets.saveVersion(id, call.argument<String>("label"))
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean =
        documents?.onActivityResult(requestCode, resultCode, data) ?: false

    private fun evaluateSample(call: MethodCall): Map<String, Any?> {
        val sample = call.argument<Any?>("sample") as? Map<*, *>
            ?: throw IllegalArgumentException("缺少 sample")
        val ruleSet = (call.argument<Any?>("ruleSet") as? Map<*, *>)
            ?.let { RuleSet.fromMap(it) }
            ?: graph.rules.load()
        val snapshot = NotificationSnapshot.fromMap(sample)
        val decision = graph.ruleEngine.evaluate(ruleSet, snapshot)
        return decision.toMap()
    }

    /** Comparison never enters the live notification executor or repositories. */
    private fun compareRuleSets(call: MethodCall, result: MethodChannel.Result) {
        if (disposed || comparisonResult != null) {
            result.error(ERROR_COMPARISON, "请等待当前批量对比完成后重试", null)
            return
        }
        comparisonResult = result
        comparisonExecutor.execute {
            val response = runCatching {
                val base = call.argument<Any?>("baseRuleSet") as? Map<*, *>
                    ?: throw IllegalArgumentException("缺少当前规则")
                val candidate = call.argument<Any?>("candidateRuleSet") as? Map<*, *>
                    ?: throw IllegalArgumentException("缺少候选规则")
                val samples = call.argument<Any?>("samples") as? List<*>
                    ?: throw IllegalArgumentException("缺少批量样本")
                comparison.compare(base, candidate, samples)
            }
            main.post {
                if (disposed || comparisonResult !== result) return@post
                comparisonResult = null
                response.onSuccess { result.success(it) }.onFailure {
                    result.error(ERROR_COMPARISON, it.message ?: "批量对比失败，请重试", null)
                }
            }
        }
    }

    private fun getHistory(call: MethodCall): List<Map<String, Any?>> {
        val action = (call.argument<String>("action"))
            ?.takeIf { it.isNotBlank() }
            ?.let { RuleAction.fromWire(it) }
        val entries = graph.history.query(
            limit = call.argument<Int>("limit") ?: 100,
            offset = call.argument<Int>("offset") ?: 0,
            packageName = call.argument<String>("packageName"),
            action = action,
            sinceMillis = call.argument<Long>("since"),
        )
        return entries.map { it.toMap() }
    }

    private fun clearHistory(): Boolean {
        graph.history.clear()
        return true
    }

    private fun activeNotifications(): List<Map<String, Any?>> {
        val service = graph.listener ?: return emptyList()
        return runCatching { service.activeNotifications }
            .getOrNull()
            ?.mapNotNull { sbn ->
                runCatching { snapshotFactory.create(sbn).toMap() }.getOrNull()
            }
            ?: emptyList()
    }

    private fun cancel(call: MethodCall): Map<String, Any?> {
        val key = call.argument<String>("key")
            ?: throw IllegalArgumentException("缺少 key")
        val service = graph.listener
            ?: return mapOf("cancelled" to false, "errorCode" to ERROR_SERVICE_NOT_CONNECTED)
        return mapOf("cancelled" to service.cancelByKey(key))
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        EventDispatcher.attach(events)
        // 订阅即推送一次状态，避免 UI 打开时状态为未知。
        EventDispatcher.post(
            mapOf(
                "type" to NotificationInterceptorService.EVENT_STATUS,
                "connected" to graph.serviceConnected,
                "granted" to NotificationAccess.isGranted(appContext),
            ),
        )
    }

    override fun onCancel(arguments: Any?) {
        EventDispatcher.attach(null)
    }

    /** 兼容层：requestRebind 只在 API 24+ 存在，minSdk 26 已满足，保留集中入口便于替换。 */
    private object NotificationListenerServiceCompat {
        fun requestRebind(context: Context) {
            runCatching {
                NotificationListenerService.requestRebind(
                    ComponentName(context, NotificationInterceptorService::class.java),
                )
            }
        }
    }

    companion object {
        const val CHANNEL_NAME = "dev.poc.notifinterceptor/bridge"
        const val EVENT_CHANNEL_NAME = "dev.poc.notifinterceptor/events"

        const val METHOD_GET_STATUS = "getStatus"
        const val METHOD_OPEN_ACCESS_SETTINGS = "openAccessSettings"
        const val METHOD_REQUEST_REBIND = "requestRebind"
        const val METHOD_GET_RULES = "getRules"
        const val METHOD_SAVE_RULES = "saveRules"
        const val METHOD_GET_PRESETS = "getPresets"
        const val METHOD_SAVE_PRESETS = "savePresets"
        const val METHOD_SAVE_PRESET_VERSION = "savePresetVersion"
        const val METHOD_IMPORT_PRESET_FILE = "importPresetFile"
        const val METHOD_EXPORT_PRESET_FILE = "exportPresetFile"
        const val METHOD_EXPORT_COMPARISON_FILE = "exportComparisonFile"
        const val METHOD_EVALUATE_SAMPLE = "evaluateSample"
        const val METHOD_COMPARE_RULE_SETS = "compareRuleSets"
        const val METHOD_GET_HISTORY = "getHistory"
        const val METHOD_CLEAR_HISTORY = "clearHistory"
        const val METHOD_GET_STATS = "getStats"
        const val METHOD_GET_ACTIVE_NOTIFICATIONS = "getActiveNotifications"
        const val METHOD_CANCEL = "cancel"
        const val METHOD_GET_SEEN_PACKAGES = "getSeenPackages"
        const val METHOD_EXPORT_HISTORY = "exportHistory"

        const val ERROR_INTERNAL = "INTERNAL"
        const val ERROR_SERVICE_NOT_CONNECTED = "SERVICE_NOT_CONNECTED"
        private const val ERROR_COMPARISON = "RULE_COMPARISON"
        private const val MAX_COMPARISON_BYTES = 8 * 1024 * 1024
    }
}
