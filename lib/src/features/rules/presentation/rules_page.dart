import 'package:flutter/material.dart';

import '../../../core/widgets/empty_state.dart';
import '../../../shared/domain/rule_action.dart';
import '../domain/rule_spec.dart';
import 'rule_display.dart';
import 'rules_controller.dart';

enum _RuleFilter { all, keep, drop, disabled }

/// 分类只影响展示，规则始终按原列表中的顺序执行。
class RulesPage extends StatefulWidget {
  const RulesPage({
    super.key,
    required this.controller,
    required this.onCreate,
    required this.onEdit,
    this.appName,
  });
  final RulesController controller;
  final VoidCallback onCreate;
  final void Function(RuleSpec rule) onEdit;
  final String Function(String package)? appName;
  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  _RuleFilter _filter = _RuleFilter.all;
  RulesController get controller => widget.controller;
  String _appName(String package) => widget.appName?.call(package) ?? package;
  bool _matches(RuleSpec rule, _RuleFilter filter) => switch (filter) {
    _RuleFilter.all => true,
    _RuleFilter.keep => rule.action == RuleAction.allow,
    _RuleFilter.drop => rule.action == RuleAction.intercept,
    _RuleFilter.disabled => !rule.enabled,
  };
  String _filterLabel(_RuleFilter filter) => switch (filter) {
    _RuleFilter.all => '全部',
    _RuleFilter.keep => '保留',
    _RuleFilter.drop => '移出',
    _RuleFilter.disabled => '已停用',
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (controller.loading && controller.ruleSet.rules.isEmpty) {
        return const Center(child: CircularProgressIndicator());
      }
      final rules = controller.ruleSet.rules;
      final visible = rules.indexed.where((item) => _matches(item.$2, _filter));
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.primaryContainer,
              foregroundColor: scheme.onPrimaryContainer,
              minimumSize: const Size.fromHeight(54),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              textStyle: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            onPressed: widget.onCreate,
            icon: const Icon(Icons.add),
            label: const Text('新建规则'),
          ),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            color: scheme.surfaceContainerHigh,
            child: SwitchListTile(
              title: Text(controller.globalEnabled ? '过滤已开启' : '过滤已关闭'),
              subtitle: Text(
                controller.globalEnabled
                    ? '${rules.where((r) => r.enabled).length} 条规则已启用'
                    : '所有通知照常保留，仍记录到历史',
              ),
              value: controller.globalEnabled,
              onChanged: controller.setGlobalEnabled,
            ),
          ),
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                controller.error!,
                style: TextStyle(color: scheme.error),
              ),
            ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final filter in _RuleFilter.values)
                ChoiceChip(
                  key: ValueKey('filter-${filter.name}'),
                  showCheckmark: false,
                  label: Text(
                    '${_filterLabel(filter)} ${rules.where((r) => _matches(r, filter)).length}',
                  ),
                  selected: _filter == filter,
                  onSelected: (_) => setState(() => _filter = filter),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _filter == _RuleFilter.all
                ? '按顺序处理；首条匹配生效。未匹配时：${_defaultActionLabel(controller.ruleSet.defaultAction)}。'
                : '仅筛选显示，编号仍对应完整执行顺序。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  _filter == _RuleFilter.all
                      ? '已设置的规则'
                      : '${_filterLabel(_filter)}规则',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text('${visible.length} 条', style: theme.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 8),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: EmptyState(
                icon: Icons.rule,
                title: rules.isEmpty ? '还没有规则' : '没有${_filterLabel(_filter)}规则',
                message: rules.isEmpty ? '点击上方「新建规则」开始设置。' : '切换分类可查看其他规则。',
              ),
            )
          else
            for (final (index, rule) in visible)
              _RuleCard(
                rule: rule,
                ordinal: index + 1,
                appName: _appName,
                issues: controller
                    .issuesFor(rule.id)
                    .map((i) => i.message)
                    .toList(),
                onToggle: (value) => controller.setRuleEnabled(rule.id, value),
                onTap: () => _showDetails(rule.id),
                onEdit: () => widget.onEdit(rule),
                onDelete: () => _confirmDelete(rule),
              ),
        ],
      );
    },
  );

  Future<void> _confirmDelete(RuleSpec rule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除规则'),
        content: Text('确定删除「${rule.name}」？该操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.remove(rule.id);
  }

  Future<void> _showDetails(String id) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (sheetContext) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final index = controller.ruleSet.rules.indexWhere((r) => r.id == id);
        if (index < 0) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Text('此规则已删除'),
          );
        }
        final rule = controller.ruleSet.rules[index];
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  rule.name.isEmpty ? '未命名规则' : rule.name,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _ActionBadge(action: rule.action),
                ),
                const SizedBox(height: 12),
                _DetailRow(
                  label: '应用范围',
                  value: ruleApplicationScope(rule, _appName),
                ),
                if (rule.packages.isNotEmpty)
                  _DetailRow(label: '应用包名', value: rule.packages.join('\n')),
                _DetailRow(
                  label: '条件组合',
                  value: rule.mode == MatchMode.all
                      ? '全部条件组都满足'
                      : '任意一个条件组满足（包括应用范围）',
                ),
                if (rule.keywordsAny.isNotEmpty)
                  const _DetailRow(label: '关键词匹配', value: '标题或正文出现任意一个关键词'),
                for (final condition in ruleDisplayConditions(rule))
                  _DetailRow(label: condition.label, value: condition.value),
                if (rule.channelIds.isNotEmpty)
                  _DetailRow(label: '渠道 ID', value: rule.channelIds.join('\n')),
                _DetailRow(
                  label: '执行顺序',
                  value:
                      '第 ${index + 1} 条 / 共 ${controller.ruleSet.rules.length} 条',
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用状态'),
                  subtitle: Text(rule.enabled ? '已启用' : '已停用'),
                  value: rule.enabled,
                  onChanged: (value) => controller.setRuleEnabled(id, value),
                ),
                if (controller.error != null)
                  Text(
                    controller.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                for (final issue in controller.issuesFor(id))
                  Text(
                    issue.message,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    controller.globalEnabled
                        ? '通知按完整列表从上到下处理。只有前面的已启用规则未匹配时，才会轮到这条规则。'
                        : '过滤已关闭。这条规则当前不会生效，所有通知照常保留。',
                  ),
                ),
                FilledButton.tonal(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    widget.onEdit(rule);
                  },
                  child: const Text('编辑规则'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(sheetContext),
                  child: const Text('关闭'),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

String _defaultActionLabel(RuleAction action) => switch (action) {
  RuleAction.allow => '照常保留',
  RuleAction.intercept => '自动移出',
  RuleAction.logOnly => '仅记录',
};

class _RuleCard extends StatelessWidget {
  const _RuleCard({
    required this.rule,
    required this.ordinal,
    required this.appName,
    required this.issues,
    required this.onToggle,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });
  final RuleSpec rule;
  final int ordinal;
  final String Function(String) appName;
  final List<String> issues;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap, onEdit, onDelete;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      key: ValueKey('rule-${rule.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12, right: 10),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$ordinal',
                  key: ValueKey('ordinal-${rule.id}'),
                  style: theme.textTheme.labelMedium,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            rule.name.isEmpty ? '未命名规则' : rule.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: rule.enabled
                                  ? scheme.onSurface
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 48,
                          child: Transform.scale(
                            scale: .8,
                            child: Switch(
                              key: ValueKey('toggle-${rule.id}'),
                              value: rule.enabled,
                              onChanged: onToggle,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 32,
                          child: PopupMenuButton<String>(
                            padding: EdgeInsets.zero,
                            tooltip: '规则操作',
                            onSelected: (value) {
                              if (value == 'edit') onEdit();
                              if (value == 'delete') onDelete();
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'edit', child: Text('编辑')),
                              PopupMenuItem(value: 'delete', child: Text('删除')),
                            ],
                          ),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '应用：${ruleApplicationScope(rule, appName)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        _ActionBadge(action: rule.action),
                        if (!rule.enabled)
                          Text('已停用', style: theme.textTheme.labelSmall),
                      ],
                    ),
                    const SizedBox(height: 6),
                    for (final condition in ruleDisplayConditions(rule))
                      Padding(
                        padding: const EdgeInsets.only(top: 2, right: 8),
                        child: Text(
                          '${condition.label}  ${condition.value}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (rule.mode == MatchMode.any)
                      Text(
                        '任意条件组满足即可',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.primary,
                        ),
                      ),
                    if (issues.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6, right: 8),
                        child: Text(
                          issues.join('；'),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionBadge extends StatelessWidget {
  const _ActionBadge({required this.action});
  final RuleAction action;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final drop = action == RuleAction.intercept;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: drop
            ? scheme.errorContainer
            : action == RuleAction.allow
            ? scheme.primaryContainer
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        ruleDisplayAction(action),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: drop ? scheme.onErrorContainer : scheme.onSurface,
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 14),
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: .5),
        ),
      ),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}
