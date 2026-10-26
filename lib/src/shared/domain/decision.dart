import '../../core/util/json_cast.dart';
import 'rule_action.dart';

/// 引擎判定结果。reason: disabled / self / rule / default。
class Decision {
  const Decision({
    this.ruleId,
    this.ruleName,
    this.action = RuleAction.allow,
    this.reason = 'default',
  });

  final String? ruleId;
  final String? ruleName;
  final RuleAction action;
  final String reason;

  bool get shouldIntercept => action == RuleAction.intercept;
  bool get matchedByRule => reason == 'rule';

  factory Decision.fromJson(Map<String, dynamic> json) => Decision(
        ruleId: asStringOrNull(json['ruleId']),
        ruleName: asStringOrNull(json['ruleName']),
        action: RuleAction.fromWire(json['action']),
        reason: asStringOrNull(json['reason']) ?? 'default',
      );

  String describe() {
    switch (reason) {
      case 'disabled':
        return '全局规则已关闭';
      case 'self':
        return '本应用自身通知';
      case 'rule':
        return '命中规则「${ruleName?.isNotEmpty == true ? ruleName : ruleId}」';
      default:
        return '未命中规则，按默认动作处理';
    }
  }
}
