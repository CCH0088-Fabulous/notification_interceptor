import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/domain/rule_action.dart';
import '../../../shared/util/notification_channel_label.dart';
import '../domain/history_entry.dart';
import '../domain/history_overview.dart';
import 'history_controller.dart';
import 'history_display.dart';

Future<void> _sheet(BuildContext context, Widget child) =>
    showModalBottomSheet<void>(
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
          child: child,
        ),
      ),
    );

Widget _title(BuildContext context, String text) => Text(
  text,
  style: Theme.of(
    context,
  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
);
Widget _note(BuildContext context, String text) => Container(
  margin: const EdgeInsets.symmetric(vertical: 16),
  padding: const EdgeInsets.all(12),
  decoration: BoxDecoration(
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    borderRadius: BorderRadius.circular(12),
  ),
  child: Text(
    text,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.7),
  ),
);
Widget _close(BuildContext context) => TextButton(
  onPressed: () => Navigator.pop(context),
  child: const Text('关闭'),
);

class HistoryResultBadge extends StatelessWidget {
  const HistoryResultBadge({super.key, required this.entry});
  final HistoryEntry entry;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final drop = entry.action == RuleAction.intercept;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: drop ? scheme.errorContainer : scheme.primaryContainer,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        historyResultLabel(entry),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: drop ? scheme.onErrorContainer : scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

Future<void> showHistoryMetricHelp(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('统计说明'),
    content: const SingleChildScrollView(
      child: Text(
        '拦截数：系统确认已移出的记录数。\n\n拦截率：已移出记录数 ÷ 所选日期内的总记录数。未成功或待确认的移出不计入拦截数。\n\n保留数：决定照常保留的记录数；仅记录和移出失败另计。\n\n只统计本地仍保存的最近 1000 条记录，并排除系统分组汇总。它可能不是全天的完整数据。同一通知更新也可能产生多条记录。\n\n搜索、应用和处理结果筛选只影响下方列表，不改变顶部统计。',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('知道了'),
      ),
    ],
  ),
);

Future<void> showHistoryDetail(
  BuildContext context,
  HistoryController controller,
  HistoryEntry entry, {
  required VoidCallback onRuleFilter,
}) {
  final record = entry.record;
  final channel = record.channelId;
  final channelLabel =
      record.packageName == 'dev.poc.notifgen' && channel != null
      ? notificationChannelLabel(channel)
      : record.channelName ?? channel ?? '未提供';
  final date = DateTime.fromMillisecondsSinceEpoch(entry.timestamp);
  final timestamp =
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
      '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';
  return _sheet(
    context,
    Builder(
      builder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(context, '通知详情'),
          const SizedBox(height: 14),
          Row(
            children: [
              HistoryResultBadge(entry: entry),
              const SizedBox(width: 10),
              Expanded(child: Text(record.displayApp)),
            ],
          ),
          Container(
            margin: const EdgeInsets.symmetric(vertical: 16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  record.displayTitle,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                SelectableText(
                  historyFullBody(entry),
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(height: 1.7),
                ),
              ],
            ),
          ),
          _DetailRow(label: '处理结果', value: historyResultDescription(entry)),
          _DetailRow(label: '命中规则', value: historyRuleName(entry)),
          _DetailRow(label: '通知类型', value: channelLabel),
          _DetailRow(label: '记录时间', value: timestamp),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('更多信息'),
            children: [
              _DetailRow(label: '应用包名', value: record.packageName),
              _DetailRow(label: '渠道 ID', value: channel ?? '未提供'),
              _DetailRow(label: '规则 ID', value: entry.matchedRuleId ?? '未匹配规则'),
              _DetailRow(label: '记录 ID', value: entry.id),
              if (entry.note?.isNotEmpty ?? false)
                _DetailRow(label: '处理备注', value: entry.note!),
            ],
          ),
          if (entry.action == RuleAction.intercept)
            _note(context, '这里只保留通知记录，不能恢复原通知或保证打开原会话。'),
          FilledButton.tonal(
            onPressed: () {
              Navigator.pop(context);
              onRuleFilter();
              controller.resetFilters();
              controller.setRuleFilter(historyRuleKey(entry));
            },
            child: const Text('查看同规则记录'),
          ),
          _close(context),
        ],
      ),
    ),
  );
}

