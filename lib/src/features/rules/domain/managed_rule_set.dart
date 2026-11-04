import '../../../shared/domain/rule_action.dart';
import 'rule_set.dart';
import 'rule_spec.dart';

/// The same transformation powers dry runs and confirmed native saves.
RuleSet replaceManagedRuleSet(
  RuleSet base, {
  required bool Function(RuleSpec rule) ownsRule,
  List<RuleSpec> replacements = const [],
}) {
  if (replacements.any((rule) => !ownsRule(rule))) {
    throw ArgumentError('替换规则不属于此预设');
  }
  final retained = base.rules.where((rule) => !ownsRule(rule)).toList();
  final firstDrop = retained.indexWhere(
    (r) => r.action == RuleAction.intercept,
  );
  retained.insertAll(firstDrop < 0 ? retained.length : firstDrop, [
    ...replacements.where((r) => r.action == RuleAction.allow),
    ...replacements.where((r) => r.action != RuleAction.allow),
  ]);
  return base.copyWith(rules: retained);
}
