import 'package:flutter/material.dart';

import '../../../core/util/time_format.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../shared/domain/rule_action.dart';
import '../../rules/presentation/rules_controller.dart';
import '../domain/history_entry.dart';
import '../domain/history_overview.dart';
import 'history_controller.dart';
import 'history_display.dart';
import 'history_sheets.dart';
import 'history_rules_banner.dart';
export 'history_sheets.dart' show showHistoryActions, confirmClearHistory;

class HistoryPage extends StatefulWidget {
  const HistoryPage({
    super.key,
    required this.controller,
    this.rules,
    this.appName,
  });
  final HistoryController controller;
  final RulesController? rules;
  final String Function(String)? appName;
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final _search = TextEditingController();
  @override
  void initState() {
    super.initState();
    _search.text = widget.controller.search;
    widget.controller.addListener(_syncSearch);
    widget.controller.load();
  }

  void _syncSearch() {
    final search = widget.controller.search;
    if (_search.text.trim() != search) {
      _search.value = TextEditingValue(
        text: search,
        selection: TextSelection.collapsed(offset: search.length),
      );
    }
  }

  @override
  void didUpdateWidget(covariant HistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncSearch);
      widget.controller.addListener(_syncSearch);
      _syncSearch();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncSearch);
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final theme = Theme.of(context);
      final entries = controller.entries;
      final overview = controller.overview;
      return RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            controller.load(),
            if (widget.rules != null) widget.rules!.load(),
          ]);
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.rules != null) ...[
                      HistoryRulesBanner(
                        controller: widget.rules!,
                        appName: widget.appName,
                      ),
                      const SizedBox(height: 14),
                    ],
                    _OverviewCard(
                      controller: controller,
                      overview: overview,
                      onRuleFilter: _search.clear,
                    ),
                    if (controller.loading)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: LinearProgressIndicator(),
                      ),
                    if (controller.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '历史读取失败，当前可能是上次的记录。',
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: controller.load,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _search,
                            onChanged: controller.setSearch,
                            textInputAction: TextInputAction.search,
                            decoration: InputDecoration(
                              hintText: '搜索标题、内容或应用',
                              hintStyle: theme.textTheme.bodySmall,
                              prefixIcon: const Icon(Icons.search, size: 20),
                              suffixIcon: controller.search.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: '清除搜索',
                                      icon: const Icon(Icons.close, size: 18),
                                      onPressed: () {
                                        _search.clear();
                                        controller.setSearch('');
                                      },
                                    ),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 12,
                                horizontal: 12,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.outlined(
                          tooltip: '筛选记录',
                          icon: const Icon(Icons.filter_list),
                          style: IconButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () => showHistoryFilters(
                            context,
                            controller,
                            onReset: _search.clear,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final action in <RuleAction?>[
                          null,
                          ...RuleAction.values,
                        ])
                          ChoiceChip(
                            key: ValueKey(
                              'history-action-${action?.wire ?? 'all'}',
                            ),
                            showCheckmark: false,
                            label: Text(
                              action == null
                                  ? '全部'
                                  : action == RuleAction.allow
                                  ? '保留'
                                  : action.label,
                            ),
                            selected: controller.query.action == action,
                            onSelected: (_) =>
                                controller.setActionFilter(action),
                          ),
                      ],
                    ),
                    if (controller.query.packageName != null ||
                        controller.ruleFilter != null)
                      Wrap(
                        spacing: 8,
                        children: [
                          if (controller.query.packageName != null)
                            InputChip(
                              label: Text(
                                controller.applications[controller
                                        .query
                                        .packageName] ??
                                    controller.query.packageName!,
                              ),
                              onDeleted: () =>
                                  controller.setPackageFilter(null),
                            ),
                          if (controller.ruleFilter != null)
                            InputChip(
                              label: const Text('同规则记录'),
                              onDeleted: () => controller.setRuleFilter(null),
                            ),
                        ],
                      ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '通知记录',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '${entries.length} 条 · ${controller.period.label}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
            if (entries.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: EmptyState(
                    icon: Icons.history,
                    title: controller.loading ? '正在读取记录' : '没有匹配的记录',
                    message: '可调整搜索或筛选条件，或发送一条新通知。',
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverList.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) => _HistoryCard(
                    entry: entries[index],
                    onTap: () => showHistoryDetail(
                      context,
                      controller,
                      entries[index],
                      onRuleFilter: _search.clear,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({
    required this.controller,
    required this.overview,
    required this.onRuleFilter,
  });
  final HistoryController controller;
  final HistoryOverview overview;
  final VoidCallback onRuleFilter;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '处理概览',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                DropdownButton<HistoryPeriod>(
                  key: const ValueKey('history-period'),
                  value: controller.period,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.primary,
                  ),
                  items: HistoryPeriod.values
                      .map(
                        (p) => DropdownMenuItem(value: p, child: Text(p.label)),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) controller.setPeriod(value);
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _Metric(
                    label: '拦截数',
                    value: '${overview.removed}',
                    unit: '条',
                    emphasis: true,
                  ),
                ),
                Expanded(
                  child: _Metric(
                    label: '拦截率',
                    value: historyPercent(overview.removedRate),
                  ),
                ),
                Expanded(
                  child: _Metric(
                    label: '保留数',
                    value: '${overview.kept}',
                    unit: '条',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: LinearProgressIndicator(
                value: overview.removedRate,
                minHeight: 7,
                color: scheme.primary,
                backgroundColor: scheme.primaryContainer,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '共 ${overview.total} 条记录',
                  style: theme.textTheme.bodySmall,
                ),
                TextButton(
                  onPressed: () => showHistoryRuleEffects(
                    context,
                    controller,
                    onRuleFilter: onRuleFilter,
                  ),
                  child: const Text('规则效果 ›'),
                ),
              ],
            ),
            Text(
              '仅统计本地保留记录，不含系统分组汇总',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (overview.unconfirmed > 0 || overview.logOnly > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  [
                    if (overview.unconfirmed > 0)
                      '${overview.unconfirmed} 条未确认移出成功',
                    if (overview.logOnly > 0) '${overview.logOnly} 条仅记录',
                  ].join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                onTap: () => showHistoryMetricHelp(context),
                child: Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Text(
                    '统计说明',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.unit = '',
    this.emphasis = false,
  });
  final String label, value, unit;
  final bool emphasis;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          const SizedBox(height: 5),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text.rich(
              TextSpan(
                text: value,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: emphasis ? theme.colorScheme.primary : null,
                ),
                children: [
                  if (unit.isNotEmpty)
                    TextSpan(text: ' $unit', style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.entry, required this.onTap});
  final HistoryEntry entry;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      key: ValueKey('history-${entry.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  HistoryResultBadge(entry: entry),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry.record.displayApp,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    formatClock(entry.timestamp),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              Text(
                entry.record.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                entry.record.displayBody,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
              ),
              const SizedBox(height: 8),
              Divider(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: .4),
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${historyResultDescription(entry)} · ${historyRuleName(entry)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 18),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
