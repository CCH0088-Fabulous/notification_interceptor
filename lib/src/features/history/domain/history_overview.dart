import '../../../shared/domain/rule_action.dart';
import 'history_entry.dart';

enum HistoryPeriod {
  today('今天'),
  week('最近7天'),
  all('全部记录');

  const HistoryPeriod(this.label);
  final String label;

  int? since(DateTime now) => switch (this) {
    today => DateTime(now.year, now.month, now.day).millisecondsSinceEpoch,
    week => DateTime(now.year, now.month, now.day - 6).millisecondsSinceEpoch,
    all => null,
  };
}

typedef HistoryRuleKey = ({String? id, String? name, RuleAction action});

HistoryRuleKey historyRuleKey(HistoryEntry entry) {
  final id = entry.matchedRuleId?.trim();
  final name = entry.matchedRuleName?.trim();
  return (
    id: id == null || id.isEmpty ? null : id,
    name: id != null && id.isNotEmpty || name == null || name.isEmpty
        ? null
        : name,
    action: entry.action,
  );
}

class HistoryRuleEffect {
  HistoryRuleEffect({required this.key, required this.name});
  final HistoryRuleKey key;
  final String name;
  int count = 0;
  int removed = 0;
  RuleAction get action => key.action;
}

/// 同一通知的更新可产生多条处理记录，总数不能解释为独立消息数。
/// 统计输入必须是已按日期过滤的完整本地记录，不受列表检索影响。
class HistoryOverview {
  HistoryOverview(Iterable<HistoryEntry> source) {
    final groups = <HistoryRuleKey, HistoryRuleEffect>{};
    final entries = source.where((e) => !e.record.isGroupSummary).toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    for (final entry in entries) {
      total++;
      if (entry.action == RuleAction.intercept) {
        if (entry.cancelStatus == CancelStatus.success) {
          removed++;
        } else {
          unconfirmed++;
        }
      } else if (entry.action == RuleAction.allow) {
        kept++;
      } else {
        logOnly++;
      }
      final key = historyRuleKey(entry);
      final group = groups.putIfAbsent(
        key,
        () => HistoryRuleEffect(
          key: key,
          name: (entry.matchedRuleName?.trim().isNotEmpty ?? false)
              ? entry.matchedRuleName!.trim()
              : entry.matchedRuleId ?? '未匹配规则',
        ),
      );
      group.count++;
      if (entry.action == RuleAction.intercept &&
          entry.cancelStatus == CancelStatus.success) {
        group.removed++;
      }
    }
    rules = groups.values.toList()..sort((a, b) => b.count.compareTo(a.count));
  }
  int total = 0;
  int removed = 0;
  int kept = 0;
  int logOnly = 0;
  int unconfirmed = 0;
  late final List<HistoryRuleEffect> rules;
  double get removedRate => total == 0 ? 0 : removed / total;
}
