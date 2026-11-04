import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/comparison/domain/comparison_models.dart';
import 'package:notifinterceptor/src/features/comparison/domain/comparison_repository.dart';
import 'package:notifinterceptor/src/features/comparison/presentation/batch_comparison_controller.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_record.dart';
import 'package:notifinterceptor/src/features/history/domain/history_entry.dart';
import 'package:notifinterceptor/src/features/history/domain/history_query.dart';
import 'package:notifinterceptor/src/features/history/domain/history_repository.dart';
import 'package:notifinterceptor/src/features/history/presentation/history_controller.dart';
import 'package:notifinterceptor/src/features/presets/domain/filter_preset.dart';
import 'package:notifinterceptor/src/features/presets/domain/preset_version.dart';
import 'package:notifinterceptor/src/features/presets/domain/presets_repository.dart';
import 'package:notifinterceptor/src/features/presets/presentation/presets_controller.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_set.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_spec.dart';
import 'package:notifinterceptor/src/features/rules/domain/rules_repository.dart';
import 'package:notifinterceptor/src/features/rules/presentation/rules_controller.dart';
import 'package:notifinterceptor/src/shared/domain/decision.dart';
import 'package:notifinterceptor/src/shared/domain/rule_action.dart';

class _Rules implements RulesRepository {
  RuleSet value = const RuleSet(
    rules: [
      RuleSpec(
        id: 'manual',
        name: '手动',
        keywordsAny: ['紧急'],
        action: RuleAction.allow,
      ),
    ],
  );
  int writes = 0;
  @override
  Future<RuleSet> load() async => value;
  @override
  Future<RuleSaveResult> save(RuleSet set) async {
    writes++;
    value = set;
    return RuleSaveResult(ruleSet: value, issues: []);
  }

  @override
  Future<Decision> evaluate(NotificationRecord sample, {RuleSet? ruleSet}) =>
      throw UnimplementedError();
  @override
  Future<List<String>> seenPackages() async => [];
}

class _Library implements PresetsRepository {
  List<FilterPreset> items = [
    FilterPreset.examples.first.copyWith(id: 'target'),
  ];
  int writes = 0;
  bool failLoad = false;
  @override
  Future<List<FilterPreset>> load() async {
    if (failLoad) throw StateError('bad library');
    return items;
  }

  @override
  Future<void> save(List<FilterPreset> presets) async {
    writes++;
    items = List.of(presets);
  }

  @override
  Future<List<PresetVersion>> loadVersions() async => [];
  @override
  Future<void> saveVersion(String presetId, {String? label}) async {}
  @override
  Future<String?> importFile() async => null;
  @override
  Future<bool> exportFile(String content, {required String fileName}) async =>
      false;
}

class _History implements HistoryRepository {
  List<HistoryEntry> items = [];
  bool failLoad = false;
  int clears = 0;
  int queryCount = 0;
  final List<Completer<List<HistoryEntry>>> gates = [];
  @override
  Future<List<HistoryEntry>> query(HistoryQuery query) async {
    queryCount++;
    if (failLoad) throw StateError('bad history');
    if (gates.isNotEmpty) return gates.removeAt(0).future;
    return items;
  }

  @override
  Future<HistoryStats> stats() async => HistoryStats(total: items.length);
  @override
  Future<void> clear() async {
    clears++;
  }

  @override
  Future<String> exportJson() async => '[]';
}

class _Comparison implements ComparisonRepository {
  RuleSet? base;
  RuleSet? candidate;
  List<HistoryEntry> samples = [];
  Completer<void>? gate;
  bool fail = false;
  bool wrongOrder = false;
  int calls = 0;
  String? exported;
  @override
  Future<ComparisonEvaluation> compare({
    required RuleSet base,
    required RuleSet candidate,
    required List<HistoryEntry> samples,
  }) async {
    calls++;
    this.base = base;
    this.candidate = candidate;
    this.samples = samples;
    if (gate != null) await gate!.future;
    if (fail) throw StateError('comparison failed');
    return ComparisonEvaluation(
      evaluatedAt: 1793750400000,
      zoneId: 'Asia/Shanghai',
      rows: samples
          .map(
            (e) => ComparisonDecisionPair(
              entryId: wrongOrder ? 'wrong' : e.id,
              before: const Decision(),
              after: const Decision(
                action: RuleAction.intercept,
                ruleId: 'predicted',
                ruleName: '预测规则',
                reason: 'rule',
              ),
            ),
          )
          .toList(),
    );
  }

  @override
  Future<bool> exportFile(String content, {required String fileName}) async {
    exported = content;
    return false;
  }
}

HistoryEntry _entry(String id, DateTime at, {bool summary = false}) =>
    HistoryEntry(
      id: id,
      timestamp: at.millisecondsSinceEpoch,
      action: RuleAction.intercept,
      cancelStatus: id == 'old' ? CancelStatus.success : CancelStatus.failed,
      record: NotificationRecord(
        key: 'same-notification',
        id: 1,
        packageName: 'demo.app',
        postTime: 1,
        title: '限时优惠',
        isGroupSummary: summary,
        extras: const {'private': 'not exported'},
      ),
    );

