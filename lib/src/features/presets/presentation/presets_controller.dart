import 'dart:convert';

import 'package:flutter/foundation.dart';
import '../../../shared/domain/usage_recorder.dart';

import '../../rules/presentation/rules_controller.dart';
import '../../rules/domain/rule_spec.dart';
import '../../rules/domain/rule_set.dart';
import '../../rules/domain/managed_rule_set.dart';
import '../domain/filter_preset.dart';
import '../domain/preset_transfer.dart';
import '../domain/preset_version.dart';
import '../domain/presets_repository.dart';

/// Library writes never activate rules. Application explicitly installs a copy
/// in the existing native rule engine; no Flutter background timer is needed.
class PresetsController extends ChangeNotifier {
  PresetsController({
    required PresetsRepository repository,
    required RulesController rules,
    UsageRecorder? usage,
  }) : _repository = repository,
       _rules = rules,
       _usage = usage {
    _rules.addListener(_changed);
  }

  final PresetsRepository _repository;
  final RulesController _rules;
  final UsageRecorder? _usage;
  List<FilterPreset> _presets = const [];
  List<PresetVersion> _versions = const [];
  bool _loading = false;
  bool _busy = false;
  bool _loaded = false;
  bool _disposed = false;
  String? _error;

  List<FilterPreset> get presets => _presets;
  List<PresetVersion> get versions => _versions;
  bool get loading => _loading;
  bool get busy => _busy;
  bool get canWrite => _loaded && !_loading && !_busy;
  String? get error => _error;
  bool get globalEnabled => _rules.globalEnabled;

  List<FilterPreset> get activeScenes => List.unmodifiable(
    _presets.where(
      (preset) => _rules.ruleSet.rules.any(
        (rule) =>
            rule.enabled &&
            preset.ownsRule(rule) &&
            _isInstalledSceneRule(rule),
      ),
    ),
  );

  bool _isInstalledSceneRule(RuleSpec rule) {
    if (rule.id.startsWith('preset:scene:')) return true;
    if (rule.id.startsWith('preset:keywords:')) return false;
    // Legacy IDs did not encode kind. Keep their existing state on upgrade;
    // the first explicit switch replaces them with typed ownership IDs.
    return _presets.any(
      (preset) => preset.kind == PresetKind.scene && preset.ownsRule(rule),
    );
  }

  bool hasAppliedRules(FilterPreset preset) =>
      _rules.ruleSet.rules.any(preset.ownsRule);

  RuleSet candidateForPreset(FilterPreset preset, {required RuleSet base}) {
    _requireCurrent(preset);
    return replaceManagedRuleSet(
      base,
      ownsRule: preset.kind == PresetKind.scene
          ? (rule) => _isInstalledSceneRule(rule) || preset.ownsRule(rule)
          : preset.ownsRule,
      replacements: preset.toRules(),
    );
  }

  bool isApplied(FilterPreset preset) {
    final actual = _rules.ruleSet.rules.where(preset.ownsRule).toList();
    final expected = preset.toRules();
    if (actual.length != expected.length) return false;
    // Keep-before-drop is part of the applied state, even if rules were edited
    // manually after activation.
    for (var index = 0; index < expected.length; index++) {
      if (jsonEncode(actual[index].toJson()) !=
          jsonEncode(expected[index].toJson())) {
        return false;
      }
    }
    return true;
  }

  Future<void> load() async {
    if (_busy || _loading) return;
    _loading = true;
    _error = null;
    _changed();
    try {
      final presets = await _repository.load();
      _validateLibrary(presets);
      final versions = await _repository.loadVersions();
      _presets = List.unmodifiable(presets);
      _setVersions(versions);
      _loaded = true;
    } catch (error) {
      _loaded = false;
      _error = error.toString();
    } finally {
      _loading = false;
      _changed();
    }
  }

  Future<void> save(FilterPreset preset) => _run(() async {
    final errors = preset.validate();
    if (errors.isNotEmpty) throw FormatException(errors.join('；'));
    // Deep-copy so a caller cannot change a saved collection after validation.
    final frozen = FilterPreset.fromJson(
      jsonDecode(jsonEncode(preset.toJson())) as Map<String, dynamic>,
    );
    final next = [..._presets];
    final index = next.indexWhere((item) => item.id == preset.id);
    if (index < 0) {
      next.add(frozen);
    } else {
      next[index] = frozen;
    }
    await _saveLibrary(next);
  });

  Future<void> apply(FilterPreset preset) => preset.kind == PresetKind.scene
      ? switchScene(preset)
      : _run(() async {
          _requireCurrent(preset);
          await _rules.replaceManagedRules(
            ownsRule: preset.ownsRule,
            replacements: preset.toRules(),
          );
        }, usageAction: UsageAction.presetApply);

  Future<void> switchScene(FilterPreset preset) => _run(() async {
    _requireCurrent(preset);
    if (preset.kind != PresetKind.scene) {
      throw ArgumentError('请选择场景预设');
    }
    // A single native rules save avoids an intermediate unfiltered state.
    await _rules.replaceManagedRules(
      ownsRule: (rule) => _isInstalledSceneRule(rule) || preset.ownsRule(rule),
      replacements: preset.toRules(),
    );
  }, usageAction: UsageAction.sceneSwitch);

  Future<void> deactivateScenes() => _run(
    () => _rules.replaceManagedRules(ownsRule: _isInstalledSceneRule),
    usageAction: UsageAction.sceneEnd,
  );

