import 'package:flutter/material.dart';

import '../core/channel/interceptor_channel.dart';
import '../features/access/data/native_access_repository.dart';
import '../features/access/presentation/access_controller.dart';
import '../features/feed/data/native_feed_repository.dart';
import '../features/feed/presentation/feed_controller.dart';
import '../features/history/data/native_history_repository.dart';
import '../features/history/presentation/history_controller.dart';
import '../features/rules/data/native_rules_repository.dart';
import '../features/rules/presentation/rules_controller.dart';
import '../shared/widgets/app_scaffold.dart';
import 'theme.dart';

/// 组装点：仓储 → 控制器 → 界面。除这里之外没有全局单例。
class NotifInterceptorApp extends StatefulWidget {
  const NotifInterceptorApp({super.key, required this.channel});

  final InterceptorChannel channel;

  @override
  State<NotifInterceptorApp> createState() => _NotifInterceptorAppState();
}

class _NotifInterceptorAppState extends State<NotifInterceptorApp> {
  late final AccessController _access;
  late final FeedController _feed;
  late final RulesController _rules;
  late final HistoryController _history;

  @override
  void initState() {
    super.initState();
    final channel = widget.channel;
    _access = AccessController(
      repository: NativeAccessRepository(channel),
      events: channel.events,
    );
    _feed = FeedController(
      repository: NativeFeedRepository(channel),
      events: channel.events,
    );
    _rules = RulesController(repository: NativeRulesRepository(channel));
    _history = HistoryController(repository: NativeHistoryRepository(channel));

    _access.refresh();
    _feed.refreshActive();
    _rules.load();
    _history.load();
  }

  @override
  void dispose() {
    _access.dispose();
    _feed.dispose();
    _rules.dispose();
    _history.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '通知拦截器',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: AppScaffold(
        access: _access,
        feed: _feed,
        rules: _rules,
        history: _history,
      ),
    );
  }
}
