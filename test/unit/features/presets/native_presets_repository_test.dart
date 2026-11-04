import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/core/channel/interceptor_channel.dart';
import 'package:notifinterceptor/src/features/presets/data/native_presets_repository.dart';
import 'package:notifinterceptor/src/features/presets/domain/filter_preset.dart';
import 'package:notifinterceptor/src/features/rules/domain/quiet_hours.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methodChannel = MethodChannel('test/presets');
  final channel = InterceptorChannel(methodChannel: methodChannel);
  final repository = NativePresetsRepository(channel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const scene = FilterPreset(
    id: 'sleep',
    name: '睡眠模式',
    kind: PresetKind.scene,
    keywords: ['促销', '游戏'],
    allowKeywords: ['紧急'],
    packages: ['dev.poc.notifgen'],
    quietHours: QuietHours(
      fromMinutes: 22 * 60,
      toMinutes: 8 * 60,
      days: {1, 2, 3, 4, 5, 6, 7},
    ),
  );

  tearDown(() => messenger.setMockMethodCallHandler(methodChannel, null));

  test('真实 StandardMethodCodec 往返能保留嵌套场景时段', () async {
    Map<dynamic, dynamic>? saved;
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      if (call.method == BridgeMethod.savePresets) {
        saved = (call.arguments as Map)['library'] as Map;
        return saved;
      }
      if (call.method == BridgeMethod.getPresets) return saved;
      fail('unexpected method ${call.method}');
    });

    await repository.save([scene]);
    expect(saved?['schemaVersion'], 1);
    expect((saved?['presets'] as List).single, scene.toJson());
    final loaded = await repository.load();
    expect(loaded.single.toJson(), scene.toJson());
  });

  test('空库正确读取；未来版本和错误结构拒绝作为空库加载', () async {
    Map<String, dynamic>? response = {'schemaVersion': 1, 'presets': []};
    messenger.setMockMethodCallHandler(methodChannel, (_) async => response);
    expect(await repository.load(), isEmpty);
    for (final invalid in <Map<String, dynamic>?>[
      null,
      {'schemaVersion': 2, 'presets': []},
      {'schemaVersion': 3, 'presets': [], 'versions': []},
      {'schemaVersion': 1, 'presets': 'not a list'},
      {
        'schemaVersion': 1,
        'presets': [42],
      },
    ]) {
      response = invalid;
      await expectLater(repository.load(), throwsFormatException);
    }
  });

  test('原生读写失败向上传递，不把失败当作空库或成功', () async {
    messenger.setMockMethodCallHandler(methodChannel, (_) async {
      throw PlatformException(code: 'IO_ERROR', message: '预设文件无法访问');
    });
    await expectLater(repository.load(), throwsA(isA<Exception>()));
    await expectLater(repository.save([scene]), throwsA(isA<Exception>()));
  });

  test('v2版本记录跨codec读取，命名版本参数传给原生', () async {
    MethodCall? savedVersion;
    final library = {
      'schemaVersion': 2,
      'presets': [scene.toJson()],
      'versions': [
        {
          'id': 'v1',
          'createdAt': 1793721600000,
          'label': '演示前',
          'preset': scene.toJson(),
        },
      ],
    };
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      if (call.method == BridgeMethod.savePresetVersion) savedVersion = call;
      return library;
    });
    expect((await repository.load()).single.toJson(), scene.toJson());
    final versions = await repository.loadVersions();
    expect(versions.single.preset.quietHours!.days, {1, 2, 3, 4, 5, 6, 7});
    await repository.saveVersion(scene.id, label: '演示前');
    expect(savedVersion!.arguments, {'presetId': scene.id, 'label': '演示前'});
  });

  test('文件选择取消原样返回，导出UTF8文本和文件名传递正确', () async {
    MethodCall? exported;
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      if (call.method == BridgeMethod.importPresetFile) return null;
      if (call.method == BridgeMethod.exportPresetFile) {
        exported = call;
        return false;
      }
      fail('unexpected method');
    });
    expect(await repository.importFile(), isNull);
    expect(
      await repository.exportFile('content', fileName: 'presets.json'),
      false,
    );
    expect(exported!.arguments, {
      'content': 'content',
      'fileName': 'presets.json',
    });
  });
}
