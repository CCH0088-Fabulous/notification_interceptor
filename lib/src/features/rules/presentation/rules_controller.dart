import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../shared/domain/decision.dart';
import '../../../shared/domain/rule_action.dart';
import '../../feed/domain/notification_record.dart';
import '../domain/rule_set.dart';
import '../domain/managed_rule_set.dart';
import '../domain/rule_spec.dart';
import '../domain/rule_validation.dart';
import '../domain/rules_repository.dart';

/// 规则编辑与持久化的唯一状态源。保存后立即回写原生校验结果。
class RulesController extends ChangeNotifier {
  RulesController({required RulesRepository repository})
    : _repository = repository;

  final RulesRepository _repository;

  RuleSet _ruleSet = RuleSet.empty;
  List<RuleIssue> _issues = const [];
  List<String> _seenPackages = const [];
  Map<String, String> _availableApps = const {};
  bool _loading = false;
  bool _disposed = false;
  Future<void>? _pending;
  String? _error;

  RuleSet get ruleSet => _ruleSet;
  List<RuleIssue> get issues => _issues;
  List<String> get seenPackages => _seenPackages;
  Map<String, String> get availableApps => _availableApps;
  bool get loading => _loading;
  bool get busy => _pending != null;
  String? get error => _error;
  bool get globalEnabled => _ruleSet.globalEnabled;

  Future<void> load() => _enqueue(() async {
    _loading = true;
    _error = null;
    _notify();
    try {
      _ruleSet = await _repository.load();
      // 先用纯函数校验给出即时反馈，保存后由原生结果覆盖。
      _issues = validateRuleSet(_ruleSet);
    } catch (error) {
      _error = error.toString();
    } finally {
      _loading = false;
      _notify();
    }
  });

  Future<void> loadSeenPackages() => _enqueue(() async {
    try {
      _seenPackages = await _repository.seenPackages();
      _error = null;
      _notify();
    } catch (error) {
      _error = error.toString();
      _notify();
    }
  });

  Future<Map<String, String>> loadAvailableApps() async {
    _availableApps = Map.unmodifiable(await _repository.availableApps());
    _notify();
    return _availableApps;
  }

  Future<void> setGlobalEnabled(bool enabled) =>
      _enqueue(() => _persist(_ruleSet.copyWith(globalEnabled: enabled)));

  /// 新保留规则排在首个移出规则之前；旧规则顺序不变，编辑原位替换。
  RuleSet candidateFor(RuleSpec rule) {
    final rules = [..._ruleSet.rules];
    final index = rules.indexWhere((item) => item.id == rule.id);
    if (index >= 0) {
      rules[index] = rule;
    } else {
      final firstDrop = rules.indexWhere(
        (r) => r.action == RuleAction.intercept,
      );
      if (rule.action == RuleAction.allow && firstDrop >= 0) {
        rules.insert(firstDrop, rule);
      } else {
        rules.add(rule);
      }
    }
    return _ruleSet.copyWith(rules: rules);
  }

  Future<void> upsert(RuleSpec rule) =>
      _enqueue(() => _persist(candidateFor(rule)));

  /// 只有预览的基础规则未变化时才保存；失败保留草稿，由页面呈现错误。
  Future<void> saveDraft(RuleSpec rule, {required RuleSet previewBase}) =>
      _enqueue(() async {
        if (jsonEncode(previewBase.toJson()) != jsonEncode(_ruleSet.toJson())) {
          throw StateError('已有规则发生变化，请重新预览');
        }
        final latest = await _repository.load();
        if (jsonEncode(previewBase.toJson()) != jsonEncode(latest.toJson())) {
          _ruleSet = latest;
          _issues = validateRuleSet(latest);
          _notify();
          throw StateError('已有规则发生变化，请重新预览');
        }
        await _persist(candidateFor(rule));
        if (_error != null) throw StateError('保存失败，请重试');
      });

  Future<void> remove(String id) => _enqueue(
    () => _persist(
      _ruleSet.copyWith(
        rules: _ruleSet.rules.where((r) => r.id != id).toList(),
      ),
    ),
  );

  /// 整体替换（导入预设/备份时使用），保留全局开关之外的一切原样写入。
  Future<void> replaceAll(RuleSet next) => _enqueue(() => _persist(next));

