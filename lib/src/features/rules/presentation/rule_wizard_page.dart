import 'package:flutter/material.dart';

import '../../../shared/domain/decision.dart';
import '../../../shared/domain/rule_action.dart';
import '../../feed/domain/notification_record.dart';
import '../domain/rule_set.dart';
import '../domain/rule_spec.dart';
import '../domain/rule_topic.dart';
import '../domain/simple_rule_draft.dart';
import 'rules_controller.dart';

/// 三步规则创建；匹配和预览始终委托原生引擎，不改变消息数据契约。
class RuleWizardPage extends StatefulWidget {
  const RuleWizardPage({
    super.key,
    required this.controller,
    required this.loadPackages,
    required this.loadSamples,
    this.initial,
  });

  final RulesController controller;
  final Future<List<String>> Function() loadPackages;
  final Future<List<NotificationRecord>> Function() loadSamples;
  final RuleSpec? initial;

  @override
  State<RuleWizardPage> createState() => _RuleWizardPageState();
}

class _RuleWizardPageState extends State<RuleWizardPage> {
  final _keyword = TextEditingController();
  final _name = TextEditingController();
  final _search = TextEditingController();
  late final String _id;
  int _step = 0;
  bool _allApps = true;
  bool _allNotifications = false;
  bool _busy = false;
  bool _loading = true;
  bool _withoutSamples = false;
  bool _previewReady = false;
  RuleAction _action = RuleAction.intercept;
  final _selected = <String>{};
  List<String> _keywords = [];
  List<String> _packages = [];
  final _labels = <String, String>{};
  List<MapEntry<NotificationRecord, Decision>> _results = [];
  RuleSet? _previewBase;
  String? _loadError;
  String? _error;

  @override
  void initState() {
    super.initState();
    final rule = widget.initial;
    _id = rule?.id ?? 'r${DateTime.now().microsecondsSinceEpoch}';
    if (rule != null) {
      _allApps = rule.packages.isEmpty;
      _selected.addAll(rule.packages);
      _keywords = [...rule.keywordsAny];
      _allNotifications = rule.keywordsAny.isEmpty;
      _action = rule.action;
      _name.text = rule.name;
    }
    _load();
  }

