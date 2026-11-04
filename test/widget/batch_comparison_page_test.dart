import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/app/theme.dart';
import 'package:notifinterceptor/src/features/comparison/domain/comparison_models.dart';
import 'package:notifinterceptor/src/features/comparison/presentation/batch_comparison_controller.dart';
import 'package:notifinterceptor/src/features/comparison/presentation/batch_comparison_page.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_record.dart';
import 'package:notifinterceptor/src/features/history/domain/history_entry.dart';
import 'package:notifinterceptor/src/features/presets/domain/filter_preset.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_set.dart';
import 'package:notifinterceptor/src/shared/domain/decision.dart';
import 'package:notifinterceptor/src/shared/domain/rule_action.dart';

const _marketing = FilterPreset(
  id: 'marketing',
  name: '减少营销',
  keywords: ['优惠'],
);
const _sleep = FilterPreset(
  id: 'sleep',
  name: '睡眠',
  kind: PresetKind.scene,
  keywords: ['直播'],
);

BatchComparisonResult _result({bool empty = false, bool warnings = false}) =>
    BatchComparisonResult(
      target: _marketing,
      rows: empty
          ? []
          : [
              const BatchComparisonRow(
                entry: HistoryEntry(
                  id: 'action-change',
                  timestamp: 1793740000000,
                  record: NotificationRecord(
                    key: 'one',
                    id: 1,
                    packageName: 'com.shop',
                    appLabel: '商城',
                    postTime: 1793740000000,
                    title: '限时优惠开始',
                    text: '今日促销',
                  ),
                  action: RuleAction.allow,
                ),
                before: Decision(),
                after: Decision(
                  action: RuleAction.intercept,
                  ruleId: 'new',
                  ruleName: '营销过滤',
                  reason: 'rule',
                ),
              ),
              const BatchComparisonRow(
                entry: HistoryEntry(
                  id: 'rule-change',
                  timestamp: 1793740000001,
                  record: NotificationRecord(
                    key: 'two',
                    id: 2,
                    packageName: 'com.chat',
                    appLabel: '聊天',
                    postTime: 1793740000001,
                    title: '紧急消息',
                    text: '请及时回复',
                  ),
                  action: RuleAction.allow,
                ),
                before: Decision(
                  ruleId: 'old-keep',
                  ruleName: '原保留规则',
                  reason: 'rule',
                ),
                after: Decision(
                  ruleId: 'new-keep',
                  ruleName: '新保留规则',
                  reason: 'rule',
                ),
              ),
            ],
      beforeRules: RuleSet.empty,
      afterRules: RuleSet.empty,
      generatedAt: 1793740100000,
      zoneId: 'Asia/Shanghai',
      period: ComparisonPeriod.all,
      limit: 1000,
      sourceCount: empty ? 0 : 3,
      skippedSummaries: empty ? 0 : 1,
      baseIssues: warnings
          ? const [
              RuleIssue(
                ruleId: 'invalid',
                field: 'titleRegex',
                message: '标题正则无效',
              ),
            ]
          : const [],
    );

/// The page is tested independently of channel and persistence. Unexpected
/// controller calls fail through noSuchMethod instead of writing live rules.
class _Controller extends ChangeNotifier implements BatchComparisonController {
  @override
  List<FilterPreset> presets = [_marketing, _sleep];
  @override
  bool loading = false;
  @override
  String? error;
  @override
  BatchComparisonResult? result;
  @override
  bool isStale = false;
  BatchComparisonResult nextResult = _result();
  int runs = 0;
  int exports = 0;
  bool exportCancelled = true;
  String? lastPreset;
  int? lastLimit;
  ComparisonPeriod? lastPeriod;

  @override
  Future<void> run({
    required String presetId,
    ComparisonPeriod period = ComparisonPeriod.all,
    int limit = 1000,
  }) async {
    runs++;
    lastPreset = presetId;
    lastLimit = limit;
    lastPeriod = period;
    result = nextResult;
    error = null;
    isStale = false;
    notifyListeners();
  }

