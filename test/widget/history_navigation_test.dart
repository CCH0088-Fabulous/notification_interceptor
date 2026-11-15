import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_record.dart';
import 'package:notifinterceptor/src/features/history/domain/history_entry.dart';
import 'package:notifinterceptor/src/features/history/domain/history_query.dart';
import 'package:notifinterceptor/src/features/history/domain/history_repository.dart';
import 'package:notifinterceptor/src/features/history/presentation/history_controller.dart';
import 'package:notifinterceptor/src/features/history/presentation/history_page.dart';
import 'package:notifinterceptor/src/shared/domain/rule_action.dart';

final _testNow = DateTime(2026, 11, 11, 12);

class _History implements HistoryRepository {
  _History(this.entries);
  List<HistoryEntry> entries;
  @override
  Future<List<HistoryEntry>> query(HistoryQuery query) async => entries;
  @override
  Future<HistoryStats> stats() async => HistoryStats(total: entries.length);
  @override
  Future<void> clear() async => entries = [];
  @override
  Future<String> exportJson() async =>
      jsonEncode(entries.map((e) => e.id).toList());
}

HistoryEntry _entry(
  String id,
  int order, {
  String package = 'shop.a',
  String label = '商城',
  RuleAction action = RuleAction.intercept,
  CancelStatus status = CancelStatus.success,
}) {
  final at = _testNow.millisecondsSinceEpoch - order * 1000;
  return HistoryEntry(
    id: id,
    timestamp: at,
    action: action,
    cancelStatus: status,
    record: NotificationRecord(
      key: id,
      id: order,
      packageName: package,
      appLabel: label,
      postTime: at,
      title: '消息 $id',
      text: '内容 $id',
    ),
  );
}

Future<HistoryController> _open(
  WidgetTester tester,
  List<HistoryEntry> entries, {
  Size size = const Size(390, 1000),
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = HistoryController(
    repository: _History(entries),
    now: () => _testNow,
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(body: HistoryPage(controller: controller)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    220,
    scrollable: find
        .descendant(
          of: find.byKey(const Key('history-scroll-view')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('同名不同应用分别折叠，展开只影响展示，保留与仅记录不折叠', (tester) async {
    final controller = await _open(tester, [
      _entry('a-new', 0),
      _entry('keep', 1, action: RuleAction.allow),
      _entry('b-new', 2, package: 'shop.b'),
      _entry('a-old', 3, status: CancelStatus.rejected),
      _entry('b-old', 4, package: 'shop.b'),
      _entry('log', 5, action: RuleAction.logOnly),
    ]);
    expect(
      find.byKey(const ValueKey('history-app-group-shop.a')),
      findsOneWidget,
    );
    expect(find.text('消息 a-old'), findsNothing);
    expect(controller.overview.total, 6);
    expect(controller.overview.removed, 3);
    final groupA = find.byKey(const ValueKey('history-app-group-shop.a'));
    await _reveal(tester, groupA);
    await tester.tap(groupA);
    await tester.pumpAndSettle();
    await _reveal(tester, find.text('消息 a-old'));
    expect(find.text('消息 a-old'), findsOneWidget);
    expect(controller.entries, hasLength(6));
    expect(controller.overview.removed, 3);
    expect(jsonDecode(await controller.exportJson()), hasLength(6));
    await _reveal(
      tester,
      find.byKey(const ValueKey('history-app-group-shop.b')),
    );
    expect(find.text('消息 b-old'), findsNothing);
    expect(
      controller.entries.where((e) => e.action == RuleAction.allow),
      hasLength(1),
    );
    final view = tester.widget<CustomScrollView>(
      find.byKey(const Key('history-scroll-view')),
    );
    view.controller!.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'a-old');
    await tester.pumpAndSettle();
    expect(controller.entries.single.id, 'a-old');
    expect(
      find.byKey(const ValueKey('history-app-group-shop.a')),
      findsNothing,
    );
    expect(find.text('消息 a-old'), findsOneWidget);
    expect(controller.overview.total, 6);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭折叠恢复逐条记录；重新开启后收起；清空不留下旧分组', (tester) async {
    final controller = await _open(tester, [
      _entry('new', 0),
      _entry('old', 1),
    ]);
    final toggle = find.byKey(const Key('history-group-applications'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('history-app-group-shop.a')),
      findsNothing,
    );
    expect(find.text('消息 new'), findsOneWidget);
    expect(find.text('消息 old'), findsOneWidget);
    expect(controller.entries.map((e) => e.id), ['new', 'old']);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('消息 old'), findsNothing);
    await controller.clear();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('history-app-group-shop.a')),
      findsNothing,
    );
    expect(controller.overview.total, 0);
  });

  testWidgets('长列表滚动后出现顶部按钮，点击回顶不改变筛选或记录', (tester) async {
    final controller = await _open(tester, [
      for (var i = 0; i < 80; i++) _entry('$i', i, action: RuleAction.allow),
    ]);
    await controller.setActionFilter(RuleAction.allow);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('history-scroll-top')), findsNothing);
    await tester.drag(
      find.byKey(const Key('history-scroll-view')),
      const Offset(0, -1100),
    );
    await tester.pumpAndSettle();
    final view = tester.widget<CustomScrollView>(
      find.byKey(const Key('history-scroll-view')),
    );
    expect(view.controller!.offset, greaterThan(400));
    await tester.tap(find.byKey(const Key('history-scroll-top')));
    await tester.pumpAndSettle();
    expect(view.controller!.offset, closeTo(0, 1));
    expect(controller.query.action, RuleAction.allow);
    expect(controller.entries, hasLength(80));
    expect(find.byKey(const Key('history-scroll-top')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字体的应用折叠卡片可以展开且不溢出', (tester) async {
    await _open(
      tester,
      [
        _entry('长标题' * 30, 0, label: '很长的应用名称' * 20),
        _entry('second', 1, label: '很长的应用名称' * 20),
      ],
      size: const Size(320, 1000),
      scale: 1.4,
    );
    final group = find.byKey(const ValueKey('history-app-group-shop.a'));
    await _reveal(tester, group);
    await tester.tap(group);
    await tester.pumpAndSettle();
    await _reveal(tester, find.text('消息 second'));
    expect(find.text('消息 second'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
