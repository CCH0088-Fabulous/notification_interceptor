import 'package:flutter/material.dart';

import '../../../core/widgets/empty_state.dart';
import '../../../shared/widgets/rule_action_chip.dart';
import '../domain/rule_set.dart';
import '../domain/rule_spec.dart';
import 'rules_controller.dart';

/// 规则列表：全局开关、单条启用/禁用、编辑与删除。
class RulesPage extends StatelessWidget {
  const RulesPage({
    super.key,
    required this.controller,
    required this.onCreate,
    required this.onEdit,
  });

  final RulesController controller;
  final VoidCallback onCreate;
  final void Function(RuleSpec rule) onEdit;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.loading && controller.ruleSet.rules.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          children: [
            _GlobalSwitch(controller: controller),
            if (controller.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  controller.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 8),
            if (controller.ruleSet.rules.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 48),
                child: EmptyState(
                  icon: Icons.rule,
                  title: '还没有规则',
                  message: '规则按顺序求值，首个命中即生效。\n右下角可以新建第一条规则。',
                ),
              )
            else
              ...controller.ruleSet.rules.map(
                (rule) => _RuleCard(
                  rule: rule,
                  issues: controller.issuesFor(rule.id),
                  onToggle: (value) => controller.setRuleEnabled(rule.id, value),
                  onEdit: () => onEdit(rule),
                  onDelete: () => _confirmDelete(context, rule),
                ),
              ),
            const SizedBox(height: 16),
            Text(
              '求值顺序：自上而下，首个命中即停止。未命中的通知按默认动作「${controller.ruleSet.defaultAction.label}」处理。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmDelete(BuildContext context, RuleSpec rule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除规则'),
        content: Text('确定删除「${rule.name}」？该操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.remove(rule.id);
    }
  }
}

class _GlobalSwitch extends StatelessWidget {
  const _GlobalSwitch({required this.controller});

  final RulesController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHigh,
      child: SwitchListTile(
        title: const Text('启用规则引擎'),
        subtitle: const Text('关闭后所有通知一律放行（仍会记录到历史）'),
        value: controller.globalEnabled,
        onChanged: controller.setGlobalEnabled,
      ),
    );
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({
    required this.rule,
    required this.issues,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final RuleSpec rule;
  final List<RuleIssue> issues;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      rule.name.isEmpty ? '(未命名规则)' : rule.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: rule.enabled ? null : theme.colorScheme.outline,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  RuleActionChip(action: rule.action),
                  Switch(value: rule.enabled, onChanged: onToggle),
                  PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'edit') onEdit();
                      if (value == 'delete') onDelete();
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 0, right: 8),
                child: Text(
                  rule.summary,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
              if (issues.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6, right: 8),
                  child: Text(
                    issues.map((issue) => issue.message).join('；'),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
