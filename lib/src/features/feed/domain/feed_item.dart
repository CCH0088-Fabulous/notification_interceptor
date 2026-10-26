import '../../../shared/domain/decision.dart';
import 'notification_record.dart';

/// 实时流中的一条记录。`decision` 为 null 表示来自"存量快照"，
/// 没有经过本次判定（例如订阅时已有的通知）。
class FeedItem {
  const FeedItem({
    required this.record,
    this.decision,
    this.existing = false,
    this.removed = false,
  });

  final NotificationRecord record;
  final Decision? decision;
  final bool existing;
  final bool removed;

  FeedItem copyWith({bool? removed}) => FeedItem(
        record: record,
        decision: decision,
        existing: existing,
        removed: removed ?? this.removed,
      );
}
