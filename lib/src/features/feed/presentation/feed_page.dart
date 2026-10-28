import 'package:flutter/material.dart';

import '../../access/presentation/access_controller.dart';
import '../../../core/widgets/empty_state.dart';
import '../domain/feed_item.dart';
import 'feed_controller.dart';
import 'widgets/notification_card.dart';

/// 实时通知流：权限引导 + 实时列表。
class FeedPage extends StatelessWidget {
  const FeedPage({super.key, required this.feed, required this.access});

  final FeedController feed;
  final AccessController access;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([feed, access]),
      builder: (context, _) {
        final status = access.status;
        final items = feed.items
            .where((item) => !item.record.isGroupSummary)
            .toList(growable: false);
        return Column(
          children: [
            if (!status.granted)
              _PermissionBanner(
                title: '尚未授予「通知使用权」',
                message: '需要该权限才能读取与取消其他应用的通知。授权后返回本页即可生效。',
                actionLabel: '去授权',
                onAction: access.openSettings,
                isError: true,
              )
            else if (!status.connected)
              _PermissionBanner(
                title: '已授权，但监听服务未连接',
                message: '系统尚未绑定监听服务。点「重新连接」或重新开关一次通知使用权。',
                actionLabel: '重新连接',
                onAction: access.requestRebind,
                isError: false,
              )
            else
              _ListeningBar(
                intercepted: items
                    .where((item) => item.decision?.shouldIntercept ?? false)
                    .length,
                total: items.length,
              ),
            _Toolbar(
              loading: feed.loading,
              onRefresh: feed.refreshActive,
              onClear: feed.clearList,
            ),
            if (feed.error != null)
              _ErrorRow(message: feed.error!, onRetry: feed.refreshActive),
            Expanded(
              child: items.isEmpty
                  ? EmptyState(
                      icon: Icons.notifications_none,
                      title: '还没有收到通知',
                      message: status.granted
                          ? '等待其他应用发出通知，或点上方刷新拉取当前活动通知。'
                          : '完成授权后，这里会实时显示其他应用的通知。',
                      action: status.granted
                          ? null
                          : FilledButton(
                              onPressed: access.openSettings,
                              child: const Text('去授权'),
                            ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        return NotificationCard(
                          item: item,
                          onCancel: () => _cancel(context, item),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _cancel(BuildContext context, FeedItem item) async {
    final messenger = ScaffoldMessenger.of(context);
    final cancelled = await feed.cancel(item.record);
    messenger.showSnackBar(
      SnackBar(content: Text(cancelled ? '已请求取消通知' : '取消失败：服务未连接或无权限')),
    );
  }
}

class _ListeningBar extends StatelessWidget {
  const _ListeningBar({required this.intercepted, required this.total});

  final int intercepted;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.hearing, size: 18, color: scheme.onPrimaryContainer),
          const SizedBox(width: 8),
          Text(
            '监听中',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: scheme.onPrimaryContainer),
          ),
          const Spacer(),
          Text(
            '本次会话：$total 条 · 拦截 $intercepted 条',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.onPrimaryContainer),
          ),
        ],
      ),
    );
  }
}

class _PermissionBanner extends StatelessWidget {
  const _PermissionBanner({
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
    required this.isError,
  });

  final String title;
  final String message;
  final String actionLabel;
  final Future<void> Function() onAction;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = isError
        ? scheme.errorContainer
        : scheme.secondaryContainer;
    final foreground = isError
        ? scheme.onErrorContainer
        : scheme.onSecondaryContainer;
    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.lock_outline : Icons.link_off,
            color: foreground,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(color: foreground),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: foreground),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(onPressed: onAction, child: Text(actionLabel)),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.loading,
    required this.onRefresh,
    required this.onClear,
  });

  final bool loading;
  final Future<void> Function() onRefresh;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
      child: Row(
        children: [
          Text('实时通知', style: Theme.of(context).textTheme.titleSmall),
          const Spacer(),
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: '刷新活动通知',
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
            ),
          IconButton(
            tooltip: '清空列表（不影响历史）',
            onPressed: onClear,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
