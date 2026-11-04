import '../../../core/channel/interceptor_channel.dart';
import '../../../core/util/json_cast.dart';
import '../domain/filter_preset.dart';
import '../domain/presets_repository.dart';
import '../domain/preset_version.dart';

/// 预设库保存在原生 filesDir，独立于正在执行的规则。
class NativePresetsRepository implements PresetsRepository {
  NativePresetsRepository(this._channel);

  final InterceptorChannel _channel;

  @override
  Future<List<FilterPreset>> load() async {
    final library = await _loadLibrary();
    return (library['presets'] as List)
        .map((item) {
          if (item is! Map) throw const FormatException('预设格式无效');
          return FilterPreset.fromJson(asStringMap(item));
        })
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> _loadLibrary() async {
    final result = await _channel.invoke<Map<dynamic, dynamic>>(
      BridgeMethod.getPresets,
    );
    final library = asStringMap(result);
    if (![1, 2].contains(library['schemaVersion']) ||
        library['presets'] is! List ||
        (library['schemaVersion'] == 2 && library['versions'] is! List)) {
      throw const FormatException('不支持的预设库格式');
    }
    return library;
  }

  @override
  Future<List<PresetVersion>> loadVersions() async {
    final library = await _loadLibrary();
    if (library['schemaVersion'] == 1) return const [];
    return (library['versions'] as List)
        .map((item) {
          if (item is! Map) throw const FormatException('预设版本格式无效');
          return PresetVersion.fromJson(asStringMap(item));
        })
        .toList(growable: false);
  }

  @override
  Future<void> saveVersion(String presetId, {String? label}) async {
    await _channel.invoke<Map<dynamic, dynamic>>(
      BridgeMethod.savePresetVersion,
      {'presetId': presetId, if (label != null) 'label': label},
    );
  }

  @override
  Future<String?> importFile() =>
      _channel.invoke<String>(BridgeMethod.importPresetFile);

  @override
  Future<bool> exportFile(String content, {required String fileName}) async =>
      await _channel.invoke<bool>(BridgeMethod.exportPresetFile, {
        'content': content,
        'fileName': fileName,
      }) ??
      false;

  @override
  Future<void> save(List<FilterPreset> presets) async {
    await _channel.invoke<Map<dynamic, dynamic>>(BridgeMethod.savePresets, {
      'library': {
        'schemaVersion': 1,
        'presets': presets.map((preset) => preset.toJson()).toList(),
      },
    });
  }
}
