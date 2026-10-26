import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_set.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_validation.dart';
import 'package:notifinterceptor/src/shared/domain/rule_action.dart';

/// 预设同时被 UI（rootBundle）与 `tool/e2e.ps1`（直接 push 到设备）使用，
/// 这里从磁盘读取同一份文件，保证两者跑的是同一套规则。
const String presetPath = 'assets/presets/generator_triage.json';
const String generatorPackage = 'dev.poc.notifgen';

const List<String> keepChannels = [
  'gen_code',
  'gen_bank',
  'gen_logistics',
  'gen_calendar',
  'gen_chat',
  'gen_group',
];

RuleSet loadPreset() =>
    RuleSet.fromJson(jsonDecode(File(presetPath).readAsStringSync()) as Map<String, dynamic>);

void main() {
  group('生成器分流预设', () {
    test('能解析且无校验告警', () {
      final preset = loadPreset();

      expect(preset.schemaVersion, RuleSet.currentSchemaVersion);
      expect(preset.globalEnabled, isTrue);
      expect(preset.rules, hasLength(4));
      expect(validateRuleSet(preset), isEmpty);
    });

    test('所有规则都限定在生成器包名内，不影响其他应用', () {
      for (final rule in loadPreset().rules) {
        expect(rule.packages, [generatorPackage], reason: '${rule.id} 未限定包名');
      }
    });

    test('白名单覆盖全部应保留渠道，兜底规则排在最后且拦截', () {
      final rules = loadPreset().rules;
      final allowChannels = rules
          .where((rule) => rule.action == RuleAction.allow)
          .expand((rule) => rule.channelIds)
          .toSet();
      expect(allowChannels, containsAll(keepChannels));

      final fallback = rules.last;
      expect(fallback.action, RuleAction.intercept);
      expect(fallback.channelIds, isEmpty);
      expect(fallback.keywordsAny, isEmpty);
      expect(fallback.titleRegex, isNull);
      expect(fallback.textRegex, isNull);
      expect(fallback.isOngoing, isNull);
      expect(fallback.isClearable, isNull);
      expect(fallback.quietHours, isNull);
    });

    test('JSON 往返后规则与顺序不变（原生按顺序首个命中）', () {
      final preset = loadPreset();
      final roundTrip = RuleSet.fromJson(
        jsonDecode(jsonEncode(preset.toJson())) as Map<String, dynamic>,
      );

      expect(roundTrip.rules.map((rule) => rule.id).toList(),
          preset.rules.map((rule) => rule.id).toList());
      expect(roundTrip.rules.map((rule) => rule.action).toList(),
          [RuleAction.allow, RuleAction.allow, RuleAction.allow, RuleAction.intercept]);
    });
  });
}
