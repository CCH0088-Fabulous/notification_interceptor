import 'filter_preset.dart';
import 'preset_version.dart';

abstract interface class PresetsRepository {
  Future<List<FilterPreset>> load();
  Future<void> save(List<FilterPreset> presets);
  Future<List<PresetVersion>> loadVersions();
  Future<void> saveVersion(String presetId, {String? label});
  Future<String?> importFile();
  Future<bool> exportFile(String content, {required String fileName});
}
