import 'package:flutter/material.dart';

import '../../../core/widgets/section_card.dart';
import '../../../shared/domain/decision.dart';
import '../../../shared/domain/rule_action.dart';
import '../domain/comparison_models.dart';
import 'batch_comparison_controller.dart';

enum _RowFilter { all, action, ruleOnly }

/// Read-only replay. The selected controls and the completed result each retain
/// their own labels, so an older result is never presented as a new comparison.
class BatchComparisonPage extends StatefulWidget {
  const BatchComparisonPage({
    super.key,
    required this.controller,
    this.initialPresetId,
  });

  final BatchComparisonController controller;
  final String? initialPresetId;

  @override
  State<BatchComparisonPage> createState() => _BatchComparisonPageState();
}

class _BatchComparisonPageState extends State<BatchComparisonPage> {
  String? _presetId;
  ComparisonPeriod _period = ComparisonPeriod.all;
  int _limit = 1000;
  _RowFilter _filter = _RowFilter.all;
  int _visibleCount = 30;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _presetId = widget.initialPresetId;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final presets = controller.presets;
      final selectedId = presets.any((p) => p.id == _presetId)
          ? _presetId
          : presets.firstOrNull?.id;
      final result = controller.result;
      final busy = controller.loading || _exporting;
      final selectionChanged =
          result != null &&
          (selectedId != result.target.id ||
              _period != result.period ||
              _limit != result.limit);
      return Scaffold(
        appBar: AppBar(title: const Text('批量效果对比')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            SectionCard(
              title: '应用前检查影响',
              subtitle: '当前配置回放 → 应用预设后预计',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '对同一批历史处理记录，分别使用当前配置和预设应用后的配置回放。'
                    '时段按每条记录当时的处理时间、设备当前时区判断；'
                    '对比不会保存规则或取消通知。',
                  ),
                  const SizedBox(height: 16),
                  if (presets.isEmpty)
                    const Text('暂无预设。请返回预设页，先保存需要比较的配置。')
                  else
                    InputDecorator(
                      decoration: const InputDecoration(labelText: '待比较预设'),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          key: const Key('comparison-preset'),
                          isExpanded: true,
                          value: selectedId,
                          items: [
                            for (final preset in presets)
                              DropdownMenuItem(
                                value: preset.id,
                                child: Text(
                                  '${preset.name} · ${preset.kind.label}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: busy
                              ? null
                              : (value) => setState(() => _presetId = value),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final period in ComparisonPeriod.values)
                        ChoiceChip(
                          key: ValueKey('comparison-period-${period.name}'),
                          label: Text(period.label),
                          selected: _period == period,
                          onSelected: busy
                              ? null
                              : (_) => setState(() => _period = period),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  InputDecorator(
                    decoration: const InputDecoration(labelText: '最多比较记录数'),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        key: const Key('comparison-limit'),
                        value: _limit,
                        isExpanded: true,
                        items: [
                          for (final limit in [100, 300, 1000])
                            DropdownMenuItem(
                              value: limit,
                              child: Text('最近 $limit 条'),
                            ),
                        ],
                        onChanged: busy
                            ? null
                            : (value) => setState(() => _limit = value!),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('comparison-run'),
                    onPressed: busy || selectedId == null
                        ? null
                        : () => _run(selectedId),
                    icon: const Icon(Icons.compare_arrows, size: 18),
                    label: Text(controller.loading ? '正在对比…' : '运行批量对比'),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '数据来自本机保留的最近 1000 条历史窗口。统计的是处理记录，'
                    '同一通知的更新也可能重复出现；系统汇总不参与比较。',
                  ),
                ],
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            if (controller.error != null)
              SectionCard(
                title: '本次对比未完成',
                child: Text(
                  controller.error!,
                  key: const Key('comparison-error'),
                ),
              ),
            if (result != null) ...[
              if (controller.isStale || selectionChanged)
                SectionCard(
                  title: controller.isStale ? '请重新运行对比' : '上方选择已调整',
                  child: Text(
                    controller.isStale
                        ? (controller.error != null
                              ? '最近一次对比未完成，下面保留的是上次结果，请重新运行。'
                              : '配置已变化，下面保留的是上次结果，不能代表当前配置。')
                        : '下面仍是「${result.target.name}」的已完成结果，尚未对新的选择运行比较。',
                    key: const Key('comparison-stale'),
                  ),
                ),
              _overview(result, busy || controller.isStale || selectionChanged),
              if (result.baseIssues.isNotEmpty ||
                  result.candidateIssues.isNotEmpty)
                _warnings(result),
              if (result.sampleCount > 0) ...[
                _matrix(result),
                _applications(result),
                _samples(result),
              ],
            ] else if (!busy && controller.error == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('选择预设并运行对比，查看哪些处理结果会发生变化。'),
              ),
          ],
        ),
      );
    },
  );

