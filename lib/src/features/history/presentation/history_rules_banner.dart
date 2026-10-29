import 'package:flutter/material.dart';

import '../../../shared/domain/rule_action.dart';
import '../../rules/domain/rule_spec.dart';
import '../../rules/presentation/rule_display.dart';
import '../../rules/presentation/rules_controller.dart';

/// The current configuration is read from rules, never inferred from historical decisions.
class HistoryRulesBanner extends StatelessWidget {
  const HistoryRulesBanner({super.key, required this.controller, this.appName});

  final RulesController controller;
  final String Function(String)? appName;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final theme = Theme.of(context);
      final rules = controller.ruleSet.rules
          .where((rule) => rule.enabled)
          .toList();
      final available = !controller.loading && controller.error == null;
      return Container(
        key: const ValueKey('history-current-rules'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '本次的拦截规则是',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            if (controller.loading)
              const Text('【正在读取当前规则…】')
            else if (controller.error != null) ...[
              const Text('【当前规则读取失败】'),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: controller.load,
                  child: const Text('重试读取规则'),
                ),
              ),
            ] else if (!controller.globalEnabled)
              const Text('【规则引擎已关闭，所有通知均保留】')
            else if (rules.isEmpty)
              Text(
                '【没有启用的规则，所有通知${_defaultAction(controller.ruleSet.defaultAction)}】',
              )
            else ...[
              for (var i = 0; i < rules.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text(
                    '${i + 1}. ${ruleDisplayAction(rules[i].action)}【${_name(rules[i])}】',
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
                  ),
                ),
              Text(
                '按顺序匹配，首条命中生效；未匹配通知${_defaultAction(controller.ruleSet.defaultAction)}。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (available && controller.globalEnabled && rules.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _showConditions(context),
                  child: const Text('查看具体条件 ›'),
                ),
              ),
          ],
        ),
      );
    },
  );

  Future<void> _showConditions(
    BuildContext context,
  ) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final theme = Theme.of(context);
            final rules = controller.ruleSet.rules
                .where((rule) => rule.enabled)
                .toList();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('本次规则的具体条件', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text('以下为当前配置；历史记录仍保留通知到达时的规则和处理结果。'),
                if (!controller.globalEnabled)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('规则引擎已关闭，以下规则当前不执行。'),
                  ),
                for (var i = 0; i < rules.length; i++) ...[
                  const SizedBox(height: 18),
                  Text(
                    '${i + 1}. ${_name(rules[i])}',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text('处理：${ruleDisplayAction(rules[i].action)}'),
                  Text('匹配方式：${rules[i].mode.label}以下条件组'),
                  Text(
                    '应用：${ruleApplicationScope(rules[i], appName ?? (package) => package)}',
                  ),
                  for (final condition in ruleDisplayConditions(rules[i]))
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text('${condition.label}：${condition.value}'),
                    ),
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                ],
                const SizedBox(height: 16),
                Text(
                  '未匹配通知：${_defaultAction(controller.ruleSet.defaultAction)}',
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

String _name(RuleSpec rule) => rule.name.trim().isEmpty ? '未命名规则' : rule.name;

String _defaultAction(RuleAction action) => switch (action) {
  RuleAction.allow => '保留',
  RuleAction.intercept => '自动移出',
  RuleAction.logOnly => '仅记录',
};
