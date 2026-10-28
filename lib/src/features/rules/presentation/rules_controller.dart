import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../shared/domain/decision.dart';
import '../../../shared/domain/rule_action.dart';
import '../../feed/domain/notification_record.dart';
import '../domain/rule_set.dart';
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
  bool _loading = false;
  String? _error;

  RuleSet get ruleSet => _ruleSet;
  List<RuleIssue> get issues => _issues;
  List<String> get seenPackages => _seenPackages;
  bool get loading => _loading;
  String? get error => _error;
  bool get globalEnabled => _ruleSet.globalEnabled;

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _ruleSet = await _repository.load();
      // 先用纯函数校验给出即时反馈，保存后由原生结果覆盖。
      _issues = validateRuleSet(_ruleSet);
    } catch (error) {
      _error = error.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> loadSeenPackages() async {
    try {
      _seenPackages = await _repository.seenPackages();
      _error = null;
      notifyListeners();
    } catch (error) {
      _error = error.toString();
      notifyListeners();
    }
  }

  Future<void> setGlobalEnabled(bool enabled) =>
      _persist(_ruleSet.copyWith(globalEnabled: enabled));

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

  Future<void> upsert(RuleSpec rule) => _persist(candidateFor(rule));

  /// 只有预览的基础规则未变化时才保存；失败保留草稿，由页面呈现错误。
  Future<void> saveDraft(RuleSpec rule, {required RuleSet previewBase}) async {
    if (jsonEncode(previewBase.toJson()) != jsonEncode(_ruleSet.toJson())) {
      throw StateError('已有规则发生变化，请重新预览');
    }
    final latest = await _repository.load();
    if (jsonEncode(previewBase.toJson()) != jsonEncode(latest.toJson())) {
      _ruleSet = latest;
      _issues = validateRuleSet(latest);
      notifyListeners();
      throw StateError('已有规则发生变化，请重新预览');
    }
    await _persist(candidateFor(rule));
    if (_error != null) throw StateError('保存失败，请重试');
  }

  Future<void> remove(String id) => _persist(
    _ruleSet.copyWith(rules: _ruleSet.rules.where((r) => r.id != id).toList()),
  );

  /// 整体替换（导入预设/备份时使用），保留全局开关之外的一切原样写入。
  Future<void> replaceAll(RuleSet next) => _persist(next);

  Future<void> setRuleEnabled(String id, bool enabled) {
    final rules = _ruleSet.rules
        .map((rule) => rule.id == id ? rule.copyWith(enabled: enabled) : rule)
        .toList();
    return _persist(_ruleSet.copyWith(rules: rules));
  }

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
    notifyListeners();
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
    notifyListeners();
  }
}

/// 动作对应的中文标签，供 UI 复用。
String actionLabel(RuleAction action) => action.label;