  /// Migrate machine ownership without applying an edited definition. Only
  /// IDs change; preserve every condition, enabled flag and original position.
  Future<void> renameManagedRuleIds(Map<String, String> renames) {
    final names = Map<String, String>.unmodifiable(renames);
    return _enqueue(() async {
      if (names.values.any((id) => id.trim().isEmpty)) {
        throw ArgumentError('规则标识不能为空');
      }
      final latest = await _repository.load();
      final changing = latest.rules.where(
        (rule) => names.containsKey(rule.id) && names[rule.id] != rule.id,
      );
      final targets = <String>{};
      final untouched = latest.rules
          .where(
            (rule) => !names.containsKey(rule.id) || names[rule.id] == rule.id,
          )
          .map((rule) => rule.id)
          .toSet();
      for (final rule in changing) {
        final target = names[rule.id]!;
        if (untouched.contains(target) || !targets.add(target)) {
          throw StateError('规则标识发生冲突，请先检查规则列表');
        }
      }
      if (targets.isEmpty) {
        _ruleSet = latest;
        _issues = validateRuleSet(latest);
        _error = null;
        _notify();
        return;
      }
      final renamed = latest.rules
          .map(
            (rule) => names.containsKey(rule.id)
                ? rule.copyWith(id: names[rule.id])
                : rule,
          )
          .toList();
      _ruleSet = latest;
      await _persist(latest.copyWith(rules: renamed));
      if (_error != null) throw StateError('规则归属迁移失败：$_error');
    });
  }

  /// Replace only a feature-owned subset, retaining fresh native rules and
  /// global/default settings. Exceptions precede drops, existing rule order
  /// remains unchanged. Failed reads or writes are reported to the caller.
  Future<void> replaceManagedRules({
    required bool Function(RuleSpec rule) ownsRule,
    List<RuleSpec> replacements = const [],
  }) => _enqueue(() async {
    final latest = await _repository.load();
    final candidate = replaceManagedRuleSet(
      latest,
      ownsRule: ownsRule,
      replacements: replacements,
    );
    if (jsonEncode(candidate.toJson()) == jsonEncode(latest.toJson())) {
      _ruleSet = latest;
      _issues = validateRuleSet(latest);
      _error = null;
      _notify();
      return;
    }
    _ruleSet = latest;
    await _persist(candidate);
    if (_error != null) throw StateError('规则保存失败：$_error');
  });

  Future<void> setRuleEnabled(String id, bool enabled) => _enqueue(() {
    final rules = _ruleSet.rules
        .map((rule) => rule.id == id ? rule.copyWith(enabled: enabled) : rule)
        .toList();
    return _persist(_ruleSet.copyWith(rules: rules));
  });

  Future<Decision> evaluate(
    NotificationRecord sample, {
    RuleSpec? draft,
  }) async {
    final ruleSet = draft == null ? _ruleSet : candidateFor(draft);
    return _repository.evaluate(sample, ruleSet: ruleSet);
  }

  List<RuleIssue> issuesFor(String ruleId) =>
      _issues.where((issue) => issue.ruleId == ruleId).toList();

  Future<void> _persist(RuleSet next) async {
    final previous = _ruleSet;
    _ruleSet = next;
    _notify();
    try {
      final result = await _repository.save(next);
      _ruleSet = result.ruleSet;
      _issues = result.issues;
      _error = null;
    } catch (error) {
      _ruleSet = previous;
      _error = error.toString();
      _issues = validateRuleSet(_ruleSet);
    }
    _notify();
  }

  /// Native reads and read/modify/write operations share one queue. Build the
  /// next set inside the callback so queued edits use the last saved state.
  /// A rejected draft must not prevent later operations from running.
  Future<void> _enqueue(Future<void> Function() operation) {
    final previous = _pending;
    final done = Completer<void>();
    final barrier = done.future;
    // Install the barrier before starting: synchronous listeners may enqueue
    // another operation while the first one is notifying its loading state.
    _pending = barrier;
    Future<void> run() async {
      try {
        await operation();
      } finally {
        // Release queued work even when this operation fails. The returned
        // future carries its error; the scheduling barrier always succeeds.
        if (identical(_pending, barrier)) _pending = null;
        done.complete();
      }
    }

    // An idle queue starts in the caller's Zone, instead of retaining a
    // completed Future from an earlier Zone (e.g. real vs fake async tests).
    return previous == null ? run() : previous.then((_) => run());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 动作对应的中文标签，供 UI 复用。
String actionLabel(RuleAction action) => action.label;
