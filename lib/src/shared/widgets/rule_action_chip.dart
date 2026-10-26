import 'package:flutter/material.dart';

import '../domain/rule_action.dart';

/// 动作标签，实时流 / 规则列表 / 历史页共用。
class RuleActionChip extends StatelessWidget {
  const RuleActionChip({super.key, required this.action, this.compact = false});

  final RuleAction action;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (color, background) = switch (action) {
      RuleAction.allow => (scheme.primary, scheme.primaryContainer),
      RuleAction.intercept => (scheme.error, scheme.errorContainer),
      RuleAction.logOnly => (scheme.tertiary, scheme.tertiaryContainer),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: compact ? 2 : 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        action.label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}
