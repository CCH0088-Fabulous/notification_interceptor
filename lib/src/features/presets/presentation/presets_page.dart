import 'package:flutter/material.dart';

import '../../../core/widgets/section_card.dart';
import '../domain/filter_preset.dart';
import 'preset_editor_page.dart';
import 'preset_transfer_sheets.dart';
import 'preset_versions_page.dart';
import 'presets_controller.dart';

class PresetsPage extends StatefulWidget {
  const PresetsPage({
    super.key,
    required this.controller,
    this.loadPackages,
    this.appName,
    this.refreshRules,
    this.onCompare,
  });

  final PresetsController controller;
  final Future<List<String>> Function()? loadPackages;
  final String Function(String)? appName;
  final Future<void> Function()? refreshRules;
  final void Function(FilterPreset? preset)? onCompare;

  @override
  State<PresetsPage> createState() => _PresetsPageState();
}

class _PresetsPageState extends State<PresetsPage> {
  PresetKind? _filter;
  bool _refreshing = false;
  bool _transferring = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await widget.refreshRules?.call();
      await widget.controller.load();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final busy =
            controller.busy ||
            controller.loading ||
            _refreshing ||
            _transferring;
        final presets = controller.presets
            .where((preset) => _filter == null || preset.kind == _filter)
            .toList();
        return Scaffold(
          appBar: AppBar(
            title: const Text('预设'),
            actions: [
              PopupMenuButton<String>(
                key: const Key('preset-tools'),
                tooltip: '导入导出与版本',
                enabled: controller.canWrite && !busy,
                icon: const Icon(Icons.import_export),
                onSelected: _tool,
                itemBuilder: (_) => [
                  if (widget.onCompare != null)
                    const PopupMenuItem(
                      value: 'compare',
                      child: Text('批量效果对比'),
                    ),
                  const PopupMenuItem(
                    value: 'import-file',
                    child: Text('从文件导入'),
                  ),
                  const PopupMenuItem(
                    value: 'import-json',
                    child: Text('粘贴 JSON 导入'),
                  ),
                  const PopupMenuItem(value: 'export', child: Text('导出全部预设')),
                  const PopupMenuItem(value: 'versions', child: Text('全部版本记录')),
                ],
              ),
              IconButton(
                tooltip: '刷新预设',
                onPressed: busy ? null : _reload,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                SectionCard(
                  title: '高级功能 · 预设管理',
                  subtitle: '核心过滤免费，高级功能付费；当前版本开放体验。',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '保存常用移除词，或为工作、睡眠等场景设置应用范围和生效时间。保存后手动应用，可随时停用。',
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            key: const Key('preset-create'),
                            onPressed: controller.canWrite && !busy
                                ? () => _edit()
                                : null,
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('新建预设'),
                          ),
                          OutlinedButton.icon(
                            onPressed: controller.canWrite && !busy
                                ? _chooseTemplate
                                : null,
                            icon: const Icon(
                              Icons.auto_awesome_outlined,
                              size: 18,
                            ),
                            label: const Text('从模板创建'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                _sceneStatus(busy),
                if (!controller.globalEnabled)
                  const SectionCard(
                    title: '全局过滤已关闭',
                    child: Text('应用预设会保存对应规则；请在“规则”页开启全局过滤后生效。'),
                  ),
                if (controller.error != null)
                  SectionCard(
                    title: '操作未完成',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          controller.error!,
                          key: const Key('presets-error'),
                        ),
                        TextButton(
                          onPressed: busy ? null : _reload,
                          child: const Text('重新读取'),
                        ),
                      ],
                    ),
                  ),
                if (busy) const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    ChoiceChip(
                      label: const Text('全部'),
                      selected: _filter == null,
                      onSelected: (_) => setState(() => _filter = null),
                    ),
                    for (final kind in PresetKind.values)
                      ChoiceChip(
                        label: Text(kind.label),
                        selected: _filter == kind,
                        onSelected: (_) => setState(() => _filter = kind),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('已保存 ${controller.presets.length} 个预设'),
                if (!busy && presets.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: Text('暂无此类预设。新建一个，或从模板开始；模板不会自动启用。'),
                  ),
                for (final preset in presets)
                  _card(preset, !controller.canWrite || busy),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _card(FilterPreset preset, bool busy) {
    final controller = widget.controller;
    final applied = controller.isApplied(preset);
    final installed = controller.hasAppliedRules(preset);
    final status = applied
        ? '已应用'
        : installed
        ? '规则已有变化 · 可重新应用'
        : '未应用';
    return SectionCard(
      key: ValueKey('preset-card-${preset.id}'),
      title: preset.name,
      subtitle: '${preset.kind.label} · $status',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ..._summary(preset),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                key: ValueKey('preset-apply-${preset.id}'),
                onPressed: busy ? null : () => _confirmApply(preset),
                child: Text(
                  preset.kind == PresetKind.scene
                      ? (installed ? '重新切换' : '切换场景')
                      : (installed ? '重新应用' : '应用'),
                ),
              ),
              if (installed)
                OutlinedButton(
                  key: ValueKey('preset-deactivate-${preset.id}'),
                  onPressed: busy
                      ? null
                      : () => _perform(
                          () => controller.deactivate(preset),
                          '已停用「${preset.name}」，预设仍保存在库中',
                        ),
                  child: const Text('停用'),
                ),
              TextButton(
                onPressed: busy ? null : () => _edit(preset),
                child: const Text('编辑'),
              ),
              TextButton(
                onPressed: busy ? null : () => _confirmDelete(preset),
                child: const Text('删除'),
              ),
              PopupMenuButton<String>(
                key: ValueKey('preset-more-${preset.id}'),
                tooltip: '${preset.name}的更多操作',
                enabled: !busy,
                onSelected: (value) {
                  switch (value) {
                    case 'save-version':
                      _saveVersion(preset);
                    case 'versions':
                      _openVersions(preset);
                    case 'export':
                      _export(preset);
                    case 'compare':
                      widget.onCompare?.call(preset);
                  }
                },
                itemBuilder: (_) => [
                  if (widget.onCompare != null)
                    const PopupMenuItem(
                      value: 'compare',
                      child: Text('对比应用效果'),
                    ),
                  const PopupMenuItem(
                    value: 'save-version',
                    child: Text('保存命名版本'),
                  ),
                  const PopupMenuItem(value: 'versions', child: Text('版本记录')),
                  const PopupMenuItem(value: 'export', child: Text('导出此预设')),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _summary(FilterPreset preset) => [
    Text('移除词：${preset.keywords.join('、')}'),
    if (preset.allowKeywords.isNotEmpty)
      Text('保留词：${preset.allowKeywords.join('、')}'),
    Text(
      '应用范围：${preset.packages.isEmpty ? '所有应用' : preset.packages.map((package) => widget.appName?.call(package) ?? package).join('、')}',
    ),
    Text(
      '生效时间：${preset.quietHours == null ? '全天' : '${preset.quietHours!.daysLabel} ${preset.quietHours!.label}'}',
    ),
  ];

  Future<void> _edit([FilterPreset? initial]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PresetEditorPage(
          controller: widget.controller,
          initial: initial,
          loadPackages: widget.loadPackages,
          appName: widget.appName,
        ),
      ),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('预设已保存；确认应用或切换场景后更新过滤规则')));
    }
  }

  Future<void> _chooseTemplate() async {
    final template = await showModalBottomSheet<FilterPreset>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('选择起始模板', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text('模板仅提供词表和时间起点，保存、应用前均可修改。'),
              for (final template in FilterPreset.examples)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(template.name),
                  subtitle: Text(
                    '${template.kind.label} · ${template.keywords.join('、')}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(context, template),
                ),
            ],
          ),
        ),
      ),
    );
    if (template != null && mounted) {
      await _edit(
        template.copyWith(id: 'p_${DateTime.now().microsecondsSinceEpoch}'),
      );
    }
  }

  Future<void> _confirmApply(FilterPreset preset) async {
    final scene = preset.kind == PresetKind.scene;
    final replaced = widget.controller.activeScenes
        .where((item) => item.id != preset.id)
        .map((item) => item.name)
        .toList();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${scene ? '切换到' : '应用'}「${preset.name}」？'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ..._summary(preset),
              const SizedBox(height: 16),
              Text(
                scene
                    ? '将一次更新整组场景规则，停用其他场景。常用关键词预设、手动规则、全局开关和默认动作保留。所选场景仍按自己的星期和时段参与匹配。'
                    : '更新本预设的规则，其他规则与全局开关保留。保留词先于本预设的移除词匹配；也可能保留其他预设要移除的通知。完整顺序见“规则”页。',
              ),
              if (scene && replaced.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('将停用：${replaced.join('、')}'),
              ],
              if (!widget.controller.globalEnabled) ...[
                const SizedBox(height: 8),
                const Text('当前全局过滤已关闭，需手动开启后生效。'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('preset-confirm-apply'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(scene ? '确认切换' : '确认应用'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await _perform(
        () => widget.controller.apply(preset),
        scene ? '已选择场景「${preset.name}」，按所设时段匹配' : '已应用「${preset.name}」',
      );
    }
  }

  Future<void> _confirmDelete(FilterPreset preset) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「${preset.name}」？'),
        content: const Text('将删除预设，并停用它生成的规则。其他预设和手动规则保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await _perform(
        () => widget.controller.remove(preset),
        '已删除「${preset.name}」',
      );
    }
  }

  Future<void> _perform(Future<void> Function() action, String success) async {
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(success)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('操作失败：$error')));
    }
  }

  Widget _sceneStatus(bool busy) {
    final scenes = widget.controller.activeScenes;
    return SectionCard(
      key: const Key('preset-scene-status'),
      title: scenes.isEmpty
          ? '日常模式 · 未选择场景'
          : '已选择场景：${scenes.map((scene) => scene.name).join('、')}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            scenes.isEmpty
                ? '常用关键词预设和手动规则独立使用。选择下面的场景后，按该场景的星期和时段匹配。'
                : '场景仅在自己设置的星期和时段内参与匹配；常用关键词预设和手动规则继续保留。',
          ),
          if (scenes.length > 1) ...[
            const SizedBox(height: 8),
            const Text('当前保留了多个旧版场景。下一次切换会只保留所选场景。'),
          ],
          if (scenes.isNotEmpty) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('preset-daily-mode'),
              onPressed: busy || !widget.controller.canWrite
                  ? null
                  : _deactivateScenes,
              child: const Text('回到日常模式'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _deactivateScenes() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('停用全部场景？'),
        content: Text(
          '将停用：${widget.controller.activeScenes.map((scene) => scene.name).join('、')}。\n\n常用关键词预设、手动规则和全局开关保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('preset-confirm-daily'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认停用场景'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await _perform(
        widget.controller.deactivateScenes,
        '已回到日常模式，常用关键词和手动规则保留',
      );
    }
  }

  Future<void> _tool(String value) async {
    switch (value) {
      case 'compare':
        widget.onCompare?.call(null);
      case 'import-file':
        await _importFile();
      case 'import-json':
        await showPresetImportDialog(context, widget.controller);
      case 'export':
        await _export();
      case 'versions':
        await _openVersions();
    }
  }

  Future<void> _importFile() async {
    setState(() => _transferring = true);
    try {
      final raw = await widget.controller.importFile();
      if (raw != null && mounted) {
        await showPresetImportDialog(
          context,
          widget.controller,
          initialText: raw,
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('文件导入失败：$error')));
    } finally {
      if (mounted) setState(() => _transferring = false);
    }
  }

  Future<void> _export([FilterPreset? preset]) async {
    try {
      await showPresetExportDialog(context, widget.controller, preset: preset);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法导出预设：$error')));
    }
  }

  Future<void> _openVersions([FilterPreset? preset]) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => PresetVersionsPage(
            controller: widget.controller,
            presetId: preset?.id,
            presetName: preset?.name,
          ),
        ),
      );

  Future<void> _saveVersion(FilterPreset preset) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _SaveVersionDialog(controller: widget.controller, preset: preset),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('版本已保存，可在版本记录中恢复')));
    }
  }
}

class _SaveVersionDialog extends StatefulWidget {
  const _SaveVersionDialog({required this.controller, required this.preset});

  final PresetsController controller;
  final FilterPreset preset;

  @override
  State<_SaveVersionDialog> createState() => _SaveVersionDialogState();
}

class _SaveVersionDialogState extends State<_SaveVersionDialog> {
  final _label = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text('保存「${widget.preset.name}」的版本'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('记录当前库中的词表与场景设置，不会改变运行规则。'),
            const SizedBox(height: 16),
            TextField(
              key: const Key('preset-version-label'),
              controller: _label,
              enabled: !_saving,
              maxLength: 60,
              decoration: const InputDecoration(
                labelText: '版本名称（可选）',
                hintText: '例如：演示前配置',
              ),
            ),
            if (_error != null)
              Text(_error!, key: const Key('preset-version-save-error')),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('preset-version-save-confirm'),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '正在保存…' : '保存版本'),
        ),
      ],
    ),
  );

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final label = _label.text.trim();
      await widget.controller.saveVersion(
        widget.preset,
        label: label.isEmpty ? null : label,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = '保存失败，名称已保留：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
