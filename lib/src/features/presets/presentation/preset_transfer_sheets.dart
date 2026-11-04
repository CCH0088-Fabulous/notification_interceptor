import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/filter_preset.dart';
import '../domain/preset_transfer.dart';
import 'presets_controller.dart';

Future<void> showPresetImportDialog(
  BuildContext context,
  PresetsController controller, {
  String? initialText,
}) async {
  final imported = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _PresetImportDialog(controller: controller, initialText: initialText),
  );
  if (imported == true && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('预设已导入到库，应用后才会更新过滤规则')));
  }
}

class _PresetImportDialog extends StatefulWidget {
  const _PresetImportDialog({required this.controller, this.initialText});

  final PresetsController controller;
  final String? initialText;

  @override
  State<_PresetImportDialog> createState() => _PresetImportDialogState();
}

class _PresetImportDialogState extends State<_PresetImportDialog> {
  late final TextEditingController _text;
  PresetImportPlan? _plan;
  bool _replaceExisting = false;
  bool _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.initialText ?? '');
    if (widget.initialText != null) _preview();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _preview() {
    try {
      _plan = widget.controller.previewImport(_text.text);
      _replaceExisting = false;
      _error = null;
    } catch (error) {
      _plan = null;
      _error = '无法预览：$error';
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final importCount = plan == null
        ? 0
        : plan.addedCount + (_replaceExisting ? plan.updatedCount : 0);
    return PopScope(
      canPop: !_working,
      child: AlertDialog(
        title: const Text('导入预设'),
        content: SizedBox(
          width: 520,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .62,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('导入只保存词库和场景设置，不会自动应用，也不会修改运行规则。'),
                  const SizedBox(height: 16),
                  if (plan == null) ...[
                    TextField(
                      key: const Key('preset-import-json'),
                      controller: _text,
                      enabled: !_working,
                      minLines: 5,
                      maxLines: 10,
                      keyboardType: TextInputType.multiline,
                      decoration: const InputDecoration(
                        labelText: '预设 JSON',
                        hintText: '粘贴从本应用导出的预设内容',
                        alignLabelWithHint: true,
                      ),
                    ),
                  ] else ...[
                    Text(
                      '共 ${plan.presets.length} 个预设：新增 ${plan.addedCount} 个，同标识 ${plan.updatedCount} 个。',
                      key: const Key('preset-import-summary'),
                    ),
                    if (plan.duplicateIds.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      RadioListTile<bool>(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('跳过同标识预设'),
                        subtitle: const Text('保留本机版本，只添加新的预设。'),
                        value: false,
                        groupValue: _replaceExisting,
                        onChanged: _working
                            ? null
                            : (_) => setState(() => _replaceExisting = false),
                      ),
                      RadioListTile<bool>(
                        key: const Key('preset-import-replace'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('更新同标识预设'),
                        subtitle: const Text('旧词表会记入版本记录，运行规则仍需重新应用。'),
                        value: true,
                        groupValue: _replaceExisting,
                        onChanged: _working
                            ? null
                            : (_) => setState(() => _replaceExisting = true),
                      ),
                    ],
                    for (final preset in plan.presets)
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: const EdgeInsets.only(bottom: 12),
                        title: Text(preset.name),
                        subtitle: Text(
                          '${preset.kind.label} · ${plan.duplicateIds.contains(preset.id) ? (_replaceExisting ? '更新本机版本' : '跳过') : '新增'}',
                        ),
                        expandedAlignment: Alignment.centerLeft,
                        children: [
                          Text('过滤词：${preset.keywords.join('、')}'),
                          if (preset.allowKeywords.isNotEmpty)
                            Text('优先保留：${preset.allowKeywords.join('、')}'),
                          Text(
                            '应用范围：${preset.packages.isEmpty ? '所有应用' : preset.packages.join('、')}',
                          ),
                          Text(
                            '生效时间：${preset.quietHours == null ? '全天' : '${preset.quietHours!.daysLabel} ${preset.quietHours!.label}'}',
                          ),
                        ],
                      ),
                    if (importCount == 0)
                      Text(
                        plan.presets.isEmpty
                            ? '此文件没有预设内容。'
                            : '当前选择没有可导入的内容，可选择更新同标识预设。',
                      ),
                    TextButton(
                      onPressed: _working
                          ? null
                          : () => setState(() {
                              _plan = null;
                              _error = null;
                            }),
                      child: const Text('查看或修改 JSON'),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, key: const Key('preset-import-error')),
                  ],
                  if (_working) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _working ? null : () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          if (plan == null)
            FilledButton(
              key: const Key('preset-import-preview'),
              onPressed: _working ? null : () => setState(_preview),
              child: const Text('预览导入'),
            )
          else
            FilledButton(
              key: const Key('preset-import-confirm'),
              onPressed: _working || importCount == 0 ? null : _import,
              child: Text(_working ? '正在导入…' : '确认导入'),
            ),
        ],
      ),
    );
  }

  Future<void> _import() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.controller.importPresets(
        _plan!,
        replaceExisting: _replaceExisting,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = '导入失败，内容已保留：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }
}

Future<void> showPresetExportDialog(
  BuildContext context,
  PresetsController controller, {
  FilterPreset? preset,
}) async {
  final raw = controller.exportJson(ids: preset == null ? null : {preset.id});
  final outcome = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PresetExportDialog(
      controller: controller,
      raw: raw,
      name: preset?.name,
      count: preset == null ? controller.presets.length : 1,
    ),
  );
  if (outcome != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(outcome == 'copied' ? '预设 JSON 已复制' : '预设 JSON 文件已保存'),
      ),
    );
  }
}

class _PresetExportDialog extends StatefulWidget {
  const _PresetExportDialog({
    required this.controller,
    required this.raw,
    required this.count,
    this.name,
  });

  final PresetsController controller;
  final String raw;
  final int count;
  final String? name;

  @override
  State<_PresetExportDialog> createState() => _PresetExportDialogState();
}

class _PresetExportDialogState extends State<_PresetExportDialog> {
  bool _working = false;
  String? _error;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_working,
    child: AlertDialog(
      title: Text(widget.name == null ? '导出全部预设' : '导出「${widget.name}」'),
      content: SizedBox(
        width: 520,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .6,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('将导出 ${widget.count} 个预设，包含过滤词、优先保留词、应用范围与时段设置。'),
                const SizedBox(height: 8),
                const Text('文件只包含当前预设，不包含版本记录、通知历史或运行规则。'),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('查看 JSON'),
                  children: [
                    SizedBox(
                      height: 180,
                      child: SingleChildScrollView(
                        child: SelectableText(widget.raw),
                      ),
                    ),
                  ],
                ),
                if (_error != null)
                  Text(_error!, key: const Key('preset-export-error')),
                if (_working) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        OutlinedButton(
          key: const Key('preset-export-copy'),
          onPressed: _working ? null : () => _export(copy: true),
          child: const Text('复制 JSON'),
        ),
        FilledButton(
          key: const Key('preset-export-file'),
          onPressed: _working ? null : () => _export(copy: false),
          child: const Text('保存 JSON 文件'),
        ),
      ],
    ),
  );

  Future<void> _export({required bool copy}) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      if (copy) {
        await Clipboard.setData(ClipboardData(text: widget.raw));
        if (mounted) Navigator.pop(context, 'copied');
      } else {
        final saved = await widget.controller.exportFile(widget.raw);
        if (saved && mounted) Navigator.pop(context, 'file');
      }
    } catch (error) {
      if (mounted) setState(() => _error = '导出失败，可重试：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }
}
