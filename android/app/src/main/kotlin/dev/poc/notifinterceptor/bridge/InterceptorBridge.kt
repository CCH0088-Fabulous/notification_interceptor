package dev.poc.notifinterceptor.bridge

import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.service.notification.NotificationListenerService
import dev.poc.notifinterceptor.domain.NotificationSnapshot
import dev.poc.notifinterceptor.domain.RuleAction
import dev.poc.notifinterceptor.domain.RuleSet
import dev.poc.notifinterceptor.listener.NotificationInterceptorService
import dev.poc.notifinterceptor.listener.NotificationSnapshotFactory
import dev.poc.notifinterceptor.support.AppGraph
import dev.poc.notifinterceptor.support.NotificationAccess
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Dart ↔ Kotlin 唯一入口。只做参数校验、编排与异常翻译，不含业务判定。
 */
class InterceptorBridge(
    context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val appContext = context.applicationContext
    private val graph = AppGraph.ensure(appContext)
    private val snapshotFactory = NotificationSnapshotFactory(appContext, graph.appInfo)

    private val methodChannel = MethodChannel(messenger, CHANNEL_NAME)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL_NAME)

    fun register() {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    fun dispose() {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        EventDispatcher.attach(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
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
        const val METHOD_EVALUATE_SAMPLE = "evaluateSample"
        const val METHOD_GET_HISTORY = "getHistory"
        const val METHOD_CLEAR_HISTORY = "clearHistory"
        const val METHOD_GET_STATS = "getStats"
        const val METHOD_GET_ACTIVE_NOTIFICATIONS = "getActiveNotifications"
        const val METHOD_CANCEL = "cancel"
        const val METHOD_GET_SEEN_PACKAGES = "getSeenPackages"
        const val METHOD_EXPORT_HISTORY = "exportHistory"

        const val ERROR_INTERNAL = "INTERNAL"
        const val ERROR_SERVICE_NOT_CONNECTED = "SERVICE_NOT_CONNECTED"
    }
}
