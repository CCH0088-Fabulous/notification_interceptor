import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
  Future<Decision> evaluate(NotificationRecord sample, {RuleSet? ruleSet}) async =>
      const Decision();

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
    final controller = RulesController(repository: _FakeRulesRepository(const RuleSet()));
    addTearDown(controller.dispose);
    await controller.load();

    await tester.pumpWidget(
      _host(RulesPage(controller: controller, onCreate: () {}, onEdit: (_) {})),
    );

    expect(find.text('还没有规则'), findsOneWidget);
    expect(find.text('启用规则引擎'), findsOneWidget);
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
    expect(find.text('拦截'), findsWidgets);
    expect(find.textContaining('首个命中即停止'), findsOneWidget);
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
