import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/history/domain/history_entry.dart';
import 'package:notifinterceptor/src/features/history/domain/history_query.dart';
import 'package:notifinterceptor/src/features/history/domain/history_repository.dart';
import 'package:notifinterceptor/src/features/history/presentation/history_controller.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_record.dart';
import 'package:notifinterceptor/src/shared/domain/rule_action.dart';

class _FakeHistoryRepository implements HistoryRepository {
  _FakeHistoryRepository(this._entries);

  List<HistoryEntry> _entries;
  HistoryQuery? lastQuery;
  int clearCount = 0;

  @override
  Future<List<HistoryEntry>> query(HistoryQuery query) async {
    lastQuery = query;
    return _entries
        .where((entry) => query.action == null || entry.action == query.action)
        .where((entry) =>
            query.packageName == null || entry.record.packageName == query.packageName)
        .toList();
  }

  @override
  Future<void> clear() async {
    clearCount++;
    _entries = const [];
  }

  @override
  Future<HistoryStats> stats() async => HistoryStats(
        total: _entries.length,
        byAction: {
          for (final action in RuleAction.values)
            action: _entries.where((entry) => entry.action == action).length,
        },
      );

  @override
  Future<String> exportJson() async => '[${_entries.length}]';
}

HistoryEntry entry(String id, {RuleAction action = RuleAction.allow, String pkg = 'com.a'}) =>
    HistoryEntry(
      id: id,
      timestamp: 1760000000000,
      record: NotificationRecord(key: id, id: 1, packageName: pkg, postTime: 1760000000000),
      action: action,
    );

void main() {
  group('HistoryController', () {
    test('load 填充条目与统计', () async {
      final controller = HistoryController(
        repository: _FakeHistoryRepository([
          entry('a', action: RuleAction.intercept),
          entry('b'),
        ]),
      );
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.entries, hasLength(2));
      expect(controller.stats.total, 2);
      expect(controller.stats.byAction[RuleAction.intercept], 1);
      expect(controller.error, isNull);
    });

    test('动作筛选会带进查询', () async {
      final repository = _FakeHistoryRepository([
        entry('a', action: RuleAction.intercept),
        entry('b'),
      ]);
      final controller = HistoryController(repository: repository);
      addTearDown(controller.dispose);

      await controller.setActionFilter(RuleAction.intercept);

      expect(repository.lastQuery?.action, RuleAction.intercept);
      expect(controller.entries, hasLength(1));
    });

    test('包名筛选忽略空白输入', () async {
      final repository = _FakeHistoryRepository([entry('a')]);
      final controller = HistoryController(repository: repository);
      addTearDown(controller.dispose);

      await controller.setPackageFilter('   ');
      expect(repository.lastQuery?.packageName, isNull);

      await controller.setPackageFilter(' com.a ');
      expect(repository.lastQuery?.packageName, 'com.a');
    });

    test('clear 清空条目并重置统计', () async {
      final repository = _FakeHistoryRepository([entry('a')]);
      final controller = HistoryController(repository: repository);
      addTearDown(controller.dispose);
      await controller.load();

      await controller.clear();

      expect(repository.clearCount, 1);
      expect(controller.entries, isEmpty);
      expect(controller.stats.total, 0);
    });

    test('exportJson 直接透传仓储结果', () async {
      final controller = HistoryController(
        repository: _FakeHistoryRepository([entry('a')]),
      );
      addTearDown(controller.dispose);

      expect(await controller.exportJson(), '[1]');
    });
  });
}
