import '../../../shared/domain/rule_action.dart';
import '../domain/history_entry.dart';

String historyResultLabel(HistoryEntry entry) {
  if (entry.action == RuleAction.allow) return '保留';
  if (entry.action == RuleAction.logOnly) return '仅记录';
  if (entry.cancelStatus == CancelStatus.success) return '已移除';
  return entry.cancelStatus == CancelStatus.pending ? '待确认' : '未移除';
}

String historyResultDescription(HistoryEntry entry) {
  if (entry.action == RuleAction.allow) return '照常保留';
  if (entry.action == RuleAction.logOnly) return '仅记录，未执行移除';
  return switch (entry.cancelStatus) {
    CancelStatus.success => '已移除通知栏',
    CancelStatus.pending => '等待系统确认移除',
    CancelStatus.rejected => '系统未允许移除',
    CancelStatus.failed => '移除失败',
    CancelStatus.notAttempted => '未执行移除',
  };
}

String historyRuleName(HistoryEntry entry) =>
    (entry.matchedRuleName?.trim().isNotEmpty ?? false)
    ? entry.matchedRuleName!.trim()
    : entry.matchedRuleId ?? '未匹配规则';

String historyFullBody(HistoryEntry entry) {
  final record = entry.record;
  if (record.isContentHidden) return record.displayBody;
  if (record.bigText?.trim().isNotEmpty ?? false) return record.bigText!;
  if (record.textLines.isNotEmpty) return record.textLines.join('\n');
  return record.displayBody;
}

String historyPercent(double rate) {
  final value = rate * 100;
  return value == value.roundToDouble()
      ? '${value.toInt()}%'
      : '${value.toStringAsFixed(1)}%';
}
