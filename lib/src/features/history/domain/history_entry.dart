import '../../../core/util/json_cast.dart';
import '../../../shared/domain/rule_action.dart';
import '../../feed/domain/notification_record.dart';

/// 一条历史记录，字段与 Kotlin `HistoryEntry.toMap()` 对应。
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.timestamp,
    required this.record,
    required this.action,
    this.matchedRuleId,
    this.matchedRuleName,
    this.cancelStatus = CancelStatus.notAttempted,
    this.note,
  });

  final String id;
  final int timestamp;
  final NotificationRecord record;
  final RuleAction action;
  final String? matchedRuleId;
  final String? matchedRuleName;
  final CancelStatus cancelStatus;
  final String? note;

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        id: asStringOrNull(json['id']) ?? '',
        timestamp: asInt(json['timestamp']),
        record: NotificationRecord.fromJson(asStringMap(json['snapshot'])),
        action: RuleAction.fromWire(json['action']),
        matchedRuleId: asStringOrNull(json['matchedRuleId']),
        matchedRuleName: asStringOrNull(json['matchedRuleName']),
        cancelStatus: CancelStatus.fromWire(json['cancelStatus']),
        note: asStringOrNull(json['note']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp,
        'snapshot': record.toJson(),
        'action': action.wire,
        'matchedRuleId': matchedRuleId,
        'matchedRuleName': matchedRuleName,
        'cancelStatus': cancelStatus.wire,
        'note': note,
      };
}
