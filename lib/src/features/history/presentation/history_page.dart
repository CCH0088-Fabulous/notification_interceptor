import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/util/time_format.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../shared/domain/rule_action.dart';
import '../../../shared/widgets/rule_action_chip.dart';
import '../domain/history_entry.dart';
import '../domain/history_query.dart';
import 'history_controller.dart';

/// 历史记录：按动作筛选、按包名搜索、导出 JSON。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.controller});

  final HistoryController controller;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final entries = controller.entries
            .where((entry) => !entry.record.isGroupSummary)
            .toList(growable: false);
        return Column(
          children: [
            _FilterBar(
              search: _search,
              selected: controller.query.action,
              onAction: controller.setActionFilter,
              onSearch: controller.setPackageFilter,
            ),
            _Summary(
              stats: controller.stats,
              loading: controller.loading,
              onExport: () => _export(controller),
              onClear: () => _confirmClear(controller),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: controller.load,
                child: entries.isEmpty
                    ? ListView(
                        children: const [
                          SizedBox(height: 80),
                          EmptyState(
                            icon: Icons.history,
                            title: '没有匹配的记录',
                            message: '通知到达后会自动记录在这里，最多保留 1000 条。',
                          ),
                        ],
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: entries.length,
                        itemBuilder: (context, index) =>
                            _HistoryTile(entry: entries[index]),
                      ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _export(HistoryController controller) async {
    final messenger = ScaffoldMessenger.of(context);
    final json = await controller.exportJson();
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text('已复制 ${json.length} 字符的历史 JSON 到剪贴板')),
    );
  }

  Future<void> _confirmClear(HistoryController controller) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空历史'),
        content: const Text('将删除本地全部历史记录，不可恢复。'),
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
    }
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.search,
    required this.selected,
    required this.onAction,
    required this.onSearch,
  });

  final TextEditingController search;
  final RuleAction? selected;
  final Future<void> Function(RuleAction?) onAction;
  final Future<void> Function(String?) onSearch;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                FilterChip(
                  label: const Text('全部'),
                  selected: selected == null,
                  onSelected: (_) => onAction(null),
                ),
                const SizedBox(width: 6),
                ...RuleAction.values.map(
                  (action) => Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(action.label),
                      selected: selected == action,
                      onSelected: (_) => onAction(action),
                    ),
                  ),
                ),
              ],
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: search,
            builder: (context, value, _) => TextField(
              controller: search,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: '按包名筛选（回车应用）',
                suffixIcon: value.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          search.clear();
                          onSearch(null);
                        },
                      ),
              ),
              onSubmitted: (text) => onSearch(text),
            ),
          ),
        ],
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.stats,
    required this.loading,
    required this.onExport,
    required this.onClear,
  });

  final HistoryStats stats;
  final bool loading;
  final VoidCallback onExport;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
      child: Row(
        children: [
          Tooltip(
            message: '原始历史统计，包含列表中隐藏的系统分组汇总通知',
            child: Text(
              '共 ${stats.total} 条',
              style: theme.textTheme.labelMedium,
            ),
          ),
          const SizedBox(width: 12),
          ...RuleAction.values.map(
            (action) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                '${action.label} ${stats.byAction[action] ?? 0}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ),
          const Spacer(),
          if (loading)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            tooltip: '导出 JSON 到剪贴板',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy_all_outlined, size: 20),
            onPressed: onExport,
          ),
          IconButton(
            tooltip: '清空历史',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: onClear,
          ),
        ],
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record = entry.record;
    final subtitleParts = <String>[
      record.packageName,
      formatClock(entry.timestamp),
      if (entry.matchedRuleName != null) '规则「${entry.matchedRuleName}」',
      if (entry.action == RuleAction.intercept) entry.cancelStatus.label,
    ];
    return ListTile(
      dense: true,
      leading: RuleActionChip(action: entry.action, compact: true),
      title: Text(
        record.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            record.displayBody,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            subtitleParts.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
