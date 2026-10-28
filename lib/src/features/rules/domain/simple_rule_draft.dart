import '../../../shared/domain/rule_action.dart';
import 'rule_spec.dart';

/// 简化界面的输入，只转换成现有规则字段，不引入第二套匹配引擎。
class SimpleRuleDraft {
  const SimpleRuleDraft({
    required this.id,
    this.name = '',
    this.allApps = true,
    this.packages = const [],
    this.allNotifications = false,
    this.keywords = const [],
    this.action = RuleAction.intercept,
    this.enabled = true,
  });

  final String id;
  final String name;
  final bool allApps;
  final List<String> packages;
  final bool allNotifications;
  final List<String> keywords;
  final RuleAction action;
  final bool enabled;

  static List<String> cleanKeywords(Iterable<String> words) {
    final seen = <String>{};
    return words
        .map((word) => word.trim())
        .where((word) => word.isNotEmpty && seen.add(word.toLowerCase()))
        .toList();
  }

  String? get validationMessage {
    if (!allApps && !packages.any((p) => p.trim().isNotEmpty)) {
      return '请选择至少一个应用';
    }
    if (allApps && allNotifications) return '所有应用必须设置关键词或主题';
    if (!allNotifications && cleanKeywords(keywords).isEmpty) {
      return '请添加至少一个关键词，或选择一个主题';
    }
    return null;
  }

  RuleSpec toRule({required String scopeLabel}) {
    final issue = validationMessage;
    if (issue != null) throw StateError(issue);
    final words = allNotifications ? <String>[] : cleanKeywords(keywords);
    final target = allNotifications ? '全部通知' : words.take(2).join('、');
    return RuleSpec(
      id: id,
      name: name.trim().isEmpty
          ? '$scopeLabel · $target${words.length > 2 ? '等' : ''} · ${action == RuleAction.allow ? '保留' : '移出'}'
          : name.trim(),
      enabled: enabled,
      action: action,
      mode: MatchMode.all,
      packages: allApps
          ? const []
          : packages
                .map((p) => p.trim())
                .where((p) => p.isNotEmpty)
                .toSet()
                .toList(),
      keywordsAny: words,
    );
  }

  /// 复杂规则继续使用原编辑器，避免不可见条件在保存时丢失。
  static bool canEdit(RuleSpec rule) =>
      rule.mode == MatchMode.all &&
      (rule.action == RuleAction.allow ||
          rule.action == RuleAction.intercept) &&
      rule.titleRegex == null &&
      rule.textRegex == null &&
      rule.channelIds.isEmpty &&
      rule.isOngoing == null &&
      rule.isClearable == null &&
      rule.quietHours == null &&
      rule.hasAnyCondition;
}
