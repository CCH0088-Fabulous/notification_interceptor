import 'dart:convert';

import '../../../shared/domain/decision.dart';
import '../../../shared/domain/rule_action.dart';
import '../../history/domain/history_entry.dart';
import '../../presets/domain/filter_preset.dart';
import '../../rules/domain/rule_set.dart';

enum ComparisonPeriod {
  today('今天'),
  week('最近7天'),
  all('全部记录');

  const ComparisonPeriod(this.label);
  final String label;
  int? since(DateTime now) => switch (this) {
    today => DateTime(now.year, now.month, now.day).millisecondsSinceEpoch,
    week => DateTime(now.year, now.month, now.day - 6).millisecondsSinceEpoch,
    all => null,
  };
}

class ComparisonDecisionPair {
  const ComparisonDecisionPair({
    required this.entryId,
    required this.before,
    required this.after,
  });
  final String entryId;
  final Decision before;
  final Decision after;
}

class ComparisonEvaluation {
  const ComparisonEvaluation({
    required this.rows,
    required this.evaluatedAt,
    required this.zoneId,
    this.baseIssues = const [],
    this.candidateIssues = const [],
  });
  final List<ComparisonDecisionPair> rows;
  final int evaluatedAt;
  final String zoneId;
  final List<RuleIssue> baseIssues;
  final List<RuleIssue> candidateIssues;
}

class BatchComparisonRow {
  const BatchComparisonRow({
    required this.entry,
    required this.before,
    required this.after,
  });
  final HistoryEntry entry;
  final Decision before;
  final Decision after;
  bool get actionChanged => before.action != after.action;
  bool get ruleChanged =>
      before.ruleId != after.ruleId || before.reason != after.reason;
  bool get changed => actionChanged || ruleChanged;
  bool get moreIntercepted =>
      before.action != RuleAction.intercept &&
      after.action == RuleAction.intercept;
  bool get lessIntercepted =>
      before.action == RuleAction.intercept &&
      after.action != RuleAction.intercept;

  Map<String, dynamic> toJson() => {
    'entryId': entry.id,
    'timestamp': entry.timestamp,
    'record': Map<String, dynamic>.of(entry.record.toJson())..remove('extras'),
    'before': _decisionJson(before),
    'after': _decisionJson(after),
    'historicalAction': entry.action.wire,
    'cancelStatus': entry.cancelStatus.wire,
  };
}

Map<String, dynamic> _decisionJson(Decision decision) => {
  'action': decision.action.wire,
  'ruleId': decision.ruleId,
  'ruleName': decision.ruleName,
  'reason': decision.reason,
};

class BatchComparisonResult {
  BatchComparisonResult({
    required this.target,
    required List<BatchComparisonRow> rows,
    required this.beforeRules,
    required this.afterRules,
    required this.generatedAt,
    required this.zoneId,
    required this.period,
    required this.limit,
    required this.sourceCount,
    required this.skippedSummaries,
    this.skippedOngoing = 0,
    List<RuleIssue> baseIssues = const [],
    List<RuleIssue> candidateIssues = const [],
  }) : rows = List.unmodifiable(rows),
       baseIssues = List.unmodifiable(baseIssues),
       candidateIssues = List.unmodifiable(candidateIssues);
  final FilterPreset target;
  final List<BatchComparisonRow> rows;
  final RuleSet beforeRules;
  final RuleSet afterRules;
  final int generatedAt;
  final String zoneId;
  final ComparisonPeriod period;
  final int limit;
  final int sourceCount;
  final int skippedSummaries;
  final int skippedOngoing;
  final List<RuleIssue> baseIssues;
  final List<RuleIssue> candidateIssues;
  int get sampleCount => rows.length;
  int get hiddenContentCount =>
      rows.where((r) => r.entry.record.isContentHidden).length;
  int get actionChangedCount => rows.where((r) => r.actionChanged).length;
  int get ruleChangedCount => rows.where((r) => r.ruleChanged).length;
  int get onlyRuleChangedCount =>
      rows.where((r) => r.ruleChanged && !r.actionChanged).length;
  int get changedCount => rows.where((r) => r.changed).length;
  int get moreInterceptedCount => rows.where((r) => r.moreIntercepted).length;
  int get lessInterceptedCount => rows.where((r) => r.lessIntercepted).length;
  Map<RuleAction, int> _counts(bool after) => {
    for (final action in RuleAction.values)
      action: rows
          .where((r) => (after ? r.after : r.before).action == action)
          .length,
  };
  Map<RuleAction, int> get beforeCounts => _counts(false);
  Map<RuleAction, int> get afterCounts => _counts(true);

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'kind': 'notification_batch_comparison',
    'generatedAt': generatedAt,
    'zoneId': zoneId,
    'target': {'id': target.id, 'name': target.name, 'kind': target.kind.name},
    'scope': {
      'period': period.name,
      'limit': limit,
      'replayTime': 'historical',
      'timeZoneBasis': 'current_device',
      'sourceCount': sourceCount,
    },
    'sampleCount': sampleCount,
    'skippedSummaries': skippedSummaries,
    'skippedOngoing': skippedOngoing,
    'hiddenContentCount': hiddenContentCount,
    'currentRules': beforeRules.toJson(),
    'candidateRules': afterRules.toJson(),
    'summary': {
      'before': {for (final e in beforeCounts.entries) e.key.wire: e.value},
      'after': {for (final e in afterCounts.entries) e.key.wire: e.value},
      'actionChanged': actionChangedCount,
      'ruleChanged': ruleChangedCount,
      'totalChanged': changedCount,
      'moreIntercepted': moreInterceptedCount,
      'lessIntercepted': lessInterceptedCount,
      'historicalConfirmedRemoved': rows
          .where(
            (r) =>
                r.entry.action == RuleAction.intercept &&
                r.entry.cancelStatus == CancelStatus.success,
          )
          .length,
    },
    'baseIssues': baseIssues.map(_issueJson).toList(),
    'candidateIssues': candidateIssues.map(_issueJson).toList(),
    'rows': rows.map((r) => r.toJson()).toList(),
  };
  static Map<String, dynamic> _issueJson(RuleIssue issue) => {
    'ruleId': issue.ruleId,
    'field': issue.field,
    'message': issue.message,
  };
  String exportJson() => jsonEncode(toJson());
}
