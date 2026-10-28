import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_spec.dart';
import 'package:notifinterceptor/src/features/rules/domain/simple_rule_draft.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_topic.dart';
import 'package:notifinterceptor/src/shared/domain/rule_action.dart';

void main() {
  test('所有应用关键词：不填包名，使用原有关键词字段', () {
    final rule = const SimpleRuleDraft(
      id: 'a',
      keywords: [' 优惠 ', '优惠', 'SALE', 'sale'],
    ).toRule(scopeLabel: '所有应用');
    expect(rule.packages, isEmpty);
    expect(rule.keywordsAny, ['优惠', 'SALE']);
    expect(rule.mode, MatchMode.all);
    expect(rule.titleRegex, isNull);
  });
  test('指定应用与词同时满足，不能退化成 OR', () {
    final rule = const SimpleRuleDraft(
      id: 'a',
      allApps: false,
      packages: ['dev.poc.notifgen'],
      keywords: ['秒杀'],
    ).toRule(scopeLabel: '通知生成器');
    expect(rule.packages, ['dev.poc.notifgen']);
    expect(rule.keywordsAny, ['秒杀']);
    expect(rule.mode, MatchMode.all);
  });
  test('只有显式选择指定应用的全部通知才允许空关键词', () {
    expect(
      const SimpleRuleDraft(id: 'a', allNotifications: true).validationMessage,
      isNotNull,
    );
    expect(const SimpleRuleDraft(id: 'a').validationMessage, isNotNull);
    expect(
      const SimpleRuleDraft(
        id: 'a',
        allApps: false,
        keywords: ['词'],
      ).validationMessage,
      isNotNull,
    );
    final rule = const SimpleRuleDraft(
      id: 'a',
      allApps: false,
      packages: ['app'],
      allNotifications: true,
      keywords: ['残留草稿'],
    ).toRule(scopeLabel: '应用');
    expect(rule.keywordsAny, isEmpty);
    expect(rule.packages, ['app']);
  });
  test('缺失应用身份不能创建全部通知规则', () {
    expect(
      const SimpleRuleDraft(
        id: 'a',
        allApps: false,
        packages: ['  '],
        allNotifications: true,
      ).validationMessage,
      isNotNull,
    );
  });
  test('主题只展开成可编辑关键词，保留动作及旧停用状态', () {
    final words = RuleTopic.suggestions.first.keywords;
    final rule = SimpleRuleDraft(
      id: 'a',
      name: '自定义',
      keywords: words,
      action: RuleAction.allow,
      enabled: false,
    ).toRule(scopeLabel: '所有应用');
    expect(rule.keywordsAny, words);
    expect(rule.name, '自定义');
    expect(rule.action, RuleAction.allow);
    expect(rule.enabled, false);
  });
  test('生成器渠道预设及正则/OR规则不能进入有损的简化编辑', () {
    const base = RuleSpec(id: 'a', name: '预设', packages: ['dev.poc.notifgen']);
    expect(
      SimpleRuleDraft.canEdit(base.copyWith(channelIds: ['gen_code'])),
      false,
    );
    expect(SimpleRuleDraft.canEdit(base.copyWith(titleRegex: 'abc')), false);
    expect(SimpleRuleDraft.canEdit(base.copyWith(mode: MatchMode.any)), false);
    expect(SimpleRuleDraft.canEdit(base), true);
  });
}