  @override
  Future<bool> exportFile() async {
    exports++;
    return !exportCancelled;
  }

  void failAndRetain() {
    error = '历史读取失败';
    isStale = true;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Controller controller;
  setUp(() => controller = _Controller());
  tearDown(() => controller.dispose());

  Future<void> open(WidgetTester tester, {double textScale = 1}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(),
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(390, 844),
            textScaler: TextScaler.linear(textScale),
          ),
          child: BatchComparisonPage(
            controller: controller,
            initialPresetId: _marketing.id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.dragUntilVisible(
      finder,
      find.byType(ListView),
      const Offset(0, -250),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('运行批量对比显示快照，动作和仅规则变化可分别筛选', (tester) async {
    await open(tester);
    await reveal(tester, find.byKey(const Key('comparison-run')));
    await tester.tap(find.byKey(const Key('comparison-run')));
    await tester.pumpAndSettle();
    expect(controller.runs, 1);
    expect(controller.lastPreset, 'marketing');
    expect(controller.lastPeriod, ComparisonPeriod.all);
    expect(controller.lastLimit, 1000);
    await reveal(tester, find.byKey(const Key('comparison-sample-count')));
    expect(find.textContaining('实际比较 2 条记录'), findsOneWidget);
    await reveal(tester, find.byKey(const Key('comparison-filter-action')));
    await tester.tap(find.byKey(const Key('comparison-filter-action')));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const Key('comparison-row-action-change')));
    expect(
      find.byKey(const Key('comparison-row-action-change')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('comparison-row-rule-change')), findsNothing);
    await reveal(tester, find.byKey(const Key('comparison-filter-ruleOnly')));
    await tester.tap(find.byKey(const Key('comparison-filter-ruleOnly')));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const Key('comparison-row-rule-change')));
    expect(find.text('紧急消息'), findsOneWidget);
    expect(find.byKey(const Key('comparison-row-action-change')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('调整选择不改旧结果标题；失败保留上次结果并禁用导出', (tester) async {
    controller.result = _result();
    await open(tester);
    await tester.tap(find.byKey(const Key('comparison-preset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('睡眠 · 场景预设').last);
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const Key('comparison-stale')));
    expect(find.textContaining('下面仍是「减少营销」'), findsOneWidget);
    await reveal(tester, find.byKey(const Key('comparison-export')));
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('comparison-export')))
          .onPressed,
      isNull,
    );
    controller.failAndRetain();
    await tester.pumpAndSettle();
    // The failure note is above the export card we just inspected. Rewind the
    // outer list before searching downwards; lazy children above the cache are
    // otherwise absent and dragUntilVisible keeps scrolling the wrong way.
    tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position
        .jumpTo(0);
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const Key('comparison-stale')));
    expect(find.textContaining('最近一次对比未完成'), findsOneWidget);
    expect(controller.result!.target.id, _marketing.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空样本与校验提示可读，导出取消后可重试', (tester) async {
    controller.result = _result(empty: true, warnings: true);
    await open(tester, textScale: 1.5);
    await reveal(tester, find.byKey(const Key('comparison-export')));
    expect(find.textContaining('此范围内没有可比较'), findsOneWidget);
    await tester.tap(find.byKey(const Key('comparison-export')));
    await tester.pumpAndSettle();
    expect(controller.exports, 1);
    expect(find.textContaining('JSON 已保存'), findsNothing);
    controller.exportCancelled = false;
    await tester.tap(find.byKey(const Key('comparison-export')));
    await tester.pumpAndSettle();
    expect(controller.exports, 2);
    expect(find.textContaining('JSON 已保存'), findsOneWidget);
    await reveal(tester, find.byKey(const Key('comparison-warnings')));
    await tester.tap(find.byKey(const Key('comparison-warnings')));
    await tester.pumpAndSettle();
    expect(find.textContaining('标题正则无效'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
