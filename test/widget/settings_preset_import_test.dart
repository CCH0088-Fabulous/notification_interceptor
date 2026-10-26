import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/access/domain/access_repository.dart';
import 'package:notifinterceptor/src/features/access/domain/access_status.dart';
import 'package:notifinterceptor/src/features/access/presentation/access_controller.dart';
import 'package:notifinterceptor/src/features/history/domain/history_entry.dart';
import 'package:notifinterceptor/src/features/history/domain/history_query.dart';
import 'package:notifinterceptor/src/features/history/domain/history_repository.dart';
import 'package:notifinterceptor/src/features/history/presentation/history_controller.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_record.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_set.dart';
import 'package:notifinterceptor/src/features/rules/domain/rules_repository.dart';
import 'package:notifinterceptor/src/features/rules/presentation/rules_controller.dart';
import 'package:notifinterceptor/src/features/settings/presentation/settings_page.dart';
import 'package:notifinterceptor/src/shared/domain/decision.dart';
import 'package:notifinterceptor/src/shared/domain/rule_action.dart';

class _Access implements AccessRepository {
  @override
  Future<AccessStatus> getStatus() async =>
      const AccessStatus(granted: true, connected: true, sdkInt: 36);

  @override
  Future<void> openAccessSettings() async {}

  @override
  Future<void> requestRebind() async {}
}

class _History implements HistoryRepository {
  @override
  Future<void> clear() async {}

  @override
  Future<String> exportJson() async => '[]';

  @override
  Future<List<HistoryEntry>> query(HistoryQuery query) async => const [];

  @override
  Future<HistoryStats> stats() async => const HistoryStats(total: 0, byAction: {});
}

class _Rules implements RulesRepository {
  RuleSet ruleSet = RuleSet.empty;
  int saveCount = 0;

  @override
  Future<RuleSet> load() async => ruleSet;

  @override
  Future<RuleSaveResult> save(RuleSet rules) async {
    ruleSet = rules;
    saveCount += 1;
    return RuleSaveResult(ruleSet: rules, issues: const []);
  }

  @override
  Future<Decision> evaluate(NotificationRecord sample, {RuleSet? ruleSet}) async =>
      const Decision();

  @override
  Future<List<String>> seenPackages() async => const [];
}

void main() {
  testWidgets('设置页可一键导入生成器分流预设', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final events = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(events.close);

    final repository = _Rules();
    final access = AccessController(repository: _Access(), events: events.stream);
    final history = HistoryController(repository: _History());
    final rules = RulesController(repository: repository);
    addTearDown(() {
      access.dispose();
      history.dispose();
      rules.dispose();
    });

    await access.refresh();
    await history.load();
    await rules.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(access: access, history: history, rules: rules),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.dragUntilVisible(
      find.text('导入分流规则'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.tap(find.text('导入分流规则'));
    await tester.pumpAndSettle();

    expect(repository.saveCount, 1);
    expect(repository.ruleSet.rules, hasLength(4));
    expect(repository.ruleSet.rules.first.packages, ['dev.poc.notifgen']);
    expect(repository.ruleSet.rules.last.action, RuleAction.intercept);
    expect(find.textContaining('已导入 4 条'), findsOneWidget);
  });
}
