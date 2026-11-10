import 'package:flutter/material.dart';

import '../../../core/widgets/section_card.dart';
import '../domain/filter_preset.dart';
import '../domain/preset_version.dart';
import 'presets_controller.dart';

class PresetVersionsPage extends StatefulWidget {
  const PresetVersionsPage({
    super.key,
    required this.controller,
    this.presetId,
    this.presetName,
  });

  final PresetsController controller;
  final String? presetId;
  final String? presetName;

  @override
  State<PresetVersionsPage> createState() => _PresetVersionsPageState();
}

class _PresetVersionsPageState extends State<PresetVersionsPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.load();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final versions =
          controller.versions
              .where(
                (version) =>
                    widget.presetId == null ||
                    version.preset.id == widget.presetId,
              )
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return Scaffold(
        appBar: AppBar(
          title: Text(
            widget.presetName == null ? '版本记录' : '${widget.presetName} · 版本记录',
          ),
          actions: [
            IconButton(
              tooltip: '刷新版本记录',
              onPressed: controller.busy || controller.loading
                  ? null
                  : controller.load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: controller.load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              const SectionCard(
                title: '恢复预设内容',
                child: Text(
                  '修改或删除前会自动保留旧版，也可以手动保存命名版本。所有预设共保留最近 20 条版本记录。\n\n'
                  '恢复只更新该预设在库中的内容，其他预设和当前运行规则保留；恢复后请重新应用。',
                ),
              ),
              if (controller.loading || controller.busy)
                const LinearProgressIndicator(),
              if (controller.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(controller.error!),
                ),
              if (!controller.loading && versions.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Text('暂无历史版本。可在预设的更多操作中保存一个命名版本。'),
                ),
              for (final version in versions) _versionCard(version),
            ],
          ),
        ),
      );
    },
  );

  Widget _versionCard(PresetVersion version) {
    final exists = widget.controller.presets.any(
      (p) => p.id == version.preset.id,
    );
    return SectionCard(
      key: ValueKey('preset-version-${version.id}'),
      title: version.preset.name,
      subtitle: '${_date(version.createdAt)} · ${version.label}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ..._summary(version.preset),
          if (!exists) ...[
            const SizedBox(height: 8),
            const Text('此预设已从当前库删除，恢复会重新加入库中。'),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            key: ValueKey('preset-version-restore-${version.id}'),
            onPressed: widget.controller.canWrite
                ? () => _restore(version)
                : null,
            icon: const Icon(Icons.restore, size: 18),
            label: const Text('恢复这个版本'),
          ),
        ],
      ),
    );
  }

  List<Widget> _summary(FilterPreset preset) => [
    Text(preset.kind.label),
    Text('移除词：${preset.keywords.join('、')}'),
    if (preset.allowKeywords.isNotEmpty)
      Text('保留词：${preset.allowKeywords.join('、')}'),
    Text(
      '应用范围：${preset.packages.isEmpty ? '所有应用' : preset.packages.join('、')}',
    ),
    Text(
      '生效时间：${preset.quietHours == null ? '全天' : '${preset.quietHours!.daysLabel} ${preset.quietHours!.label}'}',
    ),
  ];

  String _date(int millis) {
    final date = DateTime.fromMillisecondsSinceEpoch(millis);
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${pad(date.month)}-${pad(date.day)} ${pad(date.hour)}:${pad(date.minute)}';
  }

  Future<void> _restore(PresetVersion version) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('恢复「${version.preset.name}」？'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${_date(version.createdAt)} · ${version.label}'),
              const SizedBox(height: 12),
              ..._summary(version.preset),
              const SizedBox(height: 16),
              const Text('将恢复到预设库，当前运行规则继续使用原配置。重新应用后才更新过滤规则。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('preset-version-confirm-restore'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    try {
      await widget.controller.restoreVersion(version);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('版本已恢复到预设库，重新应用后更新过滤规则')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('恢复失败，可重试：$error')));
    }
  }
}
