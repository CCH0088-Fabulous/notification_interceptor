import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/rules/domain/quiet_hours.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_set.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_spec.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_validation.dart';
import 'package:notifinterceptor/src/shared/domain/rule_action.dart';

/// 与 Kotlin `RuleEngineTest` 共用的 JSON 固件，保证两端契约一致。
Map<String, dynamic> loadFixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;

void main() {
  group('RuleSet JSON 契约', () {
    test('a4 能从固件解析规则集并往返一致', () {
      final ruleSet = RuleSet.fromJson(loadFixture('rule_set_v1.json'));

      expect(ruleSet.schemaVersion, RuleSet.currentSchemaVersion);
      expect(ruleSet.globalEnabled, isTrue);
      expect(ruleSet.defaultAction, RuleAction.allow);
      expect(ruleSet.rules, hasLength(1));

      final rule = ruleSet.rules.single;
      expect(rule.id, 'r1');
      expect(rule.action, RuleAction.intercept);
      expect(rule.mode, MatchMode.all);
      expect(rule.packages, ['com.example.shop']);
      expect(rule.keywordsAny, ['秒杀', '红包']);
      expect(rule.titleRegex, '优惠|限时');
      expect(rule.channelIds, ['marketing']);
      expect(rule.isOngoing, isFalse);
      expect(rule.isClearable, isTrue);
      expect(rule.quietHours, isNotNull);
      expect(rule.quietHours!.fromMinutes, 22 * 60);
      expect(rule.quietHours!.toMinutes, 8 * 60);
      expect(rule.quietHours!.days, {1, 2, 3, 4, 5, 6, 7});

      final roundTrip = RuleSet.fromJson(ruleSet.toJson());
      expect(roundTrip.toJson(), ruleSet.toJson());
    });

    test('未知字段与缺失字段不会导致解析失败', () {
      final ruleSet = RuleSet.fromJson({
        'rules': [
          {'id': 'x', 'name': 'n', 'unknown': 1, 'match': {'packages': ['a']}},
        ],
        'futureField': {'a': 1},
      });

      expect(ruleSet.rules.single.id, 'x');
      expect(ruleSet.rules.single.enabled, isTrue);
      expect(ruleSet.schemaVersion, RuleSet.currentSchemaVersion);
    });

    test('空条件组被解析为空列表而不是 null', () {
      final rule = RuleSpec.fromJson({
        'id': 'r',
        'name': 'r',
        'match': {
          'packages': ['', '  '],
          'titleRegex': '   ',
        },
      });

      expect(rule.packages, isEmpty);
      expect(rule.titleRegex, isNull);
      expect(rule.hasAnyCondition, isFalse);
    });
  });

  group('规则静态校验', () {
    test('a4 非法正则被识别', () {
      expect(isValidRegex('([ '), isFalse);
      expect(isValidRegex('优惠|限时'), isTrue);
      expect(isValidRegex('a' * 201), isFalse);
    });

    test('a4 重复 id 与空条件都会产生告警', () {
      final issues = validateRuleSet(
        const RuleSet(
          rules: [
            RuleSpec(id: 'dup', name: 'a', packages: ['com.a']),
            RuleSpec(id: 'dup', name: 'b', packages: ['com.b']),
            RuleSpec(id: 'empty', name: 'c'),
            RuleSpec(id: 'bad-regex', name: 'd', titleRegex: '(['),
          ],
        ),
      );

      expect(issues.any((issue) => issue.message.contains('重复')), isTrue);
      expect(issues.any((issue) => issue.ruleId == 'empty'), isTrue);
      expect(issues.any((issue) => issue.field == 'titleRegex'), isTrue);
    });

    test('静默时段起止相同会告警', () {
      final issues = validateRuleSet(
        const RuleSet(
          rules: [
            RuleSpec(
              id: 'q',
              name: 'q',
              quietHours: QuietHours(fromMinutes: 60, toMinutes: 60, days: {1}),
            ),
          ],
        ),
      );

      expect(issues.single.field, 'quietHours');
    });

    test('逗号与换行输入解析为去重列表', () {
      expect(parseListInput(' a, b\nc，a '), ['a', 'b', 'c']);
    });
  });

  group('QuietHours 判定与原生一致', () {
    test('跨天区间按起始日判定', () {
      const quiet = QuietHours(
        fromMinutes: 22 * 60,
        toMinutes: 8 * 60,
        days: {1, 2, 3, 4, 5, 6, 7},
      );

      expect(quiet.matches(DateTime(2026, 10, 17, 23, 30).millisecondsSinceEpoch), isTrue);
      expect(quiet.matches(DateTime(2026, 10, 18, 2, 0).millisecondsSinceEpoch), isTrue);
      expect(quiet.matches(DateTime(2026, 10, 17, 12, 0).millisecondsSinceEpoch), isFalse);
    });

    test('只包含周六起点时，周六夜间命中、周一夜间不命中', () {
      const quiet = QuietHours(
        fromMinutes: 22 * 60,
        toMinutes: 8 * 60,
        days: {6},
      );

      expect(quiet.matches(DateTime(2026, 10, 17, 23, 0).millisecondsSinceEpoch), isTrue);
      expect(quiet.matches(DateTime(2026, 10, 19, 23, 0).millisecondsSinceEpoch), isFalse);
    });

    test('同日起止为空窗口', () {
      const quiet = QuietHours(fromMinutes: 60, toMinutes: 60, days: {1, 2, 3, 4, 5, 6, 7});
      expect(quiet.matches(DateTime(2026, 10, 17, 1, 30).millisecondsSinceEpoch), isFalse);
    });
  });
}
