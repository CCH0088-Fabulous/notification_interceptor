import 'package:flutter/material.dart';

typedef ResearchRecordingChoice = ({bool enabled, bool ruleStructures});

Future<ResearchRecordingChoice?> showResearchSetupDialog(
  BuildContext context, {
  bool initialSetup = false,
}) => showDialog<ResearchRecordingChoice>(
  context: context,
  barrierDismissible: !initialSetup,
  builder: (_) => PopScope(
    canPop: !initialSetup,
    child: _ResearchSetupDialog(initialSetup: initialSetup),
  ),
);

class _ResearchSetupDialog extends StatefulWidget {
  const _ResearchSetupDialog({required this.initialSetup});
  final bool initialSetup;

  @override
  State<_ResearchSetupDialog> createState() => _ResearchSetupDialogState();
}

class _ResearchSetupDialogState extends State<_ResearchSetupDialog> {
  bool _enabled = true;
  bool _structures = true;

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('research-setup-dialog'),
    title: const Text('内测数据记录'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('两项采集默认勾选，确认后开始。可取消勾选或不参与，通知过滤照常使用。'),
          SwitchListTile(
            key: const Key('research-default-recording'),
            contentPadding: EdgeInsets.zero,
            title: const Text('记录内测数据'),
            subtitle: const Text('本应用使用时长、通知处理结果、操作次数与时间点。'),
            value: _enabled,
            onChanged: (value) => setState(() => _enabled = value),
          ),
          SwitchListTile(
            key: const Key('research-default-structures'),
            contentPadding: EdgeInsets.zero,
            title: const Text('包含脱敏规则结构'),
            subtitle: const Text('仅含规则类型、数量区间和条件有无，不含具体过滤词、正则、包名或规则名称。'),
            value: _enabled && _structures,
            onChanged: !_enabled
                ? null
                : (value) => setState(() => _structures = value),
          ),
          const SizedBox(height: 8),
          const Text('用于产品研究及 BP 汇总分析。不记录通知标题、正文、发送人、联系人或其他应用的使用时长。'),
          const SizedBox(height: 8),
          const Text('事件明细保留 14 天，小时汇总保留 30 天，并受容量限制。数据保存在本机，不自动上传，由你选择分享。'),
          const SizedBox(height: 8),
          const Text('可在“设置 → 内测数据”关闭规则结构统计、结束记录或删除研究数据。'),
        ],
      ),
    ),
    actions: [
      TextButton(
        key: const Key('research-setup-decline'),
        onPressed: () => Navigator.pop<ResearchRecordingChoice>(
          context,
          widget.initialSetup ? (enabled: false, ruleStructures: false) : null,
        ),
        child: Text(widget.initialSetup ? '暂不参与' : '取消'),
      ),
      FilledButton(
        key: const Key('research-setup-confirm'),
        onPressed: () => Navigator.pop<ResearchRecordingChoice>(context, (
          enabled: _enabled,
          ruleStructures: _enabled && _structures,
        )),
        child: Text(_enabled ? '同意并开始' : '保存设置'),
      ),
    ],
  );
}
