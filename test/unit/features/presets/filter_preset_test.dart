import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/presets/domain/filter_preset.dart';
import 'package:notifinterceptor/src/features/rules/domain/quiet_hours.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_set.dart';

void main() {
  const sleep = FilterPreset(
    id: 'fixture_sleep',
    name: '周五睡眠',
    kind: PresetKind.scene,
    keywords: ['促销', '直播'],
    allowKeywords: ['紧急'],
    packages: ['com.demo.shop'],
    quietHours: QuietHours(fromMinutes: 22 * 60, toMinutes: 8 * 60, days: {5}),
  );

  test('场景编译符合共享原生引擎契约，保留与拦截均限定应用和时段', () {
    final fixture = jsonDecode(
      File('test/fixtures/preset_rules_v1.json').readAsStringSync(),
    );
    expect(RuleSet(rules: sleep.toRules()).toJson(), fixture);
    expect(FilterPreset.fromJson(sleep.toJson()).toJson(), sleep.toJson());
    expect(
      FilterPreset.fromJson({
        ...sleep.toJson(),
        'quietHours': <Object?, Object?>{
          'from': '22:00',
          'to': '08:00',
          'days': [5],
        },
      }).toJson(),
      sleep.toJson(),
    );
    expect(sleep.copyWith(quietHours: null).quietHours, isNull);
  });

  test('拒绝空过滤词、无效时段与空日期，避免损坏数据扩大生效范围', () {
    expect(sleep.copyWith(keywords: []).validate(), isNotEmpty);
    expect(
      sleep
          .copyWith(
            quietHours: const QuietHours(
              fromMinutes: 480,
              toMinutes: 480,
              days: {1},
            ),
          )
          .validate(),
      isNotEmpty,
    );
    expect(
      () => FilterPreset.fromJson({
        ...sleep.toJson(),
        'quietHours': {'from': '22:00', 'to': '08:00', 'days': []},
      }),
      throwsFormatException,
    );
    expect(
      () => FilterPreset.fromJson({
        ...sleep.toJson(),
        'quietHours': {
          'from': '25:00',
          'to': '08:00',
          'days': [1],
        },
      }),
      throwsFormatException,
    );
    expect(
      () => FilterPreset.fromJson({...sleep.toJson(), 'kind': 'unknown'}),
      throwsFormatException,
    );
  });
}
