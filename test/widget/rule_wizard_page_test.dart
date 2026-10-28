import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_record.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_set.dart';
import 'package:notifinterceptor/src/features/rules/domain/rules_repository.dart';
import 'package:notifinterceptor/src/features/rules/presentation/rules_controller.dart';
import 'package:notifinterceptor/src/features/rules/presentation/rule_wizard_page.dart';
import 'package:notifinterceptor/src/shared/domain/decision.dart';

class _Repository implements RulesRepository {
  RuleSet saved = RuleSet.empty;
  RuleSet? preview;
  bool fail = false;
  @override
  Future<RuleSet> load() async => saved;
  @override
  Future<RuleSaveResult> save(RuleSet set) async {
    if (fail) throw StateError('disk error');
    saved = set;
    return RuleSaveResult(ruleSet: set, issues: const []);
  }

  @override
  Future<List<String>> seenPackages() async => ['dev.poc.notifgen'];
  @override
  Future<Decision> evaluate(
    NotificationRecord sample, {
    RuleSet? ruleSet,
  }) async {
    preview = ruleSet;
    return const Decision();
  }
}

void main() {
  Future<_Repository> open(WidgetTester tester, {bool empty = false}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repository = _Repository();
    final controller = RulesController(repository: repository);
    addTearDown(controller.dispose);
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(
        home: RuleWizardPage(
          controller: controller,
          loadPackages: () async => ['dev.poc.notifgen'],
          loadSamples: () async => empty
              ? []
              : [
                  const NotificationRecord(
                    key: 'k',
                    id: 1,
                    packageName: 'dev.poc.notifgen',
                    appLabel: '通知生成器',
                    postTime: 1,
                    title: '限时秒杀',
                  ),
                ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    return repository;
  }

  Future<void> next(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pumpAndSettle();
  }

  testWidgets('跨应用关键词流程、空值阻挡和整套原生预览调用', (tester) async {
    final repo = await open(tester);
    expect(find.text('所有应用'), findsOneWidget);
    expect(find.text('dev.poc.notifgen'), findsNothing);
    await next(tester);
    await next(tester);
    expect(find.byKey(const Key('wizard-error')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('keyword-input')), ' 秒杀 ');
    await next(tester); // 未按回车的最后一个词也纳入规则。
    expect(find.byKey(const Key('rule-summary')), findsOneWidget);
    expect(repo.preview!.rules.single.packages, isEmpty);
    expect(repo.preview!.rules.single.keywordsAny, ['秒杀']);
    expect(tester.takeException(), isNull);
  });
  testWidgets('指定应用未选时禁用下一步；全应用范围不可创建全量规则', (tester) async {
    await open(tester);
    await tester.tap(find.text('指定应用'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('wizard-next')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('通知生成器'));
    await next(tester);
    await tester.scrollUntilVisible(
      find.text('所选应用的全部通知'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('所选应用的全部通知'), findsOneWidget);
    await tester.tap(find.text('所选应用的全部通知'));
    await next(tester);
    expect(find.textContaining('的全部新通知'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('主题词可删除；没有真实样本需明确确认，失败不关闭页面', (tester) async {
    final repo = await open(tester, empty: true);
    await next(tester);
    await tester.ensureVisible(find.text('促销购物'));
    await tester.tap(find.text('促销购物'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, '秒杀'), findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(InputChip, '秒杀'));
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(InputChip, '秒杀'),
        matching: find.byTooltip('Delete'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, '秒杀'), findsNothing);
    await next(tester);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('wizard-next')))
          .onPressed,
      isNull,
    );
    await tester.ensureVisible(find.text('没有样本，仍保存规则'));
    await tester.tap(find.text('没有样本，仍保存规则'));
    await tester.pumpAndSettle();
    repo.fail = true;
    await next(tester);
    expect(find.text('保存失败，请重试'), findsOneWidget);
    expect(repo.saved.rules, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
