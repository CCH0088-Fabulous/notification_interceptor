import 'package:flutter/material.dart';

import '../../../core/util/time_format.dart';
import '../../../shared/domain/decision.dart';
import '../../../shared/domain/rule_action.dart';
import '../../feed/domain/notification_record.dart';
import '../domain/quiet_hours.dart';
import '../domain/rule_set.dart';
import '../domain/rule_spec.dart';
import '../domain/rule_validation.dart';

/// 规则编辑器。保存时通过 `Navigator.pop(rule)` 返回结果，不直接落盘。
class RuleEditorPage extends StatefulWidget {
  const RuleEditorPage({
    super.key,
    this.initial,
    required this.loadPackages,
    required this.loadSamples,
    required this.evaluate,
  });

  final RuleSpec? initial;
  final Future<List<String>> Function() loadPackages;
  final Future<List<NotificationRecord>> Function() loadSamples;
  final Future<Decision> Function(NotificationRecord sample, RuleSpec draft) evaluate;

  @override
  State<RuleEditorPage> createState() => _RuleEditorPageState();
}

class _RuleEditorPageState extends State<RuleEditorPage> {
  late RuleSpec _rule;

  late final TextEditingController _name;
  late final TextEditingController _packages;
  late final TextEditingController _keywords;
  late final TextEditingController _titleRegex;
  late final TextEditingController _textRegex;
  late final TextEditingController _channelIds;

  @override
  void initState() {
    super.initState();
    _rule = widget.initial ??
        RuleSpec(id: 'r${DateTime.now().microsecondsSinceEpoch}', name: '');
    _name = TextEditingController(text: _rule.name);
    _packages = TextEditingController(text: _rule.packages.join(', '));
    _keywords = TextEditingController(text: _rule.keywordsAny.join(', '));
    _titleRegex = TextEditingController(text: _rule.titleRegex ?? '');
    _textRegex = TextEditingController(text: _rule.textRegex ?? '');
    _channelIds = TextEditingController(text: _rule.channelIds.join(', '));
  }

  @override
  void dispose() {
    _name.dispose();
    _packages.dispose();
    _keywords.dispose();
    _titleRegex.dispose();
    _textRegex.dispose();
    _channelIds.dispose();
    super.dispose();
  }

  RuleSpec _draft() => _rule.copyWith(
        name: _name.text.trim(),
        packages: parseListInput(_packages.text),
        keywordsAny: parseListInput(_keywords.text),
        titleRegex: _titleRegex.text.trim().isEmpty ? null : _titleRegex.text.trim(),
        textRegex: _textRegex.text.trim().isEmpty ? null : _textRegex.text.trim(),
        channelIds: parseListInput(_channelIds.text),
      );

