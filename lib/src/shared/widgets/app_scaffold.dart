import 'package:flutter/material.dart';

import '../../features/access/presentation/access_controller.dart';
import '../../features/feed/presentation/feed_controller.dart';
import '../../features/feed/presentation/feed_page.dart';
import '../../features/history/presentation/history_controller.dart';
import '../../features/history/presentation/history_page.dart';
import '../../features/rules/domain/rule_spec.dart';
import '../../features/rules/presentation/rule_editor_page.dart';
import '../../features/rules/presentation/rules_controller.dart';
import '../../features/rules/presentation/rules_page.dart';
import '../../features/settings/presentation/settings_page.dart';

/// 顶层脚手架：底部导航 + 按 tab 变化的 FAB + 生命周期刷新。
class AppScaffold extends StatefulWidget {
  const AppScaffold({
    super.key,
    required this.access,
    required this.feed,
    required this.rules,
    required this.history,
  });

  final AccessController access;
  final FeedController feed;
  final RulesController rules;
  final HistoryController history;

  @override
  State<AppScaffold> createState() => _AppScaffoldState();
}

class _AppScaffoldState extends State<AppScaffold> with WidgetsBindingObserver {
  static const _titles = ['实时通知', '过滤规则', '历史记录', '设置'];

  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // 从系统设置页返回后需要刷新权限状态与规则。
    widget.access.refresh();
    widget.rules.load();
    widget.history.load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
        actions: [
          if (_index == 0)
            IconButton(
              tooltip: '刷新',
              onPressed: widget.feed.refreshActive,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: IndexedStack(
        index: _index,
        children: [
          FeedPage(feed: widget.feed, access: widget.access),
          RulesPage(
            controller: widget.rules,
            onCreate: () => _openEditor(),
            onEdit: _openEditor,
          ),
          HistoryPage(controller: widget.history),
          SettingsPage(
            access: widget.access,
            history: widget.history,
            rules: widget.rules,
          ),
        ],
      ),
      floatingActionButton: _index == 1
          ? FloatingActionButton.extended(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add),
              label: const Text('新建规则'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) {
          setState(() => _index = value);
          if (value == 2) widget.history.load();
          if (value == 1) widget.rules.load();
          if (value == 3) widget.access.refresh();
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.notifications_outlined),
            selectedIcon: Icon(Icons.notifications),
            label: '实时',
          ),
          NavigationDestination(
            icon: Icon(Icons.rule_outlined),
            selectedIcon: Icon(Icons.rule),
            label: '规则',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: '历史',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }

  Future<void> _openEditor([RuleSpec? initial]) async {
    final result = await Navigator.of(context).push<RuleSpec>(
      MaterialPageRoute(
        builder: (context) => RuleEditorPage(
          initial: initial,
          loadPackages: () async {
            await widget.rules.loadSeenPackages();
            return widget.rules.seenPackages;
          },
          loadSamples: widget.feed.loadSamples,
          evaluate: (sample, draft) => widget.rules.evaluate(sample, draft: draft),
        ),
      ),
    );
    if (result != null) {
      await widget.rules.upsert(result);
    }
  }
}
