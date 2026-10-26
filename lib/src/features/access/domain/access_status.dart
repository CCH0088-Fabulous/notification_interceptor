import '../../../core/util/json_cast.dart';

/// 通知使用权的当前状态，`granted` 与 `connected` 是两件事：
/// 前者由系统设置决定，后者由监听服务是否被绑定决定。
class AccessStatus {
  const AccessStatus({
    this.granted = false,
    this.connected = false,
    this.sdkInt = 0,
    this.ownPackage = '',
    this.historyCount = 0,
    this.ruleCount = 0,
    this.globalEnabled = true,
    this.serviceComponent = '',
  });

  final bool granted;
  final bool connected;
  final int sdkInt;
  final String ownPackage;
  final int historyCount;
  final int ruleCount;
  final bool globalEnabled;
  final String serviceComponent;

  bool get isReady => granted && connected;

  factory AccessStatus.fromJson(Map<String, dynamic> json) => AccessStatus(
        granted: asBool(json['granted']),
        connected: asBool(json['connected']),
        sdkInt: asInt(json['sdkInt']),
        ownPackage: asStringOrNull(json['ownPackage']) ?? '',
        historyCount: asInt(json['historyCount']),
        ruleCount: asInt(json['ruleCount']),
        globalEnabled: asBool(json['globalEnabled'], fallback: true),
        serviceComponent: asStringOrNull(json['serviceComponent']) ?? '',
      );

  AccessStatus copyWith({bool? granted, bool? connected}) => AccessStatus(
        granted: granted ?? this.granted,
        connected: connected ?? this.connected,
        sdkInt: sdkInt,
        ownPackage: ownPackage,
        historyCount: historyCount,
        ruleCount: ruleCount,
        globalEnabled: globalEnabled,
        serviceComponent: serviceComponent,
      );
}
