import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_record.dart';
import 'package:notifinterceptor/src/features/history/domain/history_entry.dart';
import 'package:notifinterceptor/src/features/history/domain/history_query.dart';
import 'package:notifinterceptor/src/features/history/domain/history_repository.dart';
import 'package:notifinterceptor/src/features/history/presentation/history_controller.dart';
import 'package:notifinterceptor/src/features/history/presentation/history_page.dart';
import 'package:notifinterceptor/src/shared/domain/rule_action.dart';

class _History implements HistoryRepository {
  @override
  Future<List<HistoryEntry>> query(HistoryQuery query) async => const [
    HistoryEntry(
      id: 'visible',
      timestamp: 1760000000000,
      action: RuleAction.allow,
      record: NotificationRecord(
        key: 'visible',
        id: 1,
        packageName: 'dev.poc.notifgen',
        appLabel: '通知生成器',
        postTime: 1760000000000,
        title: '项目讨论',
        text: '明天下午三点开会',
      ),
    ),
    HistoryEntry(
      id: 'hidden',
      timestamp: 1760000000000,
      action: RuleAction.intercept,
      record: NotificationRecord(
        key: 'hidden',
        id: 2,
        packageName: 'dev.poc.notifgen',
        appLabel: '通知生成器',
        postTime: 1760000000000,
        title: '通知生成器',
        text: 'Sensitive notification content hidden',
      ),
    ),
    HistoryEntry(
      id: 'summary',
      timestamp: 1760000000000,
      action: RuleAction.allow,
      record: NotificationRecord(
        key: 'summary',
        id: 3,
        packageName: 'dev.poc.notifgen',
        appLabel: '通知生成器',
        postTime: 1760000000000,
        title: '系统自动汇总',
        isGroupSummary: true,
      ),
    ),
    HistoryEntry(
      id: 'empty',
      timestamp: 1760000000000,
      action: RuleAction.allow,
      record: NotificationRecord(
        key: 'empty',
        id: 4,
        packageName: 'dev.poc.notifgen',
        appLabel: '通知生成器',
        postTime: 1760000000000,
        title: '普通空正文通知',
      ),
    ),
  ];
  @override
  Future<HistoryStats> stats() async => const HistoryStats(
    total: 4,
    byAction: {RuleAction.allow: 3, RuleAction.intercept: 1},
  );
  @override
  Future<void> clear() async {}
  @override
  Future<String> exportJson() async => '[]';
}

void main() {
  testWidgets('历史同时显示正文与处理动作，隐藏内容明确标注', (tester) async {
    final controller = HistoryController(repository: _History());
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HistoryPage(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('系统自动汇总'), findsNothing);
    expect(find.text('普通空正文通知'), findsOneWidget);
    expect(controller.entries, hasLength(4)); // 只隐藏展示，不删原始记录。
    expect(find.text('项目讨论'), findsOneWidget);
    expect(find.text('明天下午三点开会'), findsOneWidget);
    expect(find.text('通知内容已隐藏'), findsOneWidget);
    expect(find.text('系统已隐藏通知内容，无法读取原文'), findsOneWidget);
    expect(find.text('Sensitive notification content hidden'), findsNothing);
    expect(find.text('通知生成器'), findsNothing);
    expect(find.text('放行'), findsWidgets);
    expect(find.text('拦截'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
