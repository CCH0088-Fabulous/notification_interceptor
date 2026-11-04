import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/presets/domain/filter_preset.dart';
import 'package:notifinterceptor/src/features/presets/domain/preset_transfer.dart';
import 'package:notifinterceptor/src/features/rules/domain/quiet_hours.dart';

void main() {
  const original = FilterPreset(
    id: 'existing',
    name: '工作',
    kind: PresetKind.scene,
    keywords: ['促销'],
    allowKeywords: ['会议'],
    quietHours: QuietHours(fromMinutes: 540, toMinutes: 1080, days: {1, 2}),
  );
  const added = FilterPreset(id: 'new', name: '工作', keywords: ['直播']);

  test('portable 文件只保存当前预设并完整往返跨天与中文内容', () {
    final raw = PresetTransfer.encode([original, added]);
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    expect(decoded.keys.toSet(), {'schemaVersion', 'presets'});
    expect(PresetTransfer.decode(raw).map((p) => p.toJson()), [
      original.toJson(),
      added.toJson(),
    ]);
    expect(
      PresetTransfer.decode('\uFEFF$raw').first.toJson(),
      original.toJson(),
    );
    expect(PresetTransfer.decode(PresetTransfer.encode([])), isEmpty);
  });

  test('同 id 默认跳过，确认更新后原位替换，同名不同 id 保留', () {
    final edited = original.copyWith(keywords: ['游戏']);
    final raw = PresetTransfer.encode([edited, added]);
    final plan = PresetTransfer.preview(raw, [original]);
    expect(plan.duplicateIds, ['existing']);
    expect(plan.addedCount, 1);
    expect(plan.updatedCount, 1);
    expect(plan.merge([original]).map((p) => p.toJson()), [
      original.toJson(),
      added.toJson(),
    ]);
    expect(
      plan.merge([original], replaceExisting: true).map((p) => p.toJson()),
      [edited.toJson(), added.toJson()],
    );
  });

  test('预览期间词库变化时拒绝导入；预览本身不受源列表后续修改影响', () {
    final words = ['优惠'];
    final days = {1, 2};
    final mutable = original.copyWith(
      keywords: words,
      quietHours: original.quietHours!.copyWith(days: days),
    );
    final plan = PresetTransfer.preview(PresetTransfer.encode([added]), [
      mutable,
    ]);
    words.add('新品');
    days.add(3);
    expect(() => plan.merge([mutable]), throwsStateError);
    expect(
      plan.merge([
        original.copyWith(keywords: ['优惠']),
      ]),
      hasLength(2),
    );
    expect(() => plan.presets.add(original), throwsUnsupportedError);
    expect(
      () => plan.presets.single.keywords.add('外部修改'),
      throwsUnsupportedError,
    );
  });

  test('合并超限整体拒绝，不静默截断导入内容', () {
    final existing = List.generate(
      100,
      (index) => original.copyWith(id: 'p_$index'),
    );
    final plan = PresetTransfer.preview(
      PresetTransfer.encode([added]),
      existing,
    );
    expect(() => plan.merge(existing), throwsFormatException);
    expect(existing, hasLength(100));
  });

  test('拒绝损坏、内部版本库、重复 id、空词、未知类型与非法时段', () {
    for (final raw in [
      '',
      'not json',
      '[]',
      '{"schemaVersion":2,"presets":[],"versions":[]}',
      '{"schemaVersion":1,"presets":[],"versions":[]}',
      '{"schemaVersion":1,"presets":[],"rules":[]}',
      '{"schemaVersion":1,"presets":{}}',
      jsonEncode({
        'schemaVersion': 1,
        'presets': [original.toJson(), original.toJson()],
      }),
      jsonEncode({
        'schemaVersion': 1,
        'presets': [
          {...original.toJson(), 'keywords': []},
        ],
      }),
      jsonEncode({
        'schemaVersion': 1,
        'presets': [
          {...original.toJson(), 'kind': 'unknown'},
        ],
      }),
      jsonEncode({
        'schemaVersion': 1,
        'presets': [
          {
            ...original.toJson(),
            'quietHours': {'from': '22:00', 'to': '08:00', 'days': []},
          },
        ],
      }),
    ]) {
      expect(
        () => PresetTransfer.decode(raw),
        throwsFormatException,
        reason: raw,
      );
    }
  });

  test('2 MiB 限制按 UTF-8 字节计算，同时限制输入与输出', () {
    final raw = jsonEncode({
      'schemaVersion': 1,
      'presets': [],
      'padding': '中' * 700000,
    });
    expect(raw.length, lessThan(PresetTransfer.maxBytes));
    expect(() => PresetTransfer.decode(raw), throwsFormatException);
    final presets = List.generate(
      100,
      (index) => FilterPreset(
        id: 'big_$index',
        name: '较大词库',
        keywords: List.generate(100, (word) => '中' * 100),
      ),
    );
    expect(() => PresetTransfer.encode(presets), throwsFormatException);
  });
}
