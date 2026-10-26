import 'rule_set.dart';

/// 纯函数校验，供编辑器即时提示；最终以原生 `validate` 为准。
/// 逻辑与 Kotlin `RuleEngine.validate` 保持一一对应。
List<RuleIssue> validateRuleSet(RuleSet ruleSet) {
  final issues = <RuleIssue>[];
  final seenIds = <String>{};

  for (final rule in ruleSet.rules) {
    if (rule.id.trim().isEmpty) {
      issues.add(RuleIssue(ruleId: rule.id, field: 'id', message: '规则 id 不能为空'));
    } else if (!seenIds.add(rule.id)) {
      issues.add(RuleIssue(ruleId: rule.id, field: 'id', message: '规则 id 重复'));
    }
    if (!rule.hasAnyCondition) {
      issues.add(RuleIssue(ruleId: rule.id, field: 'match', message: '规则没有任何匹配条件，永远不会命中'));
    }
    if (rule.titleRegex != null && !isValidRegex(rule.titleRegex!)) {
      issues.add(RuleIssue(ruleId: rule.id, field: 'titleRegex', message: '标题正则无效'));
    }
    if (rule.textRegex != null && !isValidRegex(rule.textRegex!)) {
      issues.add(RuleIssue(ruleId: rule.id, field: 'textRegex', message: '正文正则无效'));
    }
    final quiet = rule.quietHours;
    if (quiet != null && quiet.fromMinutes == quiet.toMinutes) {
      issues.add(RuleIssue(ruleId: rule.id, field: 'quietHours', message: '静默时段起止相同，窗口为空'));
    }
  }
  return issues;
}

bool isValidRegex(String pattern) {
  if (pattern.length > 200) return false;
  try {
    RegExp(pattern);
    return true;
  } on FormatException {
    return false;
  }
}

/// 把逗号/换行分隔的输入解析成去重列表，编辑器统一入口。
List<String> parseListInput(String raw) {
  return raw
      .split(RegExp(r'[,，\n]'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList(growable: false);
}
