import '../../../core/util/json_cast.dart';
import '../../../shared/domain/decision.dart';
import 'notification_record.dart';

/// 原生事件的信封。切换成强类型，避免 UI 里到处读 Map。
class NotificationEvent {
  const NotificationEvent({
    required this.type,
    this.record,
    this.decision,
    this.connected,
    this.granted,
    this.existing = false,
    this.key,
  });

  final String type;
  final NotificationRecord? record;
  final Decision? decision;
  final bool? connected;
  final bool? granted;
  final bool existing;

  /// removed 事件没有完整快照，只带 key。
  final String? key;

  factory NotificationEvent.fromJson(Map<String, dynamic> json) {
    final recordJson = json['record'];
    final decisionJson = json['decision'];
    final envelope = recordJson is Map ? asStringMap(recordJson) : null;
    final snapshot = envelope?['snapshot'] ?? envelope;
    return NotificationEvent(
      type: asStringOrNull(json['type']) ?? '',
      record: snapshot is Map
          ? NotificationRecord.fromJson(asStringMap(snapshot))
          : null,
      decision: decisionJson is Map
          ? Decision.fromJson(asStringMap(decisionJson))
          : null,
      connected: json['connected'] is bool ? json['connected'] as bool : null,
      granted: json['granted'] is bool ? json['granted'] as bool : null,
      existing: asBool(json['existing']),
      key: asStringOrNull(json['key']),
    );
  }
}
