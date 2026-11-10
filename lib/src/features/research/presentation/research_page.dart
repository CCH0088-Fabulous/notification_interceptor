import 'package:flutter/material.dart';

import '../../../core/widgets/section_card.dart';
import '../domain/research_status.dart';
import 'research_controller.dart';

class ResearchPage extends StatefulWidget {
  const ResearchPage({super.key, required this.controller});
  final ResearchController controller;
  @override
  State<ResearchPage> createState() => _ResearchPageState();
}

class _ResearchPageState extends State<ResearchPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('内测数据')),
    body: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final status = controller.status;
        final c = status?.configuration;
        final busy = controller.busy;
        final hasData = c?.hasStudy == true;
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
          children: [
            if (busy) const LinearProgressIndicator(),
            if (controller.error != null || status?.settingsError != null)
              SectionCard(
                title: '内测提示',
                child: Text(status?.settingsError ?? controller.error!),
              ),
            SectionCard(
              title: hasData ? (c!.enabled ? '本轮正在记录' : '本轮记录已结束') : '自愿参与内测',
              subtitle: '数据保存在本机，仅在你分享或保存后交给你选择的应用。',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '用于产品研究及 BP 汇总分析，包含本应用使用时长、分时通知处理结果和操作次数。拒绝或结束记录不影响通知过滤。',
                  ),
                  const SizedBox(height: 8),
                  const Text('不包含通知正文、发送人、联系人及具体过滤词，也不记录其他应用的使用时长。'),
                  if (hasData) ...[
                    if (c!.acceptedDisclosureVersion < 2)
                      const Text('记录说明已更新，上一轮已停止新增记录；已有数据可继续分享。分享后删除旧数据可重新参与。'),
                    const SizedBox(height: 12),
                    Text('本轮开始：${_stamp(c.consentAt)}'),
                    if (c.endedAt > 0) Text('结束记录：${_stamp(c.endedAt)}'),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const Key('research-share'),
                        onPressed: busy || status?.settingsError != null
                            ? null
                            : () => _perform(() async {
                                final opened = await controller.shareFile();
                                if (opened) {
                                  _message('文件已生成，请在分享应用中选择收件人并发送。原数据仍保留。');
                                }
                              }),
                        icon: const Icon(Icons.ios_share_outlined),
                        label: const Text('分享内测数据'),
                      ),
                    ),
                    TextButton.icon(
                      key: const Key('research-save-file'),
                      onPressed: busy || status?.settingsError != null
                          ? null
                          : () => _perform(() async {
                              final saved = await controller.exportFile();
                              _message(
                                saved ? '已保存内测文件，原数据仍保留。' : '已取消保存，原数据仍保留。',
                              );
                            }),
                      icon: const Icon(Icons.save_alt_outlined),
                      label: const Text('保存到手机'),
                    ),
                    const Text('会生成一个完整的数据文件，无需打开或改名。分享后不会自动清除，可再次发送。'),
                  ] else ...[
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        key: const Key('research-start'),
                        onPressed:
                            busy ||
                                status == null ||
                                status.settingsError != null
                            ? null
                            : () => _perform(_start),
                        child: const Text('开始参与内测'),
                      ),
                    ),
                    const Text('无需登录、配置接收地址或连接电脑，不会自动上传。'),
                  ],
                ],
              ),
            ),
            if (hasData)
              SectionCard(
                title: '规则结构统计（可选）',
                child: SwitchListTile(
                  key: const Key('research-rule-structures'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('包含脱敏规则结构'),
                  subtitle: const Text('仅含类型、数量区间和条件有无，不含关键词、正则内容、应用包名或规则名称。'),
                  value: c!.ruleStructures,
                  onChanged: busy || (!c.enabled && !c.ruleStructures)
                      ? null
                      : (value) => _perform(() => _structures(value)),
                ),
              ),
            if (status != null && hasData) _range(status, busy),
            if (hasData && c!.enabled)
              SectionCard(
                title: '结束本轮记录',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('停止新增记录，已有数据继续保留，可以稍后分享或再次发送。'),
                    OutlinedButton(
                      key: const Key('research-end'),
                      onPressed: busy
                          ? null
                          : () => _perform(() async {
                              if (await _confirm(
                                '结束本轮记录',
                                '将停止新增内测统计，已有数据和编号继续保留，之后仍可分享。通知过滤继续工作。',
                                '结束记录',
                              )) {
                                await controller.end();
                              }
                            }),
                      child: const Text('结束记录，保留数据'),
                    ),
                  ],
                ),
              ),
            if (hasData || status?.settingsError != null)
              SectionCard(
                title: '删除研究数据',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('确认研究者已收到文件后再删除。删除会清除本机统计和编号，通知历史及过滤规则保留。'),
                    TextButton(
                      key: const Key('research-clear'),
                      onPressed: busy
                          ? null
                          : () => _perform(() async {
                              if (await _confirm(
                                '删除本机研究数据',
                                '本机研究统计、编号与临时分享文件将被清除。已保存或发出的文件需要另行处理。此操作不能撤销。',
                                '删除研究数据',
                              )) {
                                await controller.clear();
                              }
                            }),
                      child: const Text('删除本机研究数据'),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    ),
  );

  Widget _range(ResearchStatus status, bool busy) => SectionCard(
    title: '数据范围',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('事件明细最多保留 14 天，小时汇总最多保留 30 天；达到容量上限可能提前裁剪。'),
        Text('现存 ${status.hourCount} 个小时分组、${status.eventCount} 条事件明细。'),
        if (status.firstHourBucket > 0)
          Text('最早有统计的小时：${_stamp(status.firstHourBucket)}'),
        if (status.firstEventAt > 0)
          Text('最早现存事件：${_stamp(status.firstEventAt)}'),
        if (status.lastPreparedAt > 0)
          Text('上次生成文件：${_stamp(status.lastPreparedAt)}'),
        Text('前台使用：${(status.totals['foreground_ms'] ?? 0) ~/ 60000} 分钟'),
        for (final group in ['pilot', 'demo'])
          Text(
            '${group == 'pilot' ? '真实试用' : '演示／测试'}：${status.cohorts[group]?['processed'] ?? 0} 次处理，${status.cohorts[group]?['cancel_success'] ?? 0} 次确认移除',
          ),
        if (status.retentionDroppedEvents > 0 ||
            status.retentionDroppedHours > 0 ||
            status.captureFailures > 0)
          Text(
            '完整性提示：已裁剪事件 ${status.retentionDroppedEvents}、小时组 ${status.retentionDroppedHours}；本进程采集失败 ${status.captureFailures}。文件中会保留说明。',
          ),
        const Text('时长仅代表已观测区间，缺口不会当作持续使用；处理次数包含通知更新。'),
        TextButton(
          onPressed: busy ? null : widget.controller.load,
          child: const Text('刷新统计'),
        ),
        ExpansionTile(
          title: const Text('查看编号与记录说明'),
          children: [
            SelectableText(status.configuration.participantId),
            const Text('编号代表本轮安装记录，不等同独立人数。删除后重新参与会生成新编号。'),
          ],
        ),
      ],
    ),
  );

  Future<void> _start() async {
    if (!await _confirm(
      '参与内测数据记录',
      '用于产品研究及 BP 汇总分析。在本机记录本应用使用时长、分时通知处理结果、操作类别和时间点。事件明细保留 14 天，小时汇总保留 30 天，并受容量限制。\n\n不包含通知正文、发送人、联系人或具体过滤词。无需登录，不自动上传。由你在结束后选择分享文件。可随时结束记录，删除数据另行确认。',
      '同意并开始',
    )) {
      return;
    }
    await widget.controller.configure({
      'enabled': true,
      'disclosureAccepted': 2,
      'autoUpload': false,
    });
  }

  Future<void> _structures(bool value) async {
    if (value &&
        !await _confirm(
          '可选规则结构统计',
          '仅保存规则类型、启用状态、匹配方式、数量区间及条件有无，并在你分享时包含这些结构。不包含具体词语、正则内容、包名或名称。关闭后清除本机结构，已发出的文件需另行处理。',
          '同意统计结构',
        )) {
      return;
    }
    await widget.controller.configure({
      'ruleStructures': value,
      if (value) 'ruleDisclosureAccepted': 2,
    });
  }

  Future<bool> _confirm(String title, String content, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(content)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _perform(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (_) {
      _message('操作未完成，原数据仍保留，请稍后重试。');
    }
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  static String _stamp(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}
