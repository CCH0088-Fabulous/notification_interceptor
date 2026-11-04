import 'dart:convert';

import 'filter_preset.dart';

/// Portable current definitions only. Runtime rules and version history are
/// deliberately outside this format so a shared file cannot activate rules.
abstract final class PresetTransfer {
  static const schemaVersion = 1;
  static const maxBytes = 2 * 1024 * 1024;
  static const maxPresets = 100;

  static String encode(List<FilterPreset> presets) {
    final snapshot = _validatedSnapshots(presets);
    final encoded = jsonEncode({
      'schemaVersion': schemaVersion,
      'presets': snapshot.map((preset) => preset.toJson()).toList(),
    });
    _checkSize(encoded);
    return encoded;
  }

  static List<FilterPreset> decode(String raw) {
    if (raw.trim().isEmpty) throw const FormatException('导入内容为空');
    _checkSize(raw);
    Object? decoded;
    try {
      // Some text editors write a UTF-8 BOM; it is not part of the JSON data.
      final text = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
      decoded = jsonDecode(text);
    } on FormatException {
      throw const FormatException('导入内容不是有效的 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('预设文件必须是包含版本和预设列表的 JSON 对象');
    }
    if (decoded['schemaVersion'] is! int ||
        decoded['schemaVersion'] != schemaVersion) {
      throw const FormatException('不支持的预设文件版本，请使用预设导出文件');
    }
    if (decoded.keys.any((key) => key != 'schemaVersion' && key != 'presets')) {
      throw const FormatException('请导入预设导出文件，不包含运行规则或版本历史');
    }
    final items = decoded['presets'];
    if (items is! List) throw const FormatException('预设列表格式错误');
    if (items.length > maxPresets) {
      throw const FormatException('单个文件最多包含 100 个预设');
    }
    final presets = <FilterPreset>[];
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      if (item is! Map<String, dynamic>) {
        throw FormatException('第 ${index + 1} 个预设格式错误');
      }
      try {
        presets.add(FilterPreset.fromJson(item));
      } on FormatException catch (error) {
        throw FormatException('第 ${index + 1} 个预设无效：${error.message}');
      }
    }
    return _validatedSnapshots(presets);
  }

  static PresetImportPlan preview(String raw, List<FilterPreset> existing) =>
      PresetImportPlan._(decode(raw), _validatedSnapshots(existing));

  static void _checkSize(String raw) {
    if (utf8.encode(raw).length > maxBytes) {
      throw const FormatException('预设文件不能超过 2 MiB');
    }
  }
}

/// A preview is tied to the library that the user inspected. An import cannot
/// silently overwrite a newer edit while its confirmation dialog is open.
class PresetImportPlan {
  PresetImportPlan._(this.presets, List<FilterPreset> existing)
    : baseFingerprint = _fingerprint(existing),
      duplicateIds = List.unmodifiable(
        presets
            .where((preset) => existing.any((item) => item.id == preset.id))
            .map((preset) => preset.id),
      );

  final List<FilterPreset> presets;
  final List<String> duplicateIds;
  final String baseFingerprint;
  int get addedCount => presets.length - duplicateIds.length;
  int get updatedCount => duplicateIds.length;

  List<FilterPreset> merge(
    List<FilterPreset> current, {
    bool replaceExisting = false,
  }) {
    final snapshot = _validatedSnapshots(current);
    if (_fingerprint(snapshot) != baseFingerprint) {
      throw StateError('预设库已发生变化，请重新预览导入内容');
    }
    final result = [...snapshot];
    for (final preset in presets) {
      final index = result.indexWhere((item) => item.id == preset.id);
      if (index < 0) {
        result.add(preset);
      } else if (replaceExisting) {
        result[index] = preset;
      }
    }
    // Check the complete merged result before the caller performs one write.
    return _validatedSnapshots(result);
  }
}

List<FilterPreset> _validatedSnapshots(List<FilterPreset> presets) {
  if (presets.length > PresetTransfer.maxPresets) {
    throw const FormatException('合并后最多保存 100 个预设');
  }
  final ids = <String>{};
  final snapshot = <FilterPreset>[];
  for (final preset in presets) {
    if (!ids.add(preset.id)) throw const FormatException('预设文件包含重复标识');
    final errors = preset.validate();
    if (errors.isNotEmpty) throw FormatException(errors.join('；'));
    snapshot.add(
      preset.copyWith(
        keywords: List.unmodifiable(preset.keywords),
        allowKeywords: List.unmodifiable(preset.allowKeywords),
        packages: List.unmodifiable(preset.packages),
        quietHours: preset.quietHours?.copyWith(
          days: Set.unmodifiable(preset.quietHours!.days),
        ),
      ),
    );
  }
  return List.unmodifiable(snapshot);
}

String _fingerprint(List<FilterPreset> presets) =>
    jsonEncode(presets.map((preset) => preset.toJson()).toList());
