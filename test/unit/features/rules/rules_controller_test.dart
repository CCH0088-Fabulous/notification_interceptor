import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_set.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_spec.dart';
import 'package:notifinterceptor/src/features/rules/domain/rules_repository.dart';
import 'package:notifinterceptor/src/features/rules/presentation/rules_controller.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_record.dart';
import 'package:notifinterceptor/src/shared/domain/decision.dart';
import 'package:notifinterceptor/src/shared/domain/rule_action.dart';

class _FakeRulesRepository implements RulesRepository {
  _FakeRulesRepository(this._ruleSet);

  RuleSet _ruleSet;
  int saveCount = 0;
  bool failOnSave = false;
  Map<String, dynamic>? lastEvaluateRuleSet;

  @override
  Future<RuleSet> load() async => _ruleSet;

  @override
  Future<RuleSaveResult> save(RuleSet ruleSet) async {
    saveCount++;
    if (failOnSave) throw StateError('save failed');
    _ruleSet = ruleSet;
    return RuleSaveResult(
      ruleSet: ruleSet,
      issues: const [RuleIssue(ruleId: 'x', field: 'id', message: '来自原生')],
    );
  }

  @override
  Future<Decision> evaluate(
    NotificationRecord sample, {
    RuleSet? ruleSet,
  }) async {
    lastEvaluateRuleSet = ruleSet?.toJson();
    return Decision(
      action: ruleSet?.defaultAction ?? RuleAction.allow,
      reason: 'rule',
    );
  }

  @override
  Future<List<String>> seenPackages() async => ['com.a', 'com.b'];
}

void main() {
  group('RulesController', () {
    test('load 后暴露规则并做本地校验', () async {
      final controller = RulesController(
        repository: _FakeRulesRepository(
          const RuleSet(
            rules: [
              RuleSpec(id: 'r1', name: '营销', packages: ['com.a']),
            ],
          ),
        ),
      );
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.ruleSet.rules, hasLength(1));
      expect(controller.issues, isEmpty);
      expect(controller.globalEnabled, isTrue);
    });

    test('upsert 新增与更新都走保存并回写原生 issues', () async {
      final repository = _FakeRulesRepository(const RuleSet());
      final controller = RulesController(repository: repository);
      addTearDown(controller.dispose);
      await controller.load();

      await controller.upsert(
        const RuleSpec(id: 'r1', name: 'a', packages: ['com.a']),
      );
      expect(controller.ruleSet.rules, hasLength(1));
      expect(controller.issues.single.message, '来自原生');

      await controller.upsert(
        const RuleSpec(id: 'r1', name: 'b', packages: ['com.b']),
      );
      expect(controller.ruleSet.rules.single.name, 'b');
      expect(repository.saveCount, 2);
    });

    test('setRuleEnabled 与 remove 更新规则集合', () async {
      final controller = RulesController(
        repository: _FakeRulesRepository(
          const RuleSet(
            rules: [
              RuleSpec(id: 'r1', name: 'a', packages: ['com.a']),
            ],
          ),
        ),
      );
      addTearDown(controller.dispose);
      await controller.load();

      await controller.setRuleEnabled('r1', false);
      expect(controller.ruleSet.rules.single.enabled, isFalse);

      await controller.remove('r1');
      expect(controller.ruleSet.rules, isEmpty);
    });

    test('保存失败时回滚内存修改并记录错误', () async {
      final repository = _FakeRulesRepository(const RuleSet())
        ..failOnSave = true;
      final controller = RulesController(repository: repository);
      addTearDown(controller.dispose);
      await controller.load();

      await controller.upsert(
        const RuleSpec(id: 'r1', name: 'a', packages: ['com.a']),
      );

      expect(controller.ruleSet.rules, isEmpty);
      expect(controller.error, isNotNull);
    });

    test('evaluate 把草稿规则集传给原生引擎', () async {
      final repository = _FakeRulesRepository(const RuleSet());
      final controller = RulesController(repository: repository);
      addTearDown(controller.dispose);

      await controller.evaluate(
        const NotificationRecord(
          key: 'k',
          id: 1,
          packageName: 'com.a',
          postTime: 0,
        ),
        draft: const RuleSpec(id: 'draft', name: 'd', packages: ['com.a']),
      );

      expect(repository.lastEvaluateRuleSet, isNotNull);
      expect(repository.lastEvaluateRuleSet!['rules'], hasLength(1));
    });

    test('整套预览与保存同序，保留规则插入首个移出规则之前', () async {
      final repository = _FakeRulesRepository(
        const RuleSet(
          rules: [
            RuleSpec(
              id: 'keep',
              name: '原保留',
              packages: ['app'],
              action: RuleAction.allow,
            ),
            RuleSpec(id: 'drop', name: '原移出', packages: ['app']),
          ],
        ),
      );
      final controller = RulesController(repository: repository);
      addTearDown(controller.dispose);
      await controller.load();
      final base = controller.ruleSet;
      const rule = RuleSpec(
        id: 'new',
        name: '新保留',
        keywordsAny: ['会议'],
        action: RuleAction.allow,
      );
      await controller.evaluate(
        const NotificationRecord(
          key: 'k',
          id: 1,
          packageName: 'app',
          postTime: 0,
        ),
        draft: rule,
      );
      expect(
        (repository.lastEvaluateRuleSet!['rules'] as List).map((r) => r['id']),
        ['keep', 'new', 'drop'],
      );
      await controller.saveDraft(rule, previewBase: base);
      expect(controller.ruleSet.rules.map((r) => r.id), [
        'keep',
        'new',
        'drop',
      ]);
      expect(controller.ruleSet.toJson(), repository.lastEvaluateRuleSet);
    });

    test('预览后规则变化时拒绝保存，保存失败时向向导报告失败', () async {
      final repository = _FakeRulesRepository(const RuleSet());
      final controller = RulesController(repository: repository);
      addTearDown(controller.dispose);
      await controller.load();
      final base = controller.ruleSet;
      const draft = RuleSpec(id: 'new', name: '新规则', keywordsAny: ['优惠']);
      await controller.setGlobalEnabled(false);
      await expectLater(
        controller.saveDraft(draft, previewBase: base),
        throwsStateError,
      );
      repository.failOnSave = true;
      await expectLater(
        controller.saveDraft(draft, previewBase: controller.ruleSet),
        throwsStateError,
      );
      expect(controller.ruleSet.rules, isEmpty);
      expect(controller.globalEnabled, false);
    });

    test('原生规则在后台被改变时拒绝覆盖并更新镜像', () async {
      final repository = _FakeRulesRepository(const RuleSet());
      final controller = RulesController(repository: repository);
      addTearDown(controller.dispose);
      await controller.load();
      final base = controller.ruleSet;
      await repository.save(
        const RuleSet(
          rules: [
            RuleSpec(id: 'external', name: '外部规则', packages: ['app']),
          ],
        ),
      );
      await expectLater(
        controller.saveDraft(
          const RuleSpec(id: 'new', name: '新规则', keywordsAny: ['优惠']),
          previewBase: base,
        ),
        throwsStateError,
      );
      expect(controller.ruleSet.rules.single.id, 'external');
    });

    test('seenPackages 从仓储读取', () async {
      final controller = RulesController(
        repository: _FakeRulesRepository(const RuleSet()),
      );
      addTearDown(controller.dispose);

      await controller.loadSeenPackages();

      expect(controller.seenPackages, ['com.a', 'com.b']);
    });
  });
}
