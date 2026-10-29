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
  final now = DateTime.now().millisecondsSinceEpoch;
  int clears = 0;
  bool emptied = false;
  @override
  Future<List<HistoryEntry>> query(HistoryQuery query) async => emptied
      ? []
      : [
          HistoryEntry(
            id: 'allow',
            timestamp: now,
            action: RuleAction.allow,
            matchedRuleId: 'work',
            matchedRuleName: '保留工作消息',
            record: NotificationRecord(
              key: 'a',
              id: 1,
              packageName: 'work.app',
              appLabel: '工作应用',
              postTime: now,
              title: '会议安排',
              text: '周四评审',
            ),
          ),
          HistoryEntry(
            id: 'drop',
            timestamp: now - 1000,
            action: RuleAction.intercept,
            cancelStatus: CancelStatus.success,
            matchedRuleId: 'promo',
            matchedRuleName: '移出促销',
            record: NotificationRecord(
              key: 'b',
              id: 2,
              packageName: 'dev.poc.notifgen',
              appLabel: '通知生成器',
              postTime: now,
              title: '会员中心',
              text: '简短预览',
              bigText: '这是完整的促销通知正文，详情应该显示这里的全部内容。',
              channelId: 'gen_promo_banner',
            ),
          ),
          HistoryEntry(
            id: 'fail',
            timestamp: now - 2000,
            action: RuleAction.intercept,
            cancelStatus: CancelStatus.rejected,
            matchedRuleId: 'promo',
            matchedRuleName: '移出促销',
            record: NotificationRecord(
              key: 'c',
              id: 3,
              packageName: 'dev.poc.notifgen',
              appLabel: '通知生成器',
              postTime: now,
              title: '不能取消',
              text: '正文',
            ),
          ),
          HistoryEntry(
            id: 'summary',
            timestamp: now,
            action: RuleAction.allow,
            record: NotificationRecord(
              key: 's',
              id: 4,
              packageName: 'dev.poc.notifgen',
              postTime: now,
              isGroupSummary: true,
            ),
          ),
        ];
  @override
  Future<HistoryStats> stats() async => HistoryStats(total: emptied ? 0 : 4);
  @override
  Future<void> clear() async {
    clears++;
    emptied = true;
  }

  @override
  Future<String> exportJson() async => '[]';
}

Future<HistoryController> _host(
  WidgetTester tester,
  _History repo, {
  Size size = const Size(390, 1000),
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final c = HistoryController(repository: repo);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          appBar: AppBar(
            title: const Text('历史记录'),
            actions: [
              IconButton(
                tooltip: '更多操作',
                onPressed: () => showHistoryActions(
                  tester.element(find.byType(HistoryPage)),
                  c,
                ),
                icon: const Icon(Icons.more_vert),
              ),
            ],
          ),
          body: HistoryPage(controller: c),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('搜索和处理分类不改变统计，从卡片进入完整详情与同规则记录', (tester) async {
    final c = await _host(tester, _History());
    expect(find.text('33.3%'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '会员');
    await tester.pumpAndSettle();
    expect(c.entries, hasLength(1));
    expect(find.text('33.3%'), findsOneWidget);
    await tester.tap(find.text('会员中心'));
    await tester.pumpAndSettle();
    expect(find.text('通知详情'), findsOneWidget);
    expect(find.text('这是完整的促销通知正文，详情应该显示这里的全部内容。'), findsOneWidget);
    expect(find.text('促销通知 · 横幅提醒'), findsOneWidget);
    final scroll = find
        .descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('查看同规则记录'),
      150,
      scrollable: scroll,
    );
    await tester.tap(find.text('查看同规则记录'));
    await tester.pumpAndSettle();
    expect(c.entries, hasLength(2));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.text('同规则记录'), findsOneWidget);
    expect(find.text('33.3%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('规则面板能回查，应用筛选不会修改整体概览', (tester) async {
    final c = await _host(tester, _History());
    await tester.tap(find.text('规则效果 ›'));
    await tester.pumpAndSettle();
    expect(find.text('规则效果'), findsOneWidget);
    expect(find.text('已移出 1 条 · 1 条未确认成功'), findsOneWidget);
    await tester.tap(find.text('保留工作消息').last);
    await tester.pumpAndSettle();
    expect(c.entries.single.id, 'allow');
    expect(c.overview.total, 3);
    await tester.tap(find.byTooltip('筛选记录'));
    await tester.pumpAndSettle();
    final dropdown = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(DropdownButton<String>),
    );
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('通知生成器').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用筛选'));
    await tester.pumpAndSettle();
    expect(c.query.packageName, 'dev.poc.notifgen');
    expect(c.overview.total, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('清空需要确认，取消不删数据，确认后才清空', (tester) async {
    final repo = _History();
    final c = await _host(tester, repo);
    Future<void> openClear() async {
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空历史'));
      await tester.pumpAndSettle();
    }

    await openClear();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(repo.clears, 0);
    expect(c.allEntries, hasLength(4));
    await openClear();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(repo.clears, 1);
    expect(c.allEntries, isEmpty);
    expect(find.text('0%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏和大字体不溢出，详情与筛选可滚动', (tester) async {
    await _host(tester, _History(), size: const Size(320, 760), scale: 1.5);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('会员中心'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('会员中心'));
    await tester.pumpAndSettle();
    expect(find.text('通知详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
