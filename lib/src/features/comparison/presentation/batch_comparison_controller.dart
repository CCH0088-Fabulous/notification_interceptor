import 'dart:convert';

import 'package:flutter/foundation.dart';
import '../../../shared/domain/usage_recorder.dart';

import '../../history/domain/history_entry.dart';
import '../../history/presentation/history_controller.dart';
import '../../presets/domain/filter_preset.dart';
import '../../presets/presentation/presets_controller.dart';
import '../../rules/domain/rule_set.dart';
import '../../rules/presentation/rules_controller.dart';
import '../domain/comparison_models.dart';
import '../domain/comparison_repository.dart';

/// A read-only replay of two complete rule sets over the same event snapshot.
class BatchComparisonController extends ChangeNotifier {
  BatchComparisonController({
    required ComparisonRepository repository,
    required RulesController rules,
    required HistoryController history,
    required PresetsController presets,
    DateTime Function()? now,
    UsageRecorder? usage,
  }) : _repository = repository,
       _rules = rules,
       _history = history,
       _presets = presets,
       _now = now ?? DateTime.now,
       _usage = usage {
    _rules.addListener(_changed);
    _presets.addListener(_changed);
  }

  final ComparisonRepository _repository;
  final RulesController _rules;
  final HistoryController _history;
  final PresetsController _presets;
  final DateTime Function() _now;
  final UsageRecorder? _usage;
  bool _loading = false;
  bool _disposed = false;
  bool _runFailed = false;
  bool _exporting = false;
  String? _error;
  String? _sourceFingerprint;
  BatchComparisonResult? _result;

  List<FilterPreset> get presets => _presets.presets;
  bool get loading => _loading || _exporting;
  String? get error => _error;
  BatchComparisonResult? get result => _result;
  bool get isStale =>
      _result != null && (_runFailed || _sourceFingerprint != _fingerprint());

  String _fingerprint() => jsonEncode({
    'rules': _rules.ruleSet.toJson(),
    'presets': _presets.presets.map((p) => p.toJson()).toList(),
  });

  Future<void> run({
    required String presetId,
    ComparisonPeriod period = ComparisonPeriod.all,
    int limit = 1000,
  }) async {
    if (loading) throw StateError('请等待当前对比或导出完成');
    _loading = true;
    _runFailed = true;
    _error = null;
    _changed();
    try {
      if (limit < 1 || limit > 1000) throw ArgumentError('样本数量需为 1–1000');
      await _presets.load();
      if (!_presets.canWrite) throw StateError('预设库读取失败或正在修改，请稍后重试');
      await _rules.load();
      if (_rules.error != null) throw StateError('当前规则读取失败，请重试');
      await _history.load();
      if (_history.error != null) throw StateError('历史记录读取失败，请重试');
      if (_history.loading) throw StateError('历史记录正在重新读取，请稍后重试');
      if (!_presets.canWrite || _rules.busy) {
        throw StateError('配置正在修改，请完成后重新对比');
      }
      if (_disposed) return;
      final matches = _presets.presets.where((p) => p.id == presetId);
      if (matches.isEmpty) throw StateError('所选预设已不存在，请重新选择');
      final preset = FilterPreset.fromJson(
        jsonDecode(jsonEncode(matches.single.toJson())) as Map<String, dynamic>,
      );
      final base = _freezeRules(_rules.ruleSet);
      final candidate = _freezeRules(
        _presets.candidateForPreset(preset, base: base),
      );
      final fingerprint = _fingerprint();
      final now = _now();
      final since = period.since(now);
      final source =
          _history.allEntries
              .where(
                (e) =>
                    since == null ||
                    (e.timestamp >= since &&
                        e.timestamp <= now.millisecondsSinceEpoch),
              )
              .toList()
            ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
      final skipped = source.where((e) => e.record.isGroupSummary).length;
      final skippedOngoing = source
          .where((e) => e.record.isOngoing && !e.record.isGroupSummary)
          .length;
      final samples = source
          .where((e) => e.record.countsTowardStatistics)
          .take(limit)
          .map(_snapshotEntry)
          .toList(growable: false);
      final evaluation = await _repository.compare(
        base: base,
        candidate: candidate,
        samples: samples,
      );
      if (_disposed) return;
      if (evaluation.rows.length != samples.length) {
        throw const FormatException('对比结果与样本数量不一致');
      }
      final rows = <BatchComparisonRow>[];
      for (var index = 0; index < samples.length; index++) {
        final pair = evaluation.rows[index];
        if (pair.entryId != samples[index].id) {
          throw const FormatException('对比结果顺序不一致');
        }
        rows.add(
          BatchComparisonRow(
            entry: samples[index],
            before: pair.before,
            after: pair.after,
          ),
        );
      }
      _result = BatchComparisonResult(
        target: preset,
        rows: rows,
        beforeRules: base,
        afterRules: candidate,
        generatedAt: evaluation.evaluatedAt,
        zoneId: evaluation.zoneId,
        period: period,
        limit: limit,
        sourceCount: source.length,
        skippedSummaries: skipped,
        skippedOngoing: skippedOngoing,
        baseIssues: evaluation.baseIssues,
        candidateIssues: evaluation.candidateIssues,
      );
      _sourceFingerprint = fingerprint;
      _runFailed = false;
      try {
        _usage?.record(UsageAction.comparisonCompleted);
      } catch (_) {
        /* optional observer */
      }
    } catch (error) {
      _error = error.toString();
    } finally {
      _loading = false;
      _changed();
    }
  }

  String exportJson() {
    final snapshot = _result;
    if (snapshot == null) throw StateError('请先运行批量对比');
    if (isStale || _loading) throw StateError('配置已发生变化或对比未完成，请重新运行');
    return snapshot.exportJson();
  }

  Future<bool> exportFile() async {
    if (loading) throw StateError('请等待当前操作完成');
    final content = exportJson();
    if (utf8.encode(content).length > 8 * 1024 * 1024) {
      throw StateError('报告超过 8 MiB，请减少样本数量后重试');
    }
    _exporting = true;
    _changed();
    try {
      final now = _now();
      final date =
          '${now.year}${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}';
      return await _repository.exportFile(
        content,
        fileName: 'batch-comparison-$date.json',
      );
    } finally {
      _exporting = false;
      _changed();
    }
  }

  static RuleSet _freezeRules(RuleSet source) {
    final clone = RuleSet.fromJson(
      jsonDecode(jsonEncode(source.toJson())) as Map<String, dynamic>,
    );
    return clone.copyWith(
      rules: List.unmodifiable(
        clone.rules.map(
          (r) => r.copyWith(
            packages: List.unmodifiable(r.packages),
            keywordsAny: List.unmodifiable(r.keywordsAny),
            channelIds: List.unmodifiable(r.channelIds),
            quietHours: r.quietHours?.copyWith(
              days: Set.unmodifiable(r.quietHours!.days),
            ),
          ),
        ),
      ),
    );
  }

  static HistoryEntry _snapshotEntry(HistoryEntry entry) {
    final json = entry.toJson();
    json['snapshot'] = Map<String, dynamic>.of(entry.record.toJson())
      ..remove('extras');
    return HistoryEntry.fromJson(
      jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
    );
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _rules.removeListener(_changed);
    _presets.removeListener(_changed);
    super.dispose();
  }
}
