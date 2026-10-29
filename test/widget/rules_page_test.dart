import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/shared/domain/rule_action.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_record.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_set.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_spec.dart';
import 'package:notifinterceptor/src/features/rules/domain/rules_repository.dart';
import 'package:notifinterceptor/src/features/rules/presentation/rule_editor_page.dart';
import 'package:notifinterceptor/src/features/rules/presentation/rules_controller.dart';
import 'package:notifinterceptor/src/features/rules/presentation/rules_page.dart';
import 'package:notifinterceptor/src/shared/domain/decision.dart';

class _FakeRulesRepository implements RulesRepository {
  _FakeRulesRepository(this.ruleSet);

  RuleSet ruleSet;

  @override
  Future<RuleSet> load() async => ruleSet;

  @override
  Future<RuleSaveResult> save(RuleSet rules) async {
    ruleSet = rules;
    return RuleSaveResult(ruleSet: rules, issues: const []);
  }

  @override
  Future<Decision> evaluate(
    NotificationRecord sample, {
    RuleSet? ruleSet,
  }) async => const Decision();

  @override
  Future<List<String>> seenPackages() async => const [];
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  setUp(() {
    // 编辑器内容较长，放大测试窗口避免 ListView 只构建首屏。
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets('规则为空时展示引导空态', (tester) async {
    final controller = RulesController(
      repository: _FakeRulesRepository(const RuleSet()),
    );
    addTearDown(controller.dispose);
    await controller.load();

    await tester.pumpWidget(
      _host(RulesPage(controller: controller, onCreate: () {}, onEdit: (_) {})),
    );

    expect(find.text('还没有规则'), findsOneWidget);
    expect(find.text('过滤已开启'), findsOneWidget);
    expect(find.text('新建规则'), findsOneWidget);
  });

  testWidgets('规则列表展示名称、动作与求值顺序说明', (tester) async {
    final controller = RulesController(
      repository: _FakeRulesRepository(
        const RuleSet(
          rules: [
            RuleSpec(id: 'r1', name: '屏蔽营销', packages: ['com.example.shop']),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();

    await tester.pumpWidget(
      _host(RulesPage(controller: controller, onCreate: () {}, onEdit: (_) {})),
    );

    expect(find.text('屏蔽营销'), findsOneWidget);
    expect(find.text('自动移出'), findsWidgets);
    expect(find.textContaining('首条匹配生效'), findsOneWidget);
  });

  testWidgets('筛选保留规则不改变执行编号或持久化顺序', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _FakeRulesRepository(
      const RuleSet(
        rules: [
          RuleSpec(id: 'drop', name: '移出促销', keywordsAny: ['促销']),
          RuleSpec(
            id: 'keep',
            name: '保留会议',
            action: RuleAction.allow,
            keywordsAny: ['会议'],
          ),
          RuleSpec(
            id: 'paused',
            name: '暂停规则',
            enabled: false,
            keywordsAny: ['新闻'],
          ),
          RuleSpec(
            id: 'log',
            name: '日志规则',
            action: RuleAction.logOnly,
            packages: ['app.log'],
          ),
        ],
      ),
    );
    final controller = RulesController(repository: repository);
    addTearDown(controller.dispose);
    await controller.load();
    final before = repository.ruleSet.toJson().toString();
    await tester.pumpWidget(
      _host(RulesPage(controller: controller, onCreate: () {}, onEdit: (_) {})),
    );
    await tester.tap(find.byKey(const ValueKey('filter-keep')));
    await tester.pumpAndSettle();
    expect(find.text('保留会议'), findsOneWidget);
    expect(find.byKey(const ValueKey('rule-drop')), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('ordinal-keep'))).data,
      '2',
    );
    expect(repository.ruleSet.toJson().toString(), before);
    await tester.tap(find.byKey(const ValueKey('filter-disabled')));
    await tester.pumpAndSettle();
    expect(find.text('暂停规则'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('ordinal-paused'))).data,
      '3',
    );
    await tester.tap(find.byKey(const ValueKey('toggle-paused')));
    await tester.pumpAndSettle();
    expect(repository.ruleSet.rules[2].enabled, true);
    expect(find.text('没有已停用规则'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('filter-all')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('日志规则'), 150);
    expect(find.text('仅记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情完整呈现高级条件并将原规则交给编辑器', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const rule = RuleSpec(
      id: 'advanced',
      name: '渠道与正则',
      mode: MatchMode.any,
      packages: ['dev.poc.notifgen'],
      channelIds: ['gen_code_loud', 'custom_channel'],
      titleRegex: '^重要',
      textRegex: '会议.*',
      isOngoing: false,
      isClearable: true,
    );
    final repository = _FakeRulesRepository(const RuleSet(rules: [rule]));
    final controller = RulesController(repository: repository);
    addTearDown(controller.dispose);
    await controller.load();
    RuleSpec? edited;
    await tester.pumpWidget(
      _host(
        RulesPage(
          controller: controller,
          onCreate: () {},
          onEdit: (r) => edited = r,
          appName: (_) => '通知生成器',
        ),
      ),
    );
    await tester.tap(find.text('渠道与正则'));
    await tester.pumpAndSettle();
    expect(find.text('任意一个条件组满足（包括应用范围）'), findsOneWidget);
    expect(find.text('验证码 · 响铃提醒、custom_channel'), findsWidgets);
    final sheet = find.byType(BottomSheet);
    final scroll = find
        .descendant(of: sheet, matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(
      find.text('渠道 ID'),
      150,
      scrollable: scroll,
    );
    expect(find.text('gen_code_loud\ncustom_channel'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('编辑规则'), 200, scrollable: scroll);
    await tester.tap(find.text('编辑规则'));
    await tester.pumpAndSettle();
    expect(edited, same(rule));
    expect(repository.ruleSet.rules.single, same(rule));
    expect(tester.takeException(), isNull);
  });

  testWidgets('长名称与放大字体无溢出，新建入口可用', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = RulesController(
      repository: _FakeRulesRepository(
        const RuleSet(
          rules: [
            RuleSpec(
              id: 'long',
              name: '一条名称很长的跨应用关键词保留规则用于验证窄屏',
              action: RuleAction.allow,
              keywordsAny: ['验证码', '入账', '一个非常长的关键词'],
            ),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    var created = false;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: Scaffold(
            body: RulesPage(
              controller: controller,
              onCreate: () => created = true,
              onEdit: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('新建规则'));
    await tester.pumpAndSettle();
    expect(created, true);
    expect(find.text('应用：所有应用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('规则编辑器对非法正则即时提示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: RuleEditorPage(
          initial: const RuleSpec(id: 'r1', name: '测试'),
          loadPackages: () async => const [],
          loadSamples: () async => const [],
          evaluate: (sample, draft) async => const Decision(),
        ),
      ),
    );

    await tester.enterText(find.widgetWithText(TextField, '标题正则'), '([');
    await tester.pump();

    expect(find.text('正则无效'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
  });

  testWidgets('无条件的规则在编辑器里给出提示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: RuleEditorPage(
          initial: const RuleSpec(id: 'r1', name: '空规则'),
          loadPackages: () async => const [],
          loadSamples: () async => const [],
          evaluate: (sample, draft) async => const Decision(),
        ),
      ),
    );

    expect(find.textContaining('规则没有任何匹配条件'), findsOneWidget);
  });
}