Future<void> showHistoryRuleEffects(
  BuildContext context,
  HistoryController controller, {
  required VoidCallback onRuleFilter,
}) => _sheet(
  context,
  ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final overview = controller.overview;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(context, '规则效果'),
          const SizedBox(height: 8),
          Text(
            '${controller.period.label} · 基于本地记录，不含系统分组汇总',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (overview.rules.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('这个时间范围还没有记录'),
            ),
          for (final rule in overview.rules)
            InkWell(
              onTap: () {
                Navigator.pop(context);
                onRuleFilter();
                controller.resetFilters();
                controller.setRuleFilter(rule.key);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            rule.name,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          rule.action == RuleAction.allow
                              ? '保留'
                              : rule.action.label,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '命中 ${rule.count} 条',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        Text(
                          '占全部 ${historyPercent(overview.total == 0 ? 0 : rule.count / overview.total)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                    if (rule.action == RuleAction.intercept)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '已移出 ${rule.removed} 条${rule.removed < rule.count ? ' · ${rule.count - rule.removed} 条未确认成功' : ''}',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                    const SizedBox(height: 9),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        minHeight: 5,
                        value: overview.total == 0
                            ? 0
                            : rule.count / overview.total,
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: .65),
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHigh,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          _note(
            context,
            '占比是该规则命中的记录数 ÷ 全部记录数，不代表判断准确率。点击规则可查看相应记录；旧记录保留当时的处理结果。',
          ),
          FilledButton.tonal(
            onPressed: () {
              Navigator.pop(context);
              onRuleFilter();
              controller.resetFilters();
              controller.setActionFilter(RuleAction.intercept);
            },
            child: const Text('查看拦截记录'),
          ),
          _close(context),
        ],
      );
    },
  ),
);

Future<void> showHistoryFilters(
  BuildContext context,
  HistoryController controller, {
  required VoidCallback onReset,
}) {
  var package = controller.query.packageName;
  var period = controller.period;
  final applications = <String, String>{};
  for (final entry in controller.allEntries) {
    if (!entry.record.isGroupSummary) {
      applications.putIfAbsent(
        entry.record.packageName,
        () => entry.record.displayApp,
      );
    }
  }
  if (package != null) applications.putIfAbsent(package, () => package!);
  return _sheet(
    context,
    StatefulBuilder(
      builder: (context, setState) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(context, '筛选记录'),
          const SizedBox(height: 8),
          Text(
            '应用筛选只影响列表，顶部统计按日期计算。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          const Text('应用'),
          const SizedBox(height: 6),
          DropdownButton<String>(
            isExpanded: true,
            value: package ?? '',
            items: [
              const DropdownMenuItem(value: '', child: Text('所有应用')),
              for (final item in applications.entries)
                DropdownMenuItem(
                  value: item.key,
                  child: Text(
                    item.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) =>
                setState(() => package = value == '' ? null : value),
          ),
          const SizedBox(height: 18),
          const Text('时间范围'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final item in HistoryPeriod.values)
                ChoiceChip(
                  label: Text(item.label),
                  selected: period == item,
                  onSelected: (_) => setState(() => period = item),
                ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton.tonal(
            onPressed: () {
              controller.setPeriod(period);
              controller.setPackageFilter(package);
              Navigator.pop(context);
            },
            child: const Text('应用筛选'),
          ),
          TextButton(
            onPressed: () {
              onReset();
              controller.resetFilters();
              Navigator.pop(context);
            },
            child: const Text('重置筛选'),
          ),
          _close(context),
        ],
      ),
    ),
  );
}

Future<void> showHistoryActions(
  BuildContext context,
  HistoryController controller,
) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.ios_share),
            title: const Text('导出记录'),
            subtitle: const Text('复制完整历史 JSON 到剪贴板'),
            onTap: () => Navigator.pop(context, 'export'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('清空历史'),
            onTap: () => Navigator.pop(context, 'clear'),
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  if (action == 'export') {
    try {
      final json = await controller.exportJson();
      await Clipboard.setData(ClipboardData(text: json));
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已复制完整历史记录')));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('导出失败，请重试')));
      }
    }
  } else if (action == 'clear') {
    await confirmClearHistory(context, controller);
  }
}

/// Both visible and overflow actions use the same confirmed, whole-history reset.
Future<void> confirmClearHistory(
  BuildContext context,
  HistoryController controller,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('清空历史'),
      content: const Text('将删除本地全部历史记录并重置统计，规则配置保留。此操作不可恢复。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('清空'),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await controller.clear();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.error == null ? '历史已清空，可开始下一轮演示' : '清空失败，请重试',
          ),
        ),
      );
    }
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 13),
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
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ],
    ),
  );
}
