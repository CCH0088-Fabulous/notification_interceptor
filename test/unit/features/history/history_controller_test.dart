import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/history/domain/history_entry.dart';
import 'package:notifinterceptor/src/features/history/domain/history_overview.dart';
import 'package:notifinterceptor/src/features/history/domain/history_query.dart';
import 'package:notifinterceptor/src/features/history/domain/history_repository.dart';
import 'package:notifinterceptor/src/features/history/presentation/history_controller.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_record.dart';
import 'package:notifinterceptor/src/shared/domain/rule_action.dart';

final now = DateTime(2026, 10, 29, 14, 30);
HistoryEntry entry(
  String id, {
  RuleAction action = RuleAction.allow,
  String pkg = 'com.a',
  String title = '测试',
  DateTime? at,
  CancelStatus cancel = CancelStatus.notAttempted,
  bool summary = false,
  String? rule,
  String? ruleName,
}) => HistoryEntry(
  id: id,
  timestamp: (at ?? now).millisecondsSinceEpoch,
  action: action,
  cancelStatus: cancel,
  matchedRuleId: rule,
  matchedRuleName: ruleName,
  record: NotificationRecord(
    key: id,
    id: 1,
    packageName: pkg,
    appLabel: '工作软件',
    postTime: (at ?? now).millisecondsSinceEpoch,
    title: title,
    bigText: '完整正文',
    isGroupSummary: summary,
  ),
);

class _FakeHistoryRepository implements HistoryRepository {
  _FakeHistoryRepository(this.items);
  List<HistoryEntry> items;
  HistoryQuery? lastQuery;
  int clearCount = 0;
  Completer<List<HistoryEntry>>? pending;
  bool fail = false;
  @override
  Future<List<HistoryEntry>> query(HistoryQuery query) async {
    lastQuery = query;
    if (fail) throw StateError('read failed');
    if (pending != null) return pending!.future;
    return items.take(query.limit).toList();
  }

  @override
  Future<void> clear() async {
    clearCount++;
    items = [];
  }

  @override
  Future<HistoryStats> stats() async => HistoryStats(
    total: items.length,
    byAction: {
      for (final action in RuleAction.values)
        action: items.where((e) => e.action == action).length,
    },
  );
  @override
  Future<String> exportJson() async => '[${items.length}]';
}

HistoryController _controllerFor(_FakeHistoryRepository repository) =>
    HistoryController(repository: repository, now: () => now);

