import 'package:flutter/material.dart';

import '../../../../core/util/time_format.dart';
import '../../../../shared/widgets/rule_action_chip.dart';
import '../../domain/feed_item.dart';

/// 实时流单条通知卡片。点击展开完整字段与 extras。
class NotificationCard extends StatelessWidget {
  const NotificationCard({
    super.key,
    required this.item,
    required this.onCancel,
  });

  final FeedItem item;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record = item.record;
    final decision = item.decision;
    final dimmed = item.removed;

    return Opacity(
      opacity: dimmed ? 0.55 : 1,
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _showDetails(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      child: Text(
                        record.displayApp.isEmpty
                            ? '?'
                            : record.displayApp.substring(0, 1),
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            record.displayApp,
                            style: theme.textTheme.labelMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            record.packageName,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.outline),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Text(
                      formatRelative(record.postTime),
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  record.displayTitle,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  record.displayBody,
                  style: theme.textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (decision != null) RuleActionChip(action: decision.action),
                    if (item.removed)
                      _Tag(text: '已移除', color: theme.colorScheme.outline)
                    else if (item.existing)
                      _Tag(text: '存量', color: theme.colorScheme.outline),
                    if (record.channelName != null)
                      _Tag(text: record.channelName!, color: theme.colorScheme.secondary),
                    if (record.isOngoing)
                      _Tag(text: '常驻', color: theme.colorScheme.tertiary),
                    if (!record.isClearable)
                      _Tag(text: '不可清除', color: theme.colorScheme.error),
                    if (decision != null)
                      Text(
                        decision.describe(),
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                  ],
                ),
                if (!item.removed)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: onCancel,
                      icon: const Icon(Icons.close, size: 16),
                      label: const Text('取消通知'),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showDetails(BuildContext context) {
    final record = item.record;
    final theme = Theme.of(context);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          children: [
            Text(record.displayTitle, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(record.displayBody, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            if (item.decision != null)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.rule),
                title: Text(item.decision!.describe()),
                trailing: RuleActionChip(action: item.decision!.action),
              ),
            _kv(context, '包名', record.packageName),
            _kv(context, 'key', record.key),
            _kv(context, '通知 id', '${record.id}'),
            _kv(
              context,
              '时间',
              '${formatClock(record.postTime)} · ${formatRelative(record.postTime)}',
            ),
            _kv(
              context,
              '渠道',
              '${record.channelId ?? '-'} / ${record.channelName ?? '-'}',
            ),
            _kv(context, '分类', record.category ?? '-'),
            _kv(context, '分组', record.groupKey ?? '-'),
            _kv(context, '优先级', '${record.priority}'),
            _kv(context, 'progress', '${record.progress}'),
            _kv(
              context,
              '标记',
              [
                if (record.isOngoing) 'ongoing',
                if (!record.isClearable) 'no-clear',
                if (record.isGroupSummary) 'group-summary',
              ].join(', '),
            ),
            if (record.bigText != null) _kv(context, 'bigText', record.bigText!),
            if (record.textLines.isNotEmpty)
              _kv(context, 'textLines', record.textLines.join('\n')),
            if (record.extras.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('extras（调试）', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              ...record.extras.entries.map(
                (entry) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${entry.key}: ${entry.value}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            ],
            if (item.decision != null) ...[
              const SizedBox(height: 12),
              Text('判定来源：${item.decision!.reason}', style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                onCancel();
              },
              icon: const Icon(Icons.close),
              label: const Text('取消这条通知'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(BuildContext context, String key, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(key, style: theme.textTheme.labelSmall),
          ),
          Expanded(
            child: SelectableText(value, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}