  @override
  void dispose() {
    _keyword.dispose();
    _name.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final data = await Future.wait<Object>([
        widget.loadPackages(),
        widget.loadSamples(),
      ]);
      if (!mounted) return;
      final samples = data[1] as List<NotificationRecord>;
      final labels = <String, String>{};
      for (final sample in samples) {
        final label = sample.appLabel?.trim();
        if (label != null && label.isNotEmpty) {
          labels[sample.packageName] = label;
        }
      }
      setState(() {
        _packages = {
          ...data[0] as List<String>,
          ...samples.map((s) => s.packageName),
          ..._selected,
        }.where((p) => p.trim().isNotEmpty).toList()..sort();
        _labels.addAll(labels);
      });
    } catch (_) {
      if (mounted) setState(() => _loadError = '通知读取失败，请重试。');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _appName(String package) {
    final label = _labels[package];
    final name = label ?? '未命名应用 ${_packages.indexOf(package) + 1}';
    final duplicates = _packages.where((p) => _labels[p] == label).length;
    return label != null && duplicates > 1
        ? '$name（${_packages.indexOf(package) + 1}）'
        : name;
  }

  String get _scope => _allApps ? '所有应用' : _selected.map(_appName).join('、');

  SimpleRuleDraft get _draft => SimpleRuleDraft(
    id: _id,
    name: _name.text,
    allApps: _allApps,
    packages: _selected.toList(),
    allNotifications: _allNotifications,
    keywords: _keywords,
    action: _action,
    enabled: widget.initial?.enabled ?? true,
  );

  RuleSpec get _rule => _draft.toRule(scopeLabel: _scope);

  void _addWord() {
    final word = _keyword.text.trim();
    if (word.isEmpty) return;
    setState(() {
      _keywords = SimpleRuleDraft.cleanKeywords([..._keywords, word]);
      _keyword.clear();
      _error = null;
    });
  }

  Future<void> _preview() async {
    _addWord();
    final issue = _draft.validationMessage;
    if (issue != null) {
      setState(() => _error = issue);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _step = 2;
      _busy = true;
      _error = null;
      _results = [];
      _previewReady = false;
      _withoutSamples = false;
      _previewBase = widget.controller.ruleSet;
    });
    try {
      // Fresh samples also include already removed notifications supplied by the caller.
      final samples = await widget.loadSamples();
      final results = <MapEntry<NotificationRecord, Decision>>[];
      final rule = _rule;
      for (final sample in samples.take(12)) {
        results.add(
          MapEntry(
            sample,
            await widget.controller.evaluate(sample, draft: rule),
          ),
        );
      }
      if (mounted) {
        setState(() {
          _results = results;
          _previewReady = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '预览失败，请重试；规则尚未保存。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.saveDraft(_rule, previewBase: _previewBase!);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _previous() {
    if (_busy) return;
    if (_step == 0) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _step--;
        _error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final canNext = _allApps || _selected.isNotEmpty;
    return PopScope(
      canPop: !_busy && _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _previous();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: _busy ? null : _previous,
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回',
          ),
          title: Text(widget.initial == null ? '创建规则' : '编辑规则'),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
                child: Row(
                  children: List.generate(
                    3,
                    (i) => Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            height: 2,
                            margin: const EdgeInsets.only(right: 8),
                            color: i <= _step
                                ? Colors.black
                                : const Color(0xFFE5E5E5),
                          ),
                          const SizedBox(height: 9),
                          Text(
                            '${i + 1}  ${['应用范围', '处理', '预览'][i]}',
                            style: TextStyle(
                              fontSize: 13,
                              color: i == _step
                                  ? Colors.black
                                  : const Color(0xFF777777),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  key: ValueKey(_step),
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
                  children: [
                    Text(
                      ['应用范围', '处理', '预览'][_step],
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 17),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(
                          _error!,
                          key: const Key('wizard-error'),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    if (_step == 0) ..._scopePage(),
                    if (_step == 1) ..._conditionsPage(),
                    if (_step == 2) ..._previewPage(),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 10, 24, 18),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const Key('wizard-next'),
                    onPressed: _busy || (_step == 0 && !canNext)
                        ? null
                        : _step == 0
                        ? () => setState(() {
                            _step = 1;
                            _error = null;
                          })
                        : _step == 1
                        ? _preview
                        : (_previewReady &&
                              (_results.isNotEmpty || _withoutSamples))
                        ? _save
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Text(
                        _busy ? '处理中…' : ['下一步', '预览', '保存规则'][_step],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _scopePage() => [
    _hint('按关键词处理所有应用，或只处理选中的应用。'),
    _option(
      '所有应用',
      '不区分应用，按关键词或主题匹配',
      _allApps,
      () => setState(() {
        _allApps = true;
        _allNotifications = false;
      }),
    ),
    _option(
      '指定应用',
      '仅处理你选中的应用',
      !_allApps,
      () => setState(() => _allApps = false),
    ),
    if (!_allApps) ...[
      const SizedBox(height: 20),
      TextField(
        controller: _search,
        decoration: const InputDecoration(
          hintText: '搜索应用名称',
          prefixIcon: Icon(Icons.search),
        ),
        onChanged: (_) => setState(() {}),
      ),
      if (_loading)
        const Padding(
          padding: EdgeInsets.all(20),
          child: Center(child: CircularProgressIndicator()),
        ),
      if (_loadError != null) ...[
        Text(_loadError!),
        TextButton(onPressed: _load, child: const Text('重试')),
      ],
      ..._packages
          .where(
            (p) => _appName(
              p,
            ).toLowerCase().contains(_search.text.trim().toLowerCase()),
          )
          .map(
            (p) => CheckboxListTile(
              key: ValueKey('app-$p'),
              contentPadding: EdgeInsets.zero,
              title: Text(_appName(p)),
              value: _selected.contains(p),
              onChanged: (value) => setState(() {
                value == true ? _selected.add(p) : _selected.remove(p);
              }),
            ),
          ),
      if (!_loading && _packages.isEmpty && _loadError == null)
        _hint('暂无应用。先让目标应用发一条通知，再点击刷新。'),
      TextButton.icon(
        onPressed: _loading ? null : _load,
        icon: const Icon(Icons.refresh, size: 18),
        label: const Text('刷新应用'),
      ),
      _hint('列表来自已收到的通知，不需要输入包名。'),
    ],
  ];

  List<Widget> _conditionsPage() => [
    Row(
      children: [
        Expanded(child: Text(_scope, style: const TextStyle(fontSize: 14))),
        TextButton(
          onPressed: () => setState(() => _step = 0),
          child: const Text('修改'),
        ),
      ],
    ),
    _section('处理方式'),
    Wrap(
      spacing: 10,
      children: [
        ChoiceChip(
          label: const Text('自动移出'),
          selected: _action == RuleAction.intercept,
          onSelected: (_) => setState(() => _action = RuleAction.intercept),
        ),
        ChoiceChip(
          label: const Text('优先保留'),
          selected: _action == RuleAction.allow,
          onSelected: (_) => setState(() => _action = RuleAction.allow),
        ),
      ],
    ),
    _hint(
      _action == RuleAction.intercept
          ? '匹配的通知会从通知栏移出，仍可在历史中查看。首次声音或横幅可能已经出现。'
          : '匹配的通知优先保留，不交给后面的移出规则。已有规则仍按顺序处理。',
    ),
    _section('匹配条件'),
    if (!_allApps) ...[
      _option(
        '关键词或主题',
        '只处理出现任意一个关键词的通知',
        !_allNotifications,
        () => setState(() => _allNotifications = false),
      ),
      _option(
        '所选应用的全部通知',
        '不再按消息内容区分，请谨慎选择',
        _allNotifications,
        () => setState(() => _allNotifications = true),
      ),
    ],
    if (!_allNotifications) ...[
      _hint('关键词会在通知标题和内容中查找，出现任意一个即匹配，英文不区分大小写。系统隐藏正文时，关键词可能无法识别。'),
      TextField(
        key: const Key('keyword-input'),
        controller: _keyword,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _addWord(),
        decoration: InputDecoration(
          labelText: '关键词',
          hintText: '例如：秒杀',
          suffixIcon: IconButton(
            onPressed: _addWord,
            tooltip: '添加关键词',
            icon: const Icon(Icons.add),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: _keywords
            .map(
              (word) => InputChip(
                label: Text(word),
                onDeleted: () => setState(() => _keywords.remove(word)),
              ),
            )
            .toList(),
      ),
      _section('主题快捷选择'),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: RuleTopic.suggestions
            .map(
              (topic) => ActionChip(
                label: Text(topic.name),
                onPressed: () => setState(
                  () => _keywords = SimpleRuleDraft.cleanKeywords([
                    ..._keywords,
                    ...topic.keywords,
                  ]),
                ),
              ),
            )
            .toList(),
      ),
      _hint('主题只帮你添加一组关键词，可自行增删；不会自动理解语义，未出现关键词的相关消息不会匹配。'),
    ],
    const SizedBox(height: 18),
    TextField(
      key: const Key('rule-name'),
      controller: _name,
      decoration: const InputDecoration(
        labelText: '规则名称（可选）',
        hintText: '留空则自动生成',
      ),
    ),
  ];

  List<Widget> _previewPage() => [
    Container(
      padding: const EdgeInsets.only(left: 16),
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(width: 3)),
      ),
      child: Text(
        '$_scope${_allNotifications ? '的全部新通知' : '的新通知中，标题或内容出现${_keywords.map((w) => '“$w”').join('或')}时'}，${_action == RuleAction.intercept ? '自动移出' : '优先保留'}。',
        key: const Key('rule-summary'),
        style: const TextStyle(fontSize: 17, height: 1.9),
      ),
    ),
    const SizedBox(height: 20),
    Text(
      _rule.name,
      style: const TextStyle(fontSize: 14, color: Color(0xFF666666)),
    ),
    if (!widget.controller.globalEnabled)
      _hint('规则目前已暂停。保存不会自动开启；需返回规则页开启后才会处理新通知。'),
    if (!_rule.enabled) _hint('这条规则目前未启用；保存会保留停用状态。'),
    if (_results.any((e) => e.key.isContentHidden))
      _hint('部分通知正文已被系统隐藏，关键词或主题可能无法匹配。以下结果仍按系统实际提供的内容计算；按应用全部处理不依赖正文。'),
    _section('真实通知试运行'),
    _hint('使用最近收到的最多 12 条通知，按整套规则预览。只计算结果，不移出或重发这些消息。'),
    if (_busy)
      const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(),
        ),
      ),
    ..._results.map(
      (entry) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${entry.key.displayApp} · ${entry.key.displayTitle}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            Text(
              entry.key.isContentHidden
                  ? '系统已隐藏这条通知的正文，无法验证关键词匹配。'
                  : entry.key.displayBody,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, height: 1.7),
            ),
            const SizedBox(height: 8),
            Text(
              '${entry.value.action == RuleAction.intercept
                  ? '预计移出'
                  : entry.value.action == RuleAction.allow
                  ? '预计保留'
                  : '仅记录'} · ${entry.value.describe()}',
              style: const TextStyle(fontSize: 13, height: 1.7),
            ),
            if (entry.value.ruleId != null && entry.value.ruleId != _id)
              _hint('已有规则先命中，本条新规则不会覆盖它。'),
            const Divider(height: 20),
          ],
        ),
      ),
    ),
    if (!_busy && _results.isEmpty && _previewReady) ...[
      _hint('暂无真实通知可供预览。可以先让生成器或其他应用发送通知，再刷新。'),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('没有样本，仍保存规则', style: TextStyle(fontSize: 14)),
        value: _withoutSamples,
        onChanged: (v) => setState(() => _withoutSamples = v == true),
      ),
    ],
    if (!_busy)
      TextButton.icon(
        onPressed: _preview,
        icon: const Icon(Icons.refresh, size: 18),
        label: const Text('刷新预览'),
      ),
  ];

  Widget _option(
    String title,
    String subtitle,
    bool selected,
    VoidCallback onTap,
  ) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        border: Border.all(
          color: selected ? Colors.black : const Color(0xFFDDDDDD),
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_off,
            size: 21,
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 5),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF666666),
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  Widget _section(String text) => Padding(
    padding: const EdgeInsets.only(top: 21, bottom: 11),
    child: Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
  );
  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        height: 1.8,
        color: Color(0xFF666666),
      ),
    ),
  );
}
