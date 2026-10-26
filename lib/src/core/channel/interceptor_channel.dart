import 'package:flutter/services.dart';

import '../error/interceptor_exception.dart';
import '../util/json_cast.dart';

/// 通道名与方法名的唯一来源，业务代码禁止出现裸字符串（structure.md P4）。
abstract final class BridgeChannel {
  static const String method = 'dev.poc.notifinterceptor/bridge';
  static const String events = 'dev.poc.notifinterceptor/events';
}

/// 与 Kotlin 侧 `InterceptorBridge` 对应的方法名。
abstract final class BridgeMethod {
  static const String getStatus = 'getStatus';
  static const String openAccessSettings = 'openAccessSettings';
  static const String requestRebind = 'requestRebind';
  static const String getRules = 'getRules';
  static const String saveRules = 'saveRules';
  static const String evaluateSample = 'evaluateSample';
  static const String getHistory = 'getHistory';
  static const String clearHistory = 'clearHistory';
  static const String getStats = 'getStats';
  static const String getActiveNotifications = 'getActiveNotifications';
  static const String cancel = 'cancel';
  static const String getSeenPackages = 'getSeenPackages';
  static const String exportHistory = 'exportHistory';
}

/// 事件类型（与 Kotlin `NotificationInterceptorService` 保持一致）。
abstract final class BridgeEventType {
  static const String posted = 'posted';
  static const String removed = 'removed';
  static const String statusChanged = 'statusChanged';
}

/// MethodChannel / EventChannel 的薄封装：只做调用与异常翻译。
class InterceptorChannel {
  InterceptorChannel({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _method = methodChannel ?? const MethodChannel(BridgeChannel.method),
        _event = eventChannel ?? const EventChannel(BridgeChannel.events);

  final MethodChannel _method;
  final EventChannel _event;

  Future<T?> invoke<T>(String method, [Map<String, dynamic>? arguments]) async {
    try {
      return await _method.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      throw const InterceptorException('NO_PLATFORM', '当前平台不支持通知拦截能力');
    } on PlatformException catch (error) {
      throw InterceptorException(error.code, error.message ?? '原生调用失败');
    }
  }

  Stream<Map<String, dynamic>> get events => _events;

  late final Stream<Map<String, dynamic>> _events =
      _event.receiveBroadcastStream().map(asStringMap);
}
