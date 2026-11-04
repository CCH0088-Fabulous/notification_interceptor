import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/comparison/domain/comparison_models.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_record.dart';
import 'package:notifinterceptor/src/features/history/domain/history_entry.dart';
import 'package:notifinterceptor/src/features/presets/domain/filter_preset.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_set.dart';
import 'package:notifinterceptor/src/shared/domain/decision.dart';
import 'package:notifinterceptor/src/shared/domain/rule_action.dart';

void main() {
  test('动作变化与仅规则变化分别计数，预测不冒充历史真实取消', () {
    const entry = HistoryEntry(
      id: 'event',
      timestamp: 1793750400000,
      action: RuleAction.intercept,
      cancelStatus: CancelStatus.failed,
      record: NotificationRecord(
        key: 'k',
        id: 1,
        packageName: 'app',
        postTime: 1,
        text: 'Sensitive notification content hidden',
      ),
    );
    final result = BatchComparisonResult(
      target: FilterPreset.examples.first,
      beforeRules: RuleSet.empty,
      afterRules: RuleSet.empty,
      generatedAt: 1793750400000,
      zoneId: 'Asia/Shanghai',
      period: ComparisonPeriod.all,
      limit: 1000,
      sourceCount: 4,
      skippedSummaries: 0,
      rows: [
        const BatchComparisonRow(
          entry: entry,
          before: Decision(),
          after: Decision(
            action: RuleAction.intercept,
            ruleId: 'drop',
            reason: 'rule',
          ),
        ),
        const BatchComparisonRow(
          entry: entry,
          before: Decision(
            action: RuleAction.intercept,
            ruleId: 'drop',
            reason: 'rule',
          ),
          after: Decision(),
        ),
        const BatchComparisonRow(
          entry: entry,
          before: Decision(ruleId: 'old', reason: 'rule'),
          after: Decision(ruleId: 'new', reason: 'rule'),
        ),
        const BatchComparisonRow(
          entry: entry,
          before: Decision(action: RuleAction.logOnly),
          after: Decision(action: RuleAction.logOnly),
        ),
      ],
    );
    expect(result.actionChangedCount, 2);
    expect(result.ruleChangedCount, 3);
    expect(result.onlyRuleChangedCount, 1);
    expect(result.changedCount, 3);
    expect(result.moreInterceptedCount, 1);
    expect(result.lessInterceptedCount, 1);
    expect(result.beforeCounts, {
      RuleAction.allow: 2,
      RuleAction.intercept: 1,
      RuleAction.logOnly: 1,
    });
    expect(result.afterCounts, result.beforeCounts);
    expect(result.hiddenContentCount, 4);
    expect(result.toJson()['summary']['historicalConfirmedRemoved'], 0);
  });
}
