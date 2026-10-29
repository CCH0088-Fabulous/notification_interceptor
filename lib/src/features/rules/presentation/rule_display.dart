import '../../../shared/domain/rule_action.dart';
import '../../../shared/util/notification_channel_label.dart';
import '../domain/rule_spec.dart';

/// 仅展示，不改写规则名、条件或跨平台契约。
String ruleDisplayAction(RuleAction action) => switch (action) {
  RuleAction.allow => '优先保留',
  RuleAction.intercept => '自动移出',
  RuleAction.logOnly => '仅记录',
};

String ruleApplicationScope(RuleSpec rule, String Function(String) appName) =>
    rule.packages.isEmpty ? '所有应用' : rule.packages.map(appName).join('、');

List<({String label, String value})> ruleDisplayConditions(RuleSpec rule) => [
  if (rule.keywordsAny.isNotEmpty)
    (label: '关键词', value: rule.keywordsAny.join('、')),
  if (rule.channelIds.isNotEmpty)
    (
      label: '通知渠道',
      value: rule.channelIds.map(notificationChannelLabel).join('、'),
    ),
  if (rule.titleRegex != null) (label: '标题正则', value: rule.titleRegex!),
  if (rule.textRegex != null) (label: '正文正则', value: rule.textRegex!),
  if (rule.isOngoing != null)
    (label: '常驻通知', value: rule.isOngoing! ? '是' : '否'),
  if (rule.isClearable != null)
    (label: '可清除', value: rule.isClearable! ? '是' : '否'),
  if (rule.quietHours != null)
    (
      label: '生效时段',
      value: '${rule.quietHours!.daysLabel} ${rule.quietHours!.label}',
    ),
  if (!rule.hasAnyCondition)
    (label: '条件', value: '未设置条件，不会匹配通知')
  else if (rule.packages.isNotEmpty &&
      rule.keywordsAny.isEmpty &&
      rule.channelIds.isEmpty &&
      rule.titleRegex == null &&
      rule.textRegex == null &&
      rule.isOngoing == null &&
      rule.isClearable == null &&
      rule.quietHours == null)
    (label: '范围', value: '所选应用的全部通知'),
];