  List<RuleIssue> get _issues => validateRuleSet(RuleSet(rules: [_draft()]));

  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final draft = _draft();
    final issues = _issues;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? '新建规则' : '编辑规则'),
        actions: [
          IconButton(
            tooltip: '试运行',
            onPressed: () => _runTest(draft),
            icon: const Icon(Icons.play_circle_outline),
          ),
          TextButton(
            onPressed: () => _save(draft),
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: '规则名称',
              hintText: '例如：屏蔽电商营销通知',
            ),
            onChanged: (_) => _refresh(),
          ),
          const SizedBox(height: 16),
          _Label('命中动作'),
          SegmentedButton<RuleAction>(
            segments: RuleAction.values
                .map((action) => ButtonSegment(value: action, label: Text(action.label)))
                .toList(),
            selected: {draft.action},
            onSelectionChanged: (selection) {
              setState(() => _rule = _rule.copyWith(action: selection.first));
            },
          ),
          const SizedBox(height: 16),
          _Label('条件组合'),
          SegmentedButton<MatchMode>(
            segments: MatchMode.values
                .map((mode) => ButtonSegment(value: mode, label: Text(mode.label)))
                .toList(),
            selected: {draft.mode},
            onSelectionChanged: (selection) {
              setState(() => _rule = _rule.copyWith(mode: selection.first));
            },
          ),
          const SizedBox(height: 8),
          Text(
            '「全部满足」= 各条件组之间 AND；「任一满足」= OR。组内多个值为 OR。空白条件不参与匹配。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Divider(height: 32),
          _Label('应用包名'),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _packages,
                  decoration: const InputDecoration(
                    hintText: 'com.example.shop',
                    helperText: '多个包名用逗号分隔',
                  ),
                  onChanged: (_) => _refresh(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: '从已见应用选择',
                onPressed: () => _pickPackages(draft),
                icon: const Icon(Icons.apps),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Label('关键词'),
          TextField(
            controller: _keywords,
            decoration: const InputDecoration(
              hintText: '秒杀, 红包, 限时',
              helperText: '匹配标题、正文、大文本、子文本，忽略大小写',
            ),
            onChanged: (_) => _refresh(),
          ),
          const SizedBox(height: 16),
          _Label('正则（可选）'),
          TextField(
            controller: _titleRegex,
            decoration: InputDecoration(
              labelText: '标题正则',
              hintText: '优惠|限时',
              errorText: isValidRegex(_titleRegex.text) ? null : '正则无效',
            ),
            onChanged: (_) => _refresh(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _textRegex,
            decoration: InputDecoration(
              labelText: '正文正则',
              hintText: r'^\d{6}$',
              errorText: isValidRegex(_textRegex.text) ? null : '正则无效',
            ),
            onChanged: (_) => _refresh(),
          ),
          const SizedBox(height: 16),
          _Label('通知渠道 id'),
          TextField(
            controller: _channelIds,
            decoration: const InputDecoration(
              hintText: 'marketing, promotion',
              helperText: '对应 NotificationChannel，可在实时通知详情里查看',
            ),
            onChanged: (_) => _refresh(),
          ),
          const Divider(height: 32),
          _TriStateField(
            label: '常驻通知（ongoing）',
            value: draft.isOngoing,
            onChanged: (value) => setState(() => _rule = _rule.copyWith(isOngoing: value)),
          ),
          _TriStateField(
            label: '可清除（clearable）',
            value: draft.isClearable,
            onChanged: (value) => setState(() => _rule = _rule.copyWith(isClearable: value)),
          ),
          const Divider(height: 32),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('限定静默时段'),
            subtitle: Text(
              draft.quietHours == null
                  ? '在该时段内才命中'
                  : '${draft.quietHours!.label} · ${draft.quietHours!.daysLabel}',
            ),
            value: draft.quietHours != null,
            onChanged: (enabled) {
              setState(() {
                _rule = _rule.copyWith(
                  quietHours: enabled
                      ? const QuietHours(
                          fromMinutes: 22 * 60,
                          toMinutes: 8 * 60,
                          days: {1, 2, 3, 4, 5, 6, 7},
                        )
                      : null,
                );
              });
            },
          ),
          if (draft.quietHours != null) _quietHoursEditor(draft.quietHours!),
          if (issues.isNotEmpty) ...[
            const Divider(height: 32),
            ...issues.map(
              (issue) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber, size: 16, color: Theme.of(context).colorScheme.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        issue.message,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (!draft.hasAnyCondition) ...[
            const SizedBox(height: 12),
            Text(
              '提示：没有条件组的规则不会命中任何通知。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Widget _quietHoursEditor(QuietHours quiet) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _TimeField(
                label: '开始',
                minutes: quiet.fromMinutes,
                onChanged: (value) => setState(
                  () => _rule = _rule.copyWith(quietHours: quiet.copyWith(fromMinutes: value)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _TimeField(
                label: '结束',
                minutes: quiet.toMinutes,
                onChanged: (value) => setState(
                  () => _rule = _rule.copyWith(quietHours: quiet.copyWith(toMinutes: value)),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          children: List.generate(7, (index) => index + 1).map((day) {
            const names = ['一', '二', '三', '四', '五', '六', '日'];
            return FilterChip(
              label: Text('周${names[day - 1]}'),
              selected: quiet.days.contains(day),
              onSelected: (selected) {
                final days = {...quiet.days};
                if (selected) {
                  days.add(day);
                } else {
                  days.remove(day);
                }
                setState(
                  () => _rule = _rule.copyWith(quietHours: quiet.copyWith(days: days)),
                );
              },
            );
          }).toList(),
        ),
        Text(
          '跨天区间（如 22:00–08:00）按起始日判断；周日选周六表示周六夜间到周日早晨。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Future<void> _pickPackages(RuleSpec draft) async {
    final available = await widget.loadPackages();
    if (!mounted) return;
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有记录到任何包名，先让目标应用发一条通知')),
      );
      return;
    }
    final selected = <String>{...draft.packages};
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('选择应用包名'),
          content: SizedBox(
            width: 400,
            child: ListView(
              shrinkWrap: true,
              children: available
                  .map(
                    (packageName) => CheckboxListTile(
                      dense: true,
                      title: Text(packageName),
                      value: selected.contains(packageName),
                      onChanged: (checked) => setDialogState(() {
                        if (checked == true) {
                          selected.add(packageName);
                        } else {
                          selected.remove(packageName);
                        }
                      }),
                    ),
                  )
                  .toList(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                _packages.text = selected.join(', ');
                Navigator.pop(context);
                _refresh();
              },
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runTest(RuleSpec draft) async {
    final samples = await widget.loadSamples();
    if (!mounted) return;
    if (samples.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前没有活动通知可用于试运行')),
      );
      return;
    }
    final results = <MapEntry<NotificationRecord, Decision>>[];
    for (final sample in samples.take(5)) {
      results.add(MapEntry(sample, await widget.evaluate(sample, draft)));
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('试运行结果'),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: results
                .map(
                  (entry) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry.key.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${entry.key.displayApp} · ${entry.value.describe()}'),
                    trailing: Text(entry.value.action.label),
                  ),
                )
                .toList(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ],
      ),
    );
  }

  void _save(RuleSpec draft) {
    final name = draft.name.trim().isEmpty
        ? '规则 ${DateTime.now().millisecondsSinceEpoch % 10000}'
        : draft.name.trim();
    Navigator.pop(context, draft.copyWith(name: name));
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

class _TriStateField extends StatelessWidget {
  const _TriStateField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool? value;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'any', label: Text('不限')),
              ButtonSegment(value: 'yes', label: Text('是')),
              ButtonSegment(value: 'no', label: Text('否')),
            ],
            selected: {value == null ? 'any' : (value! ? 'yes' : 'no')},
            onSelectionChanged: (selection) {
              onChanged(switch (selection.first) {
                'yes' => true,
                'no' => false,
                _ => null,
              });
            },
          ),
        ],
      ),
    );
  }
}

class _TimeField extends StatelessWidget {
  const _TimeField({
    required this.label,
    required this.minutes,
    required this.onChanged,
  });

  final String label;
  final int minutes;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
        );
        if (picked != null) {
          onChanged(picked.hour * 60 + picked.minute);
        }
      },
      child: Text('$label ${formatMinutesOfDay(minutes)}'),
    );
  }
}
