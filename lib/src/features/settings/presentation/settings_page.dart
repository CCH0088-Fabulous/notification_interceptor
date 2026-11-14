import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/widgets/section_card.dart';
import '../../access/presentation/access_controller.dart';
import '../../history/presentation/history_controller.dart';
import '../../rules/domain/rule_set.dart';
import '../../rules/presentation/rules_controller.dart';

/// 设置与诊断：权限状态、服务重连、数据管理与能力边界说明。
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.access,
    required this.history,
    required this.rules,
    this.onOpenPresets,
    this.onOpenResearch,
  });

  final AccessController access;
  final HistoryController history;
  final RulesController rules;
  final VoidCallback? onOpenPresets;
  final VoidCallback? onOpenResearch;

  static const String generatorPresetAsset =
      'assets/presets/generator_triage.json';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([access, history, rules]),
      builder: (context, _) {
        final status = access.status;
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
          children: [
            if (onOpenResearch != null)
              SectionCard(
                title: '内测数据',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.insights_outlined),
                  title: const Text('内测数据'),
                  subtitle: const Text('自愿参与，本地记录，结束后分享，无需登录'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: onOpenResearch,
                ),
              ),
            if (onOpenPresets != null)
              SectionCard(
                title: '高级功能',
                subtitle: '核心过滤免费，高级功能付费；当前版本开放体验。',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.bookmarks_outlined),
                  title: const Text('预设管理'),
                  subtitle: const Text('保存移除词与保留词，配置工作、睡眠等场景'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: onOpenPresets,
                ),
              ),
            SectionCard(
              title: '通知使用权',
              subtitle: status.isReady ? '监听服务已连接' : '尚未生效',
              trailing: Icon(
                status.isReady ? Icons.check_circle : Icons.error_outline,
                color: status.isReady
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.error,
              ),
              child: Column(
                children: [
                  _row('已授予权限', status.granted ? '是' : '否'),
                  _row('服务已连接', status.connected ? '是' : '否'),
                  if (access.connectionMessage != null)
                    Text(access.connectionMessage!),
                  _row('系统版本', 'API ${status.sdkInt}'),
                  _row('本应用包名', status.ownPackage),
                  if (status.serviceComponent.isNotEmpty)
                    _row('服务组件', status.serviceComponent),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.tonal(
                        onPressed: access.openSettings,
                        child: const Text('打开系统设置'),
                      ),
                      OutlinedButton(
                        onPressed: access.reconnecting ? null : access.requestRebind,
                        child: Text(access.reconnecting ? '连接中…' : '重新连接'),
                      ),
                      OutlinedButton(
                        onPressed: access.refresh,
                        child: const Text('刷新状态'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SectionCard(
              title: '数据',
              subtitle: '通知历史与规则保存在本机；自愿研究统计单独管理。',
              child: Column(
                children: [
                  _row('已保存历史', '${history.stats.total} 条（上限 1000）'),
                  const Text('常驻通知不保存到历史；系统汇总不计入通知效果统计。'),
                  _row('规则数量', '${rules.ruleSet.rules.length} 条'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          final json = await history.exportJson();
                          await Clipboard.setData(ClipboardData(text: json));
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text('已复制 ${json.length} 字符 JSON'),
                            ),
                          );
                        },
                        icon: const Icon(Icons.copy_all_outlined, size: 18),
                        label: const Text('导出历史'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          await history.load();
                          await access.refresh();
                        },
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('刷新统计'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SectionCard(
              title: '示例：通知生成器分流',
              subtitle: '配合测试生成器 dev.poc.notifgen 使用',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '导入 4 条规则：保留私聊、群聊、验证码、银行、物流与日程，其余通知请求移除。\n'
                    '仅处理通知生成器的消息，先匹配保留规则，再匹配移除规则。',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                    onPressed: () => _importGeneratorPreset(context),
                    child: const Text('导入分流规则'),
                  ),
                ],
              ),
            ),
            const SectionCard(
              title: '能力边界（必读）',
              child: Text(
                '1. “移除”指通知发出后请求从通知栏取消，不删除原应用消息；首次声音、震动或横幅仍可能出现。\n'
                '2. 部分常驻或系统通知无法移除，请在历史中查看实际结果。\n'
                '3. 撤销通知使用权后规则立即失效，本应用无法自行恢复权限。\n'
                '4. 工作资料（work profile）中的通知对监听器不可见。\n'
                '5. 通知内容与过滤规则保存在本机。内测记录需单独同意，由你选择是否分享。',
              ),
            ),
            SectionCard(
              title: '关于',
              subtitle: '通知拦截器 PoC · 仅用于技术验证',
              child: Column(
                children: [
                  _row('规则存储', 'filesDir/rules.json'),
                  _row('历史存储', 'filesDir/history.jsonl'),
                  _row('求值顺序', '自上而下，首个命中即生效'),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// 预设与 e2e 脚本共用同一份 JSON（`assets/presets/generator_triage.json`），避免两处漂移。
  Future<void> _importGeneratorPreset(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final raw = await rootBundle.loadString(generatorPresetAsset);
      final preset = RuleSet.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      await rules.replaceAll(preset);
      messenger.showSnackBar(
        SnackBar(content: Text('已导入 ${preset.rules.length} 条分流规则（仅作用于生成器）')),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$error')));
    }
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: SelectableText(value, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