void main() {
  test('完整加载窗口，设置页保留原始统计，效果统计排除汇总与失败', () async {
    final repo = _FakeHistoryRepository([
      entry(
        'success',
        action: RuleAction.intercept,
        cancel: CancelStatus.success,
      ),
      entry(
        'failed',
        action: RuleAction.intercept,
        cancel: CancelStatus.failed,
      ),
      entry(
        'pending',
        action: RuleAction.intercept,
        cancel: CancelStatus.pending,
      ),
      entry('allow'),
      entry('log', action: RuleAction.logOnly),
      entry('summary', summary: true),
    ]);
    final c = _controllerFor(repo);
    addTearDown(c.dispose);
    await c.load();
    expect(repo.lastQuery?.limit, 1000);
    expect(c.allEntries, hasLength(6));
    expect(c.entries, hasLength(5));
    expect(c.stats.total, 6);
    expect(c.overview.total, 5);
    expect(c.overview.removed, 1);
    expect(c.overview.removedRate, .2);
    expect(c.overview.kept, 1);
    expect(c.overview.logOnly, 1);
    expect(c.overview.unconfirmed, 2);
  });

  test('搜索100条之后的记录，动作和包名筛选均不改变统计', () async {
    final repo = _FakeHistoryRepository([
      for (var i = 0; i < 150; i++)
        entry(
          '$i',
          title: i == 149 ? '唯一会议' : '其他',
          pkg: i == 149 ? 'com.work' : 'com.a',
          action: i == 149 ? RuleAction.intercept : RuleAction.allow,
          cancel: i == 149 ? CancelStatus.success : CancelStatus.notAttempted,
        ),
    ]);
    final c = _controllerFor(repo);
    addTearDown(c.dispose);
    await c.load();
    c.setSearch('唯一会议');
    expect(c.entries.single.id, '149');
    await c.setActionFilter(RuleAction.intercept);
    await c.setPackageFilter(' com.work ');
    expect(c.query.packageName, 'com.work');
    expect(c.entries.single.id, '149');
    expect(c.overview.total, 150);
    expect(c.overview.removed, 1);
    expect(repo.lastQuery?.action, isNull);
    expect(repo.lastQuery?.packageName, isNull);
    c.resetFilters();
    expect(c.entries, hasLength(150));
    c.setSearch('工作软件');
    expect(c.entries, hasLength(150));
    c.setSearch('完整正文');
    expect(c.entries, hasLength(150));
    await c.setPackageFilter('  ');
    expect(c.query.packageName, isNull);
  });

  test('日期使用本地日界线，七天包含今天与之前六天，全部可重置日期限制', () async {
    final c = _controllerFor(
      _FakeHistoryRepository([
        entry('midnight', at: DateTime(2026, 10, 29)),
        entry('yesterday', at: DateTime(2026, 10, 28, 23, 59)),
        entry('six', at: DateTime(2026, 10, 23)),
        entry('seven', at: DateTime(2026, 10, 22, 23, 59)),
      ]),
    );
    addTearDown(c.dispose);
    await c.load();
    expect(c.entries.map((e) => e.id), ['midnight']);
    c.setPeriod(HistoryPeriod.week);
    expect(c.overview.total, 3);
    c.setPeriod(HistoryPeriod.all);
    expect(c.overview.total, 4);
    c.setSearch('missing');
    expect(c.entries, isEmpty);
    expect(c.overview.total, 4);
  });

  test('规则按当时ID和动作分组，改名不重复，同名不同ID不混淆', () async {
    final c = _controllerFor(
      _FakeHistoryRepository([
        entry(
          'old',
          rule: 'r1',
          ruleName: '旧名字',
          at: now.subtract(const Duration(minutes: 1)),
        ),
        entry('new', rule: 'r1', ruleName: '新名字'),
        entry('other', rule: 'r2', ruleName: '新名字'),
        entry('default'),
      ]),
    );
    addTearDown(c.dispose);
    await c.load();
    final effect = c.overview.rules.first;
    expect(c.overview.rules, hasLength(3));
    expect(effect.name, '新名字');
    expect(effect.count, 2);
    c.setRuleFilter(effect.key);
    expect(c.entries, hasLength(2));
    expect(c.overview.total, 4);
    c.setRuleFilter(null);
    expect(c.entries, hasLength(4));
  });

  test('空记录比率不产生NaN，清空期间旧加载回包不能恢复记录', () async {
    final repo = _FakeHistoryRepository([entry('old')]);
    final c = _controllerFor(repo);
    addTearDown(c.dispose);
    await c.load();
    repo.pending = Completer();
    final load = c.load();
    await c.clear();
    repo.pending!.complete([entry('late')]);
    await load;
    expect(c.allEntries, isEmpty);
    expect(c.stats.total, 0);
    expect(c.overview.removedRate, 0);
    expect(c.loading, false);
    expect(repo.clearCount, 1);
  });

  test('读取失败保留上次记录，成功重试清除错误，导出保持原始仓储结果', () async {
    final repo = _FakeHistoryRepository([entry('a')]);
    final c = _controllerFor(repo);
    addTearDown(c.dispose);
    await c.load();
    repo.fail = true;
    await c.load();
    expect(c.error, isNotNull);
    expect(c.entries, hasLength(1));
    repo.fail = false;
    await c.load();
    expect(c.error, isNull);
    expect(await c.exportJson(), '[1]');
  });
}