void main() {
  final now = DateTime(2026, 11, 4, 12);
  late _Rules rulesRepo;
  late _Library library;
  late _History historyRepo;
  late _Comparison repository;
  late RulesController rules;
  late PresetsController presets;
  late HistoryController history;
  late BatchComparisonController controller;
  setUp(() async {
    rulesRepo = _Rules();
    library = _Library();
    historyRepo = _History();
    repository = _Comparison();
    rules = RulesController(repository: rulesRepo);
    presets = PresetsController(repository: library, rules: rules);
    history = HistoryController(repository: historyRepo);
    controller = BatchComparisonController(
      repository: repository,
      rules: rules,
      presets: presets,
      history: history,
      now: () => now,
    );
    await rules.load();
    await presets.load();
    historyRepo.items = [
      _entry('old', now.subtract(const Duration(days: 1))),
      _entry('summary', now, summary: true),
      _entry('new', now.subtract(const Duration(hours: 1))),
    ];
  });
  tearDown(() {
    controller.dispose();
    presets.dispose();
    rules.dispose();
    history.dispose();
  });

  test('只读采样排除汇总、保留同通知的多个处理事件，并使用完整规则快照', () async {
    final original = jsonEncode(rulesRepo.value.toJson());
    await controller.run(presetId: 'target');
    expect(controller.error, isNull);
    expect(repository.samples.map((e) => e.id), ['new', 'old']);
    expect(repository.samples.map((e) => e.timestamp), [
      now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
      now.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
    ]);
    expect(controller.result!.sourceCount, 3);
    expect(controller.result!.skippedSummaries, 1);
    expect(controller.result!.moreInterceptedCount, 2);
    expect(
      controller.result!.toJson()['summary']['historicalConfirmedRemoved'],
      1,
    );
    expect(rulesRepo.writes, 0);
    expect(library.writes, 0);
    expect(historyRepo.clears, 0);
    expect(jsonEncode(rulesRepo.value.toJson()), original);
    expect(repository.base!.toJson(), rulesRepo.value.toJson());
    final exported = jsonDecode(controller.exportJson());
    expect(exported['kind'], 'notification_batch_comparison');
    expect(
      (exported['rows'] as List).every(
        (r) => !(r['record'] as Map).containsKey('extras'),
      ),
      true,
    );
  });

  test('日期范围、最新数量限制和空样本按所选范围处理', () async {
    historyRepo.items.add(_entry('future', now.add(const Duration(days: 2))));
    await controller.run(
      presetId: 'target',
      period: ComparisonPeriod.today,
      limit: 1,
    );
    expect(repository.samples.map((e) => e.id), ['new']);
    expect(controller.result!.sourceCount, 2);
    historyRepo.items = [];
    await controller.run(presetId: 'target');
    expect(controller.result!.sampleCount, 0);
    expect(controller.error, isNull);
    await controller.run(presetId: 'target', limit: 1001);
    expect(controller.error, isNotNull);
    expect(controller.isStale, true);
  });

  test('历史读取被较新请求取代时，不把旧窗口当作对比成功', () async {
    final first = Completer<List<HistoryEntry>>();
    final second = Completer<List<HistoryEntry>>();
    historyRepo.gates.addAll([first, second]);
    final running = controller.run(presetId: 'target');
    while (historyRepo.queryCount == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    final newer = history.load();
    while (historyRepo.queryCount < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    first.complete(historyRepo.items);
    await running;
    expect(repository.calls, 0);
    expect(controller.result, isNull);
    expect(controller.error, contains('重新读取'));
    second.complete([]);
    await newer;
  });

  test('场景预览与实际确认切换使用同一完整规则变换', () async {
    final work = FilterPreset.examples[1].copyWith(id: 'work');
    final sleep = FilterPreset.examples[2].copyWith(id: 'sleep');
    await presets.save(work);
    await presets.save(sleep);
    await presets.apply(library.items.first);
    await presets.apply(work);
    final writesBefore = rulesRepo.writes;
    await controller.run(presetId: 'sleep');
    expect(rulesRepo.writes, writesBefore);
    expect(controller.result!.afterRules.rules.any(work.ownsRule), false);
    expect(
      controller.result!.afterRules.rules.any(library.items.first.ownsRule),
      true,
    );
    final preview = controller.result!.afterRules.toJson();
    await presets.apply(sleep);
    expect(rulesRepo.value.toJson(), preview);
    expect(controller.isStale, true);
    expect(() => controller.exportJson(), throwsStateError);
  });

  test('比较途中配置改变时保留快照并标记过期，不能导出为当前结果', () async {
    repository.gate = Completer<void>();
    final running = controller.run(presetId: 'target');
    while (repository.calls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await rules.setGlobalEnabled(false);
    repository.gate!.complete();
    await running;
    expect(controller.result!.beforeRules.globalEnabled, true);
    expect(controller.result!.afterRules.globalEnabled, true);
    expect(controller.isStale, true);
    expect(() => controller.exportJson(), throwsStateError);
  });

  test('读取或计算失败保留上次结果，错误/顺序错乱不能生成新成功报告', () async {
    await controller.run(presetId: 'target');
    final previous = controller.result;
    historyRepo.failLoad = true;
    await controller.run(presetId: 'target');
    expect(controller.result, same(previous));
    expect(controller.isStale, true);
    expect(repository.calls, 1);
    historyRepo.failLoad = false;
    repository.fail = true;
    await controller.run(presetId: 'target');
    expect(controller.result, same(previous));
    expect(controller.error, isNotNull);
    repository.fail = false;
    repository.wrongOrder = true;
    await controller.run(presetId: 'target');
    expect(controller.result, same(previous));
    expect(controller.error, contains('顺序'));
  });

  test('全局关闭保留进两套配置，文件取消不改变规则或历史', () async {
    await rules.setGlobalEnabled(false);
    await controller.run(presetId: 'target');
    expect(repository.base!.globalEnabled, false);
    expect(repository.candidate!.globalEnabled, false);
    final writes = rulesRepo.writes;
    expect(await controller.exportFile(), false);
    expect(repository.exported, isNotNull);
    expect(rulesRepo.writes, writes);
    expect(historyRepo.clears, 0);
  });
}
