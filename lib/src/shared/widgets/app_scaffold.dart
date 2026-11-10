import 'package:flutter/material.dart';

import '../../features/access/presentation/access_controller.dart';
import '../../features/feed/presentation/feed_controller.dart';
import '../../features/feed/presentation/feed_page.dart';
import '../../features/history/presentation/history_controller.dart';
import '../../features/history/presentation/history_page.dart';
import '../../features/presets/presentation/presets_controller.dart';
import '../../features/presets/presentation/presets_page.dart';
import '../../features/comparison/presentation/batch_comparison_controller.dart';
import '../../features/comparison/presentation/batch_comparison_page.dart';
import '../../features/research/presentation/research_controller.dart';
import '../../features/research/presentation/research_page.dart';
import '../domain/usage_recorder.dart';
import '../../features/presets/domain/filter_preset.dart';
import '../../features/rules/domain/rule_spec.dart';
import '../../features/rules/domain/simple_rule_draft.dart';
import '../../features/feed/domain/notification_record.dart';
import '../../features/rules/presentation/rule_wizard_page.dart';
import '../../features/rules/presentation/rule_editor_page.dart';
import '../../features/rules/presentation/rules_controller.dart';
import '../../features/rules/presentation/rules_page.dart';
import '../../features/settings/presentation/settings_page.dart';

/// 顶层脚手架：底部导航、规则创建入口与生命周期刷新。
class AppScaffold extends StatefulWidget {
  const AppScaffold({
    super.key,
    required this.access,
    required this.feed,
    required this.rules,
    required this.history,
    this.presets,
    this.comparison,
    this.research,
  });

  final AccessController access;
  final FeedController feed;
  final RulesController rules;
  final HistoryController history;
  final PresetsController? presets;
  final BatchComparisonController? comparison;
  final ResearchController? research;

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
  Widget build(BuildContext context) => _buildScaffold(context);

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
        actions: [
          if (_index == 1 && widget.presets != null)
            IconButton(
              tooltip: '预设 · 高级功能',
              icon: const Icon(Icons.bookmarks_outlined),
              onPressed: _openPresets,
            ),
          if (_index == 2)
            ListenableBuilder(
              listenable: widget.history,
              builder: (context, _) => TextButton.icon(
                onPressed: widget.history.loading
                    ? null
                    : () => confirmClearHistory(context, widget.history),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('清空'),
              ),
            ),
          if (_index == 1)
            PopupMenuButton<String>(
              tooltip: '更多操作',
              onSelected: (value) {
                if (value == 'advanced') _openAdvancedEditor();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'advanced', child: Text('高级创建')),
              ],
            ),
          if (_index == 2)
            IconButton(
              tooltip: '更多操作',
              icon: const Icon(Icons.more_vert),
              onPressed: () => showHistoryActions(context, widget.history),
            ),
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
            appName: _appName,
          ),
          HistoryPage(
            controller: widget.history,
            rules: widget.rules,
            appName: _appName,
          ),
          SettingsPage(
            access: widget.access,
            history: widget.history,
            rules: widget.rules,
            onOpenPresets: widget.presets == null ? null : _openPresets,
            onOpenResearch: widget.research == null ? null : _openResearch,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) {
          if (value != _index) {
            widget.research?.record(
              [
                UsageAction.pageFeed,
                UsageAction.pageRules,
                UsageAction.pageHistory,
                UsageAction.pageSettings,
              ][value],
            );
          }
          setState(() => _index = value);
          if (value == 2) {
            widget.history.load();
            widget.rules.load();
          }
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

  String _appName(String package) {
    for (final record in [
      ...widget.feed.items.map((item) => item.record),
      ...widget.history.allEntries.map((entry) => entry.record),
    ]) {
      if (record.packageName == package &&
          (record.appLabel?.trim().isNotEmpty ?? false)) {
        return record.appLabel!.trim();
      }
    }
    return package;
  }

  Future<void> _openPresets() async {
    final controller = widget.presets;
    if (controller == null) return;
    widget.research?.record(UsageAction.openPresets);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PresetsPage(
          controller: controller,
          refreshRules: widget.rules.load,
          loadPackages: () async {
            await widget.rules.loadSeenPackages();
            if (widget.rules.error != null) throw StateError('应用列表读取失败');
            return widget.rules.seenPackages;
          },
          appName: _appName,
          onCompare: widget.comparison == null ? null : _openComparison,
        ),
      ),
    );
  }

  Future<void> _openComparison(FilterPreset? preset) async {
    final controller = widget.comparison;
    if (controller == null) return;
    widget.research?.record(UsageAction.openComparison);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BatchComparisonPage(
          controller: controller,
          initialPresetId: preset?.id,
        ),
      ),
    );
  }

  Future<void> _openResearch() async {
    final controller = widget.research;
    if (controller == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => ResearchPage(controller: controller)),
    );
  }

  Future<List<NotificationRecord>> _ruleSamples() async {
    final active = await widget.feed.loadSamples();
    await widget.history.load();
    if (widget.history.error != null) throw StateError('历史读取失败');
    final records = <String, NotificationRecord>{};
    for (final record in [
      ...widget.history.allEntries.map((entry) => entry.record),
      ...widget.feed.items.map((item) => item.record),
      ...active,
    ]) {
      if (record.key.isNotEmpty &&
          record.packageName.trim().isNotEmpty &&
          !record.isGroupSummary) {
        records[record.key] = record;
      }
    }
    return records.values.toList()
      ..sort((a, b) => b.postTime.compareTo(a.postTime));
  }

  Future<void> _openEditor([RuleSpec? initial]) async {
    await widget.rules.load();
    if (!mounted) return;
    if (widget.rules.error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('规则读取失败，请重试')));
      return;
    }
    if (initial != null && !SimpleRuleDraft.canEdit(initial)) {
      await _openAdvancedEditor(initial);
      return;
    }
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => RuleWizardPage(
          controller: widget.rules,
          initial: initial,
          loadPackages: () async {
            await widget.rules.loadSeenPackages();
            if (widget.rules.error != null) throw StateError('应用列表读取失败');
            return widget.rules.seenPackages;
          },
          loadSamples: _ruleSamples,
        ),
      ),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('规则已保存')));
    }
  }

  Future<void> _openAdvancedEditor([RuleSpec? initial]) async {
    final result = await Navigator.of(context).push<RuleSpec>(
      MaterialPageRoute(
        builder: (context) => RuleEditorPage(
          initial: initial,
          loadPackages: () async {
            await widget.rules.loadSeenPackages();
            if (widget.rules.error != null) throw StateError('应用列表读取失败');
            return widget.rules.seenPackages;
          },
          loadSamples: _ruleSamples,
          evaluate: (sample, draft) =>
              widget.rules.evaluate(sample, draft: draft),
        ),
      ),
    );
    if (result != null) await widget.rules.upsert(result);
  }
}
