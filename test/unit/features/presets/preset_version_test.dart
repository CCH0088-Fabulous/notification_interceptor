import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/presets/domain/filter_preset.dart';
import 'package:notifinterceptor/src/features/presets/domain/preset_version.dart';

void main() {
  final raw = <String, dynamic>{
    'id': 'version_123-456',
    'createdAt': 1793722939325,
    'label': '修改前',
    'preset': <Object?, Object?>{
      ...FilterPreset.examples.last.toJson(),
      'quietHours': <Object?, Object?>{
        'from': '22:00',
        'to': '08:00',
        'days': [1, 2, 3],
      },
    },
  };

  test('真实 codec 的嵌套 Map 能解析完整版本且可序列化回 JSON', () {
    final version = PresetVersion.fromJson(raw);
    expect(version.preset.quietHours!.days, {1, 2, 3});
    expect(version.createdAt, 1793722939325);
    expect(PresetVersion.fromJson(version.toJson()).toJson(), version.toJson());
    expect(
      () => version.preset.quietHours!.days.add(4),
      throwsUnsupportedError,
    );
  });

  test('拒绝损坏元数据和不能显示的时间，保留严格词库校验', () {
    for (final changes in <Map<String, dynamic>>[
      {'id': 'bad.id'},
      {'createdAt': 0},
      {'createdAt': 1793722939325.0},
      {'createdAt': 8640000000000001},
      {'label': ''},
      {'label': ' 未修剪 '},
      {
        'preset': {'id': 'bad'},
      },
      {
        'preset': <Object?, Object?>{1: 'not string key'},
      },
    ]) {
      expect(
        () => PresetVersion.fromJson({...raw, ...changes}),
        throwsFormatException,
      );
    }
  });
}
