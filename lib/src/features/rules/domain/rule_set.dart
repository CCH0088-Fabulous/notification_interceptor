import '../../../core/util/json_cast.dart';
import '../../../shared/domain/rule_action.dart';
import 'rule_spec.dart';

/// 规则集合，规则持久化与通道传输的最小单位。
class RuleSet {
  const RuleSet({
    this.schemaVersion = currentSchemaVersion,
    this.globalEnabled = true,
    this.defaultAction = RuleAction.allow,
    this.rules = const [],
  });

  static const int currentSchemaVersion = 1;
  static const RuleSet empty = RuleSet();

  final int schemaVersion;
  final bool globalEnabled;
  final RuleAction defaultAction;
  final List<RuleSpec> rules;

  RuleSet copyWith({
    bool? globalEnabled,
    RuleAction? defaultAction,
    List<RuleSpec>? rules,
  }) =>
      RuleSet(
        schemaVersion: schemaVersion,
        globalEnabled: globalEnabled ?? this.globalEnabled,
        defaultAction: defaultAction ?? this.defaultAction,
        rules: rules ?? this.rules,
      );

  factory RuleSet.fromJson(Map<String, dynamic> json) => RuleSet(
        schemaVersion: asInt(json['schemaVersion'], fallback: currentSchemaVersion),
        globalEnabled: asBool(json['globalEnabled'], fallback: true),
        defaultAction: RuleAction.fromWire(json['defaultAction']),
        rules: asStringMapList(json['rules']).map(RuleSpec.fromJson).toList(),
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'globalEnabled': globalEnabled,
        'defaultAction': defaultAction.wire,
        'rules': rules.map((rule) => rule.toJson()).toList(),
      };
}

/// 规则静态校验的告警项，由 UI 展示，不参与运行时判定。
class RuleIssue {
  const RuleIssue({
    required this.ruleId,
    required this.field,
    required this.message,
  });

  final String ruleId;
  final String field;
  final String message;

  factory RuleIssue.fromJson(Map<String, dynamic> json) => RuleIssue(
        ruleId: asStringOrNull(json['ruleId']) ?? '',
        field: asStringOrNull(json['field']) ?? '',
        message: asStringOrNull(json['message']) ?? '',
      );
}

/// 保存规则后的回执：规则集 + 原生校验告警。
class RuleSaveResult {
  const RuleSaveResult({required this.ruleSet, required this.issues});

  final RuleSet ruleSet;
  final List<RuleIssue> issues;
}
