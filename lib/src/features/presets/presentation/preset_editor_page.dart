import 'package:flutter/material.dart';

import '../../../core/widgets/section_card.dart';
import '../../rules/domain/quiet_hours.dart';
import '../../rules/domain/rule_validation.dart';
import '../domain/filter_preset.dart';
import 'presets_controller.dart';

/// Editing a library entry never changes the active native rules.
class PresetEditorPage extends StatefulWidget {
  const PresetEditorPage({
    super.key,
    required this.controller,
    this.initial,
    this.loadPackages,
    this.appName,
  });

  final PresetsController controller;
  final FilterPreset? initial;
  final Future<List<String>> Function()? loadPackages;
  final String Function(String)? appName;

  @override
  State<PresetEditorPage> createState() => _PresetEditorPageState();
}

class _PresetEditorPageState extends State<PresetEditorPage> {
  late final String _id;
  late final TextEditingController _name;
  late final TextEditingController _keywords;
  late final TextEditingController _allow;
  late final TextEditingController _packages;
  late PresetKind _kind;
  late QuietHours _hours;
  late bool _scheduled;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _id = initial?.id ?? 'p_${DateTime.now().microsecondsSinceEpoch}';
    _name = TextEditingController(text: initial?.name ?? '');
    _keywords = TextEditingController(text: initial?.keywords.join('\n') ?? '');
    _allow = TextEditingController(
      text: initial?.allowKeywords.join('\n') ?? '',
    );
    _packages = TextEditingController(text: initial?.packages.join('\n') ?? '');
    _kind = initial?.kind ?? PresetKind.keywords;
    _hours =
        initial?.quietHours ??
        const QuietHours(
          fromMinutes: 9 * 60,
          toMinutes: 18 * 60,
          days: {1, 2, 3, 4, 5},
        );
    _scheduled = initial?.quietHours != null;
  }

  @override
  void dispose() {
    _name.dispose();
    _keywords.dispose();
    _allow.dispose();
    _packages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.initial == null ? '新建预设' : '编辑预设')),
      body: AbsorbPointer(
        absorbing: _saving,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            const Text('先保存到预设库，再从列表应用。保存不会改变当前过滤规则。'),
            const SizedBox(height: 20),
            TextField(
              key: const Key('preset-name'),
              controller: _name,
              maxLength: 60,
              decoration: const InputDecoration(labelText: '预设名称'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final kind in PresetKind.values)
                  ChoiceChip(
                    label: Text(kind.label),
                    selected: _kind == kind,
                    onSelected: (_) => setState(() => _kind = kind),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('preset-keywords'),
              controller: _keywords,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: '过滤词',
                helperText: '逗号或换行分隔；标题或正文包含任一词即匹配。',
                helperMaxLines: 3,
                hintText: '促销\n限时优惠\n直播',
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              key: const Key('preset-allow-keywords'),
              controller: _allow,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: '优先保留词（可选）',
                helperText: '相同应用与时段内，包含这些词的通知优先保留。',
                helperMaxLines: 3,
                hintText: '验证码，取件码，紧急',
              ),
            ),
            const SizedBox(height: 20),
            SectionCard(
              title: '应用范围',
              subtitle: '留空作用于所有应用；填写后仅作用于这些应用。',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    key: const Key('preset-packages'),
                    controller: _packages,
                    minLines: 1,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: '应用包名（可选）',
                      hintText: 'dev.poc.notifgen',
                      helperText: '多个包名用逗号或换行分隔。',
                    ),
                  ),
                  if (widget.loadPackages != null)
                    TextButton.icon(
                      onPressed: _choosePackages,
                      icon: const Icon(Icons.apps_outlined, size: 18),
                      label: const Text('从已记录应用选择'),
                    ),
                ],
              ),
            ),
            if (_kind == PresetKind.scene)
              SectionCard(
                title: '场景生效时间',
                subtitle: '场景按关键词、应用和时段共同匹配；不会静音全部通知。',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('按时段生效'),
                      subtitle: Text(_scheduled ? '应用后由系统侧按时段匹配' : '应用后全天生效'),
                      value: _scheduled,
                      onChanged: (value) => setState(() => _scheduled = value),
                    ),
                    if (_scheduled) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          OutlinedButton(
                            key: const Key('preset-time-from'),
                            onPressed: () => _pickTime(true),
                            child: Text('开始 ${_timeLabel(_hours.fromMinutes)}'),
                          ),
                          OutlinedButton(
                            key: const Key('preset-time-to'),
                            onPressed: () => _pickTime(false),
                            child: Text('结束 ${_timeLabel(_hours.toMinutes)}'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (var day = 1; day <= 7; day++)
                            FilterChip(
                              label: Text(
                                '周${['一', '二', '三', '四', '五', '六', '日'][day - 1]}',
                              ),
                              selected: _hours.days.contains(day),
                              onSelected: (selected) => setState(() {
                                final days = {..._hours.days};
                                selected ? days.add(day) : days.remove(day);
                                _hours = _hours.copyWith(days: days);
                              }),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text('支持跨天时段；跨天按开始当天的星期判断。使用手机本地时间。'),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_error!, key: const Key('preset-editor-error')),
              ),
            FilledButton(
              key: const Key('preset-save'),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? '正在保存…' : '保存预设'),
            ),
          ],
        ),
      ),
    );
  }

  String _timeLabel(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

  Future<void> _pickTime(bool from) async {
    final current = from ? _hours.fromMinutes : _hours.toMinutes;
    final selected = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
      initialEntryMode: TimePickerEntryMode.input,
      helpText: from ? '场景开始时间' : '场景结束时间',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (selected == null || !mounted) return;
    final minutes = selected.hour * 60 + selected.minute;
    setState(() {
      _hours = from
          ? _hours.copyWith(fromMinutes: minutes)
          : _hours.copyWith(toMinutes: minutes);
    });
  }

  Future<void> _choosePackages() async {
    try {
      final packages = await widget.loadPackages!();
      if (!mounted) return;
      if (packages.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('还没有记录到应用，可先发送通知或手动填写包名')));
        return;
      }
      final selected = parseListInput(_packages.text).toSet();
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('选择应用'),
            content: SizedBox(
              width: 360,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final package in packages.toSet())
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(widget.appName?.call(package) ?? package),
                        subtitle: widget.appName == null ? null : Text(package),
                        value: selected.contains(package),
                        onChanged: (value) => update(() {
                          value == true
                              ? selected.add(package)
                              : selected.remove(package);
                        }),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确定'),
              ),
            ],
          ),
        ),
      );
      if (accepted == true && mounted) _packages.text = selected.join('\n');
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('应用列表读取失败：$error')));
    }
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    final preset = FilterPreset(
      id: _id,
      name: _name.text.trim(),
      kind: _kind,
      keywords: parseListInput(_keywords.text),
      allowKeywords: parseListInput(_allow.text),
      packages: parseListInput(_packages.text),
      quietHours: _kind == PresetKind.scene && _scheduled ? _hours : null,
    );
    final errors = preset.validate();
    if (errors.isNotEmpty) {
      setState(() => _error = errors.join('；'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.save(preset);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = '保存失败，内容已保留：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
