package dev.poc.notifinterceptor.bridge

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * EventChannel 的 sink 只能在主线程调用；所有事件统一经此处切换线程。
 * 界面销毁后 sink 为 null，事件静默丢弃（历史仍在原生侧累积）。
 */
object EventDispatcher {

    private val handler = Handler(Looper.getMainLooper())

    @Volatile
    private var sink: EventChannel.EventSink? = null

    fun attach(newSink: EventChannel.EventSink?) {
        sink = newSink
    }

    fun post(event: Map<String, Any?>) {
        handler.post {
            runCatching { sink?.success(event) }
        }
    }
}