  Widget _overview(BatchComparisonResult result, bool exportDisabled) =>
      SectionCard(
        title: '对比结果 · ${result.target.name}',
        subtitle:
            '${result.period.label} · 最多 ${result.limit} 条 · ${result.zoneId}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '本地范围 ${result.sourceCount} 条；实际比较 ${result.sampleCount} 条记录，'
              '排除 ${result.skippedSummaries} 条系统汇总、${result.skippedOngoing} 条常驻通知。',
              key: const Key('comparison-sample-count'),
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = (constraints.maxWidth - 12) / 2;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _metric('动作变化', result.actionChangedCount, width),
                    _metric('新增预计移除', result.moreInterceptedCount, width),
                    _metric('不再预计移除', result.lessInterceptedCount, width),
                    _metric('仅命中规则变化', result.onlyRuleChangedCount, width),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            const Text('以上为规则回放预测；“预计移除”不代表 Android 已实际取消通知。'),
            if (result.hiddenContentCount > 0) ...[
              const SizedBox(height: 8),
              Text('其中 ${result.hiddenContentCount} 条正文被系统隐藏，只能依据可读取内容判断。'),
            ],
            if (result.sampleCount == 0) ...[
              const SizedBox(height: 12),
              const Text('此范围内没有可比较的具体通知记录。可扩大时间范围，或先让应用产生通知。'),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('comparison-export'),
              onPressed: exportDisabled ? null : _export,
              icon: const Icon(Icons.file_download_outlined, size: 18),
              label: const Text('导出对比数据 JSON'),
            ),
          ],
        ),
      );

  Widget _metric(String title, int value, double width) => SizedBox(
    width: width,
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$value', style: Theme.of(context).textTheme.headlineSmall),
          Text(title, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ),
  );

  Widget _warnings(BatchComparisonResult result) => SectionCard(
    title: '规则校验提示',
    child: ExpansionTile(
      key: const Key('comparison-warnings'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      expandedAlignment: Alignment.centerLeft,
      title: Text(
        '${result.baseIssues.length + result.candidateIssues.length} 项提示',
      ),
      subtitle: const Text('回放沿用当前引擎行为；请结合具体条件检查这些提示。'),
      children: [
        for (final issue in result.baseIssues)
          Text('当前配置 · ${issue.ruleId}：${issue.message}'),
        for (final issue in result.candidateIssues)
          Text('预设应用后 · ${issue.ruleId}：${issue.message}'),
      ],
    ),
  );

  Widget _matrix(BatchComparisonResult result) {
    const actions = [
      RuleAction.allow,
      RuleAction.intercept,
      RuleAction.logOnly,
    ];
    return SectionCard(
      title: '动作流向',
      subtitle: '行：当前配置回放；列：应用预设后预计',
      child: Table(
        border: TableBorder.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        columnWidths: const {0: FlexColumnWidth(1.15)},
        children: [
          TableRow(
            children: [
              _cell('当前 / 预设后'),
              for (final action in actions) _cell(_action(action)),
            ],
          ),
          for (final before in actions)
            TableRow(
              children: [
                _cell(_action(before)),
                for (final after in actions)
                  _cell(
                    '${result.rows.where((row) => row.before.action == before && row.after.action == after).length}',
                    highlight:
                        before != after &&
                        result.rows.any(
                          (row) =>
                              row.before.action == before &&
                              row.after.action == after,
                        ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _cell(String text, {bool highlight = false}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
    color: highlight ? Theme.of(context).colorScheme.primary : null,
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: highlight ? Theme.of(context).colorScheme.onPrimary : null,
      ),
    ),
  );

  Widget _applications(BatchComparisonResult result) {
    final groups = <String, List<BatchComparisonRow>>{};
    for (final row in result.rows.where((row) => row.actionChanged)) {
      groups.putIfAbsent(row.entry.record.packageName, () => []).add(row);
    }
    final applications = groups.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    final maximum = applications.isEmpty ? 1 : applications.first.value.length;
    return SectionCard(
      title: '动作变化最多的应用',
      subtitle: '仅统计本次样本，最多显示 8 个应用',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: applications.isEmpty
            ? const [Text('本次样本没有动作变化。')]
            : [
                for (final application in applications.take(8))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${application.value.first.entry.record.displayApp} · ${application.value.length} 条',
                        ),
                        Text(
                          application.key,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: application.value.length / maximum,
                          minHeight: 5,
                        ),
                      ],
                    ),
                  ),
              ],
      ),
    );
  }

  Widget _samples(BatchComparisonResult result) {
    final rows = result.rows
        .where(
          (row) => switch (_filter) {
            _RowFilter.all => true,
            _RowFilter.action => row.actionChanged,
            _RowFilter.ruleOnly => row.ruleChanged && !row.actionChanged,
          },
        )
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Text('记录明细', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final filter in _RowFilter.values)
              ChoiceChip(
                key: ValueKey('comparison-filter-${filter.name}'),
                label: Text(switch (filter) {
                  _RowFilter.all => '全部',
                  _RowFilter.action => '动作变化',
                  _RowFilter.ruleOnly => '仅规则变化',
                }),
                selected: _filter == filter,
                onSelected: (_) => setState(() {
                  _filter = filter;
                  _visibleCount = 30;
                }),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '显示 ${rows.length < _visibleCount ? rows.length : _visibleCount} / ${rows.length} 条',
        ),
        if (rows.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text('此筛选下没有记录。'),
          ),
        for (final row in rows.take(_visibleCount)) _sample(row),
        if (rows.length > _visibleCount)
          OutlinedButton(
            key: const Key('comparison-show-more'),
            onPressed: () => setState(() => _visibleCount += 30),
            child: const Text('再显示 30 条'),
          ),
      ],
    );
  }

  Widget _sample(BatchComparisonRow row) => SectionCard(
    key: ValueKey('comparison-row-${row.entry.id}'),
    title: row.entry.record.displayTitle,
    subtitle: '${row.entry.record.displayApp} · ${_time(row.entry.timestamp)}',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${_action(row.before.action)} → ${_action(row.after.action)}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Text('当前配置：${_decision(row.before)}'),
        Text('预设应用后：${_decision(row.after)}'),
        if (row.ruleChanged &&
            row.before.ruleName != null &&
            row.before.ruleName == row.after.ruleName &&
            row.before.ruleId != row.after.ruleId)
          const Text('命中规则同名，标识不同；可展开查看匹配详情。'),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: const Text('查看原记录与匹配详情'),
          expandedAlignment: Alignment.centerLeft,
          children: [
            Text(row.entry.record.displayBody),
            const SizedBox(height: 8),
            Text(
              '历史真实处理：${row.entry.action.label} · ${row.entry.cancelStatus.label}',
            ),
            Text('当前规则标识：${row.before.ruleId ?? '未命中规则'}'),
            Text('预设后规则标识：${row.after.ruleId ?? '未命中规则'}'),
            if (row.entry.record.isContentHidden)
              const Text('系统隐藏了正文，无法据此还原未公开的文字。'),
          ],
        ),
      ],
    ),
  );

  String _action(RuleAction action) => switch (action) {
    RuleAction.allow => '保留',
    RuleAction.intercept => '移除',
    RuleAction.logOnly => '仅记录',
  };

  String _decision(Decision decision) => decision.matchedByRule
      ? '命中「${decision.ruleName ?? decision.ruleId ?? '未命名规则'}」'
      : decision.describe();

  String _time(int millis) {
    final time = DateTime.fromMillisecondsSinceEpoch(millis);
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${time.month}-${pad(time.day)} ${pad(time.hour)}:${pad(time.minute)}';
  }

  Future<void> _run(String presetId) async {
    setState(() {
      _filter = _RowFilter.all;
      _visibleCount = 30;
    });
    try {
      await widget.controller.run(
        presetId: presetId,
        period: _period,
        limit: _limit,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('对比未完成：$error')));
    }
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final saved = await widget.controller.exportFile();
      if (saved && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('对比数据 JSON 已保存，可用于独立图表报告')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出失败，请重试：$error')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }
}