  Future<void> saveVersion(FilterPreset preset, {String? label}) =>
      _run(() async {
        _requireCurrent(preset);
        final normalized = label?.trim();
        if (normalized != null &&
            (normalized.isEmpty || normalized.length > 60)) {
          throw ArgumentError('版本名称需为 1–60 个字符');
        }
        await _repository.saveVersion(preset.id, label: normalized);
        await _refreshVersionsAfterWrite();
      });

  Future<void> restoreVersion(PresetVersion version) => _run(() async {
    if (!_versions.any(
      (item) => jsonEncode(item.toJson()) == jsonEncode(version.toJson()),
    )) {
      throw StateError('版本记录已发生变化，请刷新后重试');
    }
    final restored = FilterPreset.fromJson(
      jsonDecode(jsonEncode(version.preset.toJson())) as Map<String, dynamic>,
    );
    final next = [..._presets];
    final index = next.indexWhere((item) => item.id == restored.id);
    if (index < 0) {
      next.add(restored);
    } else {
      next[index] = restored;
    }
    // Rolling back a definition uses the same save/archive path as editing.
    // Running rules remain visible as "needs reapply" until confirmation.
    await _saveLibrary(next);
  }, usageAction: UsageAction.presetRestore);

  PresetImportPlan previewImport(String raw) {
    if (!canWrite) throw StateError('请先完成预设库读取或当前操作');
    return PresetTransfer.preview(raw, _presets);
  }

  Future<void> importPresets(
    PresetImportPlan plan, {
    bool replaceExisting = false,
  }) => _run(() async {
    final next = plan.merge(_presets, replaceExisting: replaceExisting);
    await _saveLibrary(next);
  }, usageAction: UsageAction.presetImport);

  String exportJson({Set<String>? ids}) {
    if (!_loaded) throw StateError('请先读取预设库');
    if (ids != null && ids.any((id) => !_presets.any((p) => p.id == id))) {
      throw StateError('所选预设已不存在，请刷新');
    }
    return PresetTransfer.encode(
      _presets.where((p) => ids == null || ids.contains(p.id)).toList(),
    );
  }

  Future<String?> importFile() => _run(_repository.importFile);

  Future<bool> exportFile(String content) => _run(() {
    // Validate portable output before opening the picker.
    PresetTransfer.decode(content);
    final now = DateTime.now();
    final date =
        '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    return _repository.exportFile(
      content,
      fileName: 'notification-presets-$date.json',
    );
  }, usageAction: UsageAction.presetExport);

  Future<void> deactivate(FilterPreset preset) => _run(() async {
    _requireCurrent(preset);
    await _rules.replaceManagedRules(ownsRule: preset.ownsRule);
  });

  Future<void> remove(FilterPreset preset) => _run(() async {
    _requireCurrent(preset);
    // Always read native rules first: a stale UI must not orphan active rules.
    await _rules.replaceManagedRules(ownsRule: preset.ownsRule);
    await _saveLibrary(_presets.where((item) => item.id != preset.id).toList());
  });

  void _requireCurrent(FilterPreset preset) {
    if (!_presets.any(
      (item) => jsonEncode(item.toJson()) == jsonEncode(preset.toJson()),
    )) {
      throw StateError('预设已发生变化，请返回列表重新操作');
    }
  }

  Future<void> _saveLibrary(List<FilterPreset> next) async {
    _validateLibrary(next);
    final nextById = {for (final preset in next) preset.id: preset};
    final legacyRenames = <String, String>{};
    for (final previous in _presets) {
      final updated = nextById[previous.id];
      if (updated != null && updated.kind != previous.kind) {
        for (final action in ['allow', 'intercept']) {
          legacyRenames['preset_${previous.id}_$action'] =
              'preset:${previous.kind.name}:${previous.id}:$action';
        }
      }
    }
    if (legacyRenames.isNotEmpty) {
      // Legacy rule IDs lack kind. Pin their original ownership before a
      // library edit changes kind, preserving live behavior until application.
      await _rules.renameManagedRuleIds(legacyRenames);
    }
    await _repository.save(next);
    _presets = List.unmodifiable(next);
    await _refreshVersionsAfterWrite();
  }

  void _setVersions(List<PresetVersion> versions) {
    if (versions.length > 20 ||
        versions.map((v) => v.id).toSet().length != versions.length) {
      throw const FormatException('预设版本记录无效');
    }
    _versions = List.unmodifiable(
      [...versions]..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
    );
  }

  Future<void> _refreshVersionsAfterWrite() async {
    try {
      _setVersions(await _repository.loadVersions());
    } catch (_) {
      // The primary save succeeded. Do not report it as a failed write or
      // allow restoring stale versions while a reload is needed.
      _versions = const [];
      _error = '预设已保存，版本记录暂时无法读取，请重新读取';
    }
  }

  void _validateLibrary(List<FilterPreset> presets) {
    if (presets.length > 100) throw StateError('最多保存 100 个预设');
    final ids = <String>{};
    for (final preset in presets) {
      if (!ids.add(preset.id)) throw const FormatException('预设标识重复');
      final errors = preset.validate();
      if (errors.isNotEmpty) throw FormatException(errors.join('；'));
    }
  }

  Future<T> _run<T>(
    Future<T> Function() operation, {
    UsageAction? usageAction,
  }) async {
    if (_busy || _loading) throw StateError('请等待当前操作完成');
    if (!_loaded) throw StateError('请先成功读取预设库，再进行修改');
    _busy = true;
    _error = null;
    _changed();
    try {
      final result = await operation();
      if (usageAction != null && result != false) {
        try {
          _usage?.record(usageAction);
        } catch (_) {
          /* optional observer */
        }
      }
      return result;
    } catch (error) {
      _error = error.toString();
      rethrow;
    } finally {
      _busy = false;
      _changed();
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _rules.removeListener(_changed);
    super.dispose();
  }
}
