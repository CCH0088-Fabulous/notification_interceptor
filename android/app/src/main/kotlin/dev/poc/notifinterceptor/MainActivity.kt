package dev.poc.notifinterceptor

import android.os.Bundle
import dev.poc.notifinterceptor.bridge.InterceptorBridge
import dev.poc.notifinterceptor.support.NotificationAccess
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private var bridge: InterceptorBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 进程被强杀后系统不会自动重新绑定监听服务，打开界面时补一次请求。
        NotificationAccess.rebindIfGranted(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = InterceptorBridge(
            context = applicationContext,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        ).also { it.register() }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        bridge?.dispose()
        bridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
