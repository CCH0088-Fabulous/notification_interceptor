import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_record.dart';
import 'package:notifinterceptor/src/features/presets/domain/filter_preset.dart';
import 'package:notifinterceptor/src/features/presets/domain/presets_repository.dart';
import 'package:notifinterceptor/src/features/presets/domain/preset_version.dart';
import 'package:notifinterceptor/src/features/presets/presentation/preset_editor_page.dart';
import 'package:notifinterceptor/src/features/presets/presentation/presets_controller.dart';
import 'package:notifinterceptor/src/features/presets/presentation/presets_page.dart';
import 'package:notifinterceptor/src/features/presets/presentation/preset_versions_page.dart';
import 'package:notifinterceptor/src/features/rules/domain/quiet_hours.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_set.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_spec.dart';
import 'package:notifinterceptor/src/features/rules/domain/rules_repository.dart';
import 'package:notifinterceptor/src/features/rules/presentation/rules_controller.dart';
import 'package:notifinterceptor/src/shared/domain/decision.dart';

class _Library implements PresetsRepository {
  List<FilterPreset> items = [];
  final List<PresetVersion> versions = [];
  bool failSave = false;
  bool failLoad = false;
  String? importText;
  bool exportCancelled = false;
  String? exportedText;
  int _versionId = 0;

  @override
  Future<List<FilterPreset>> load() async {
    if (failLoad) throw StateError('cannot read library');
    return items;
  }

  @override
  Future<void> save(List<FilterPreset> presets) async {
    if (failSave) throw StateError('disk full');
    for (final old in items) {
      final next = presets.where((preset) => preset.id == old.id);
      if (next.isEmpty ||
          jsonEncode(next.single.toJson()) != jsonEncode(old.toJson())) {
        _archive(old, next.isEmpty ? '删除前' : '修改前');
      }
    }
    items = List.of(presets);
  }

  void _archive(FilterPreset preset, String label) {
    _versionId++;
    versions.insert(
      0,
      PresetVersion(
        id: 'v_$_versionId',
        createdAt: 1793740000000 + _versionId,
        label: label,
        preset: preset,
      ),
    );
    if (versions.length > 20) versions.removeLast();
  }

  @override
  Future<List<PresetVersion>> loadVersions() async {
    if (failLoad) throw StateError('cannot read versions');
    return List.of(versions);
  }

  @override
  Future<void> saveVersion(String presetId, {String? label}) async {
    if (failSave) throw StateError('disk full');
    _archive(
      items.singleWhere((preset) => preset.id == presetId),
      label ?? '手动保存',
    );
  }

  @override
  Future<String?> importFile() async => importText;

  @override
  Future<bool> exportFile(String content, {required String fileName}) async {
    if (exportCancelled) return false;
    exportedText = content;
    return true;
  }
}

class _Rules implements RulesRepository {
  RuleSet current = const RuleSet(
    rules: [
      RuleSpec(id: 'manual', name: '我的已有规则', keywordsAny: ['广告']),
    ],
  );

  @override
  Future<RuleSet> load() async => current;

  @override
  Future<RuleSaveResult> save(RuleSet ruleSet) async {
    current = ruleSet;
    return RuleSaveResult(ruleSet: current, issues: const []);
  }

  @override
  Future<Decision> evaluate(
    NotificationRecord sample, {
    RuleSet? ruleSet,
  }) async => const Decision();

  @override
  Future<Map<String, String>> availableApps() async => {
    for (final package in await seenPackages()) package: package,
  };

  @override
  Future<List<String>> seenPackages() async => const [];
}

void main() {
  late _Library library;
  late _Rules rulesRepository;
  late RulesController rules;
  late PresetsController controller;

  setUp(() async {
    library = _Library();
    rulesRepository = _Rules();
    rules = RulesController(repository: rulesRepository);
    controller = PresetsController(repository: library, rules: rules);
    await rules.load();
    await controller.load();
  });

  tearDown(() {
    controller.dispose();
    rules.dispose();
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: PresetsPage(controller: controller)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tool(WidgetTester tester, String title) async {
    await tester.tap(find.byKey(const Key('preset-tools')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('创建仅保存到库，应用需确认，停用后保留预设及手动规则', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('preset-create')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('preset-name')), '演示营销');
    await tester.enterText(
      find.byKey(const Key('preset-keywords')),
      ' 优惠，秒杀\n优惠 ',
    );
    await tester.tap(find.byKey(const Key('preset-save')));
    await tester.pumpAndSettle();
    expect(library.items.single.keywords, ['优惠', '秒杀']);
    expect(rulesRepository.current.rules.map((rule) => rule.id), ['manual']);
    final preset = library.items.single;
    final apply = find.byKey(ValueKey('preset-apply-${preset.id}'));
    await tester.scrollUntilVisible(apply, 200);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(rulesRepository.current.rules, hasLength(1));
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('preset-confirm-apply')));
    await tester.pumpAndSettle();
    expect(controller.isApplied(preset), isTrue);
    final deactivate = find.byKey(ValueKey('preset-deactivate-${preset.id}'));
    await tester.ensureVisible(deactivate);
    await tester.tap(deactivate);
    await tester.pumpAndSettle();
    expect(library.items, hasLength(1));
    expect(rulesRepository.current.rules.map((rule) => rule.id), ['manual']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑跨天场景保存失败时保留草稿，重试成功但不更新已应用规则', (tester) async {
    final initial = FilterPreset.examples.last.copyWith(id: 'sleep');
    await controller.save(initial);
    await controller.apply(initial);
    library.failSave = true;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: PresetEditorPage(controller: controller, initial: initial),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('preset-name')), '我的睡眠场景');
    await tester.tap(find.byKey(const Key('preset-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('preset-editor-error')), findsOneWidget);
    expect(find.textContaining('内容已保留'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('preset-name')))
          .controller!
          .text,
      '我的睡眠场景',
    );
    expect(library.items.single.name, initial.name);
    library.failSave = false;
    await tester.tap(find.byKey(const Key('preset-save')));
    await tester.pumpAndSettle();
    expect(library.items.single.name, '我的睡眠场景');
    expect(library.items.single.quietHours!.isCrossMidnight, isTrue);
    expect(controller.isApplied(library.items.single), isFalse);
    expect(controller.hasAppliedRules(library.items.single), isTrue);
    expect(
      rulesRepository.current.rules.where(initial.ownsRule).first.name,
      contains(initial.name),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('场景编辑可选择日期，空日期阻止保存并显示错误', (tester) async {
    final scene = FilterPreset(
      id: 'work',
      name: '工作',
      kind: PresetKind.scene,
      keywords: const ['热搜'],
      quietHours: const QuietHours(
        fromMinutes: 540,
        toMinutes: 1080,
        days: {1},
      ),
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: PresetEditorPage(controller: controller, initial: scene),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilterChip, '周一'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, '周一'));
    await tester.tap(find.byKey(const Key('preset-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('preset-editor-error')), findsOneWidget);
    expect(library.items, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('库读取失败时显示重试并禁用创建，避免覆盖未读出的内容', (tester) async {
    library.failLoad = true;
    await open(tester);
    expect(find.byKey(const Key('presets-error')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('preset-create')))
          .onPressed,
      isNull,
    );
    library.failLoad = false;
    await tester.tap(find.text('重新读取'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('presets-error')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('preset-create')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('导入默认跳过同标识，选择更新时失败保留预览并可重试', (tester) async {
    const local = FilterPreset(id: 'local', name: '本机词库', keywords: ['旧词']);
    const extra = FilterPreset(id: 'extra', name: '新词库', keywords: ['新词']);
    await controller.save(local);
    final replacement = local.copyWith(name: '导入词库', keywords: ['替换词']);
    final raw = jsonEncode({
      'schemaVersion': 1,
      'presets': [replacement.toJson(), extra.toJson()],
    });
    await open(tester);
    await tool(tester, '粘贴 JSON 导入');
    await tester.enterText(find.byKey(const Key('preset-import-json')), raw);
    await tester.tap(find.byKey(const Key('preset-import-preview')));
    await tester.pumpAndSettle();
    expect(find.textContaining('新增 1 个，同标识 1 个'), findsOneWidget);
    await tester.tap(find.byKey(const Key('preset-import-confirm')));
    await tester.pumpAndSettle();
    expect(library.items.map((p) => p.name), ['本机词库', '新词库']);
    expect(rulesRepository.current.rules.map((r) => r.id), ['manual']);

    await tool(tester, '粘贴 JSON 导入');
    await tester.enterText(find.byKey(const Key('preset-import-json')), raw);
    await tester.tap(find.byKey(const Key('preset-import-preview')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('preset-import-replace')));
    await tester.pumpAndSettle();
    library.failSave = true;
    await tester.tap(find.byKey(const Key('preset-import-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('preset-import-error')), findsOneWidget);
    expect(find.textContaining('内容已保留'), findsOneWidget);
    expect(library.items.first.name, '本机词库');
    library.failSave = false;
    await tester.tap(find.byKey(const Key('preset-import-confirm')));
    await tester.pumpAndSettle();
    expect(library.items.first.name, '导入词库');
    expect(controller.versions.any((v) => v.preset.name == '本机词库'), isTrue);
    expect(rulesRepository.current.rules.map((r) => r.id), ['manual']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('命名版本保存失败保留名称，恢复只更新预设库且可找回已删除预设', (tester) async {
    const original = FilterPreset(
      id: 'versioned',
      name: '我的词库',
      keywords: ['旧词'],
    );
    await controller.save(original);
    await open(tester);
    final more = find.byKey(const ValueKey('preset-more-versioned'));
    await reveal(tester, more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存命名版本'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('preset-version-label')),
      '演示前配置',
    );
    library.failSave = true;
    await tester.tap(find.byKey(const Key('preset-version-save-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('preset-version-save-error')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('preset-version-label')))
          .controller!
          .text,
      '演示前配置',
    );
    library.failSave = false;
    await tester.tap(find.byKey(const Key('preset-version-save-confirm')));
    await tester.pumpAndSettle();
    final savedVersion = controller.versions.single;
    expect(savedVersion.label, '演示前配置');
    final edited = original.copyWith(keywords: ['新词']);
    await controller.save(edited);
    await controller.apply(edited);

    await tester.pumpWidget(
      MaterialApp(
        home: PresetVersionsPage(
          controller: controller,
          presetId: original.id,
          presetName: original.name,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final restore = find.byKey(
      ValueKey('preset-version-restore-${savedVersion.id}'),
    );
    await reveal(tester, restore);
    await tester.tap(restore);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(library.items.single.keywords, ['新词']);
    await tester.tap(restore);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('preset-version-confirm-restore')));
    await tester.pumpAndSettle();
    expect(library.items.single.keywords, ['旧词']);
    expect(
      rulesRepository.current.rules.singleWhere(original.ownsRule).keywordsAny,
      ['新词'],
    );
    expect(controller.isApplied(library.items.single), isFalse);

    await controller.remove(library.items.single);
    await tester.pumpAndSettle();
    await reveal(tester, restore);
    await tester.tap(restore);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('preset-version-confirm-restore')));
    await tester.pumpAndSettle();
    expect(library.items.single.keywords, ['旧词']);
    expect(rulesRepository.current.rules.map((r) => r.id), ['manual']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('场景切换先确认并保留常用关键词，回到日常只停用场景', (tester) async {
    const keyword = FilterPreset(id: 'daily', name: '日常词库', keywords: ['营销']);
    final work = FilterPreset.examples[1].copyWith(id: 'work', name: '工作');
    final sleep = FilterPreset.examples[2].copyWith(id: 'sleep', name: '睡眠');
    await controller.save(keyword);
    await controller.save(work);
    await controller.save(sleep);
    await controller.apply(keyword);
    await controller.switchScene(work);
    await open(tester);
    expect(find.text('已选择场景：工作'), findsOneWidget);
    final sleepButton = find.byKey(const ValueKey('preset-apply-sleep'));
    await reveal(tester, sleepButton);
    await tester.tap(sleepButton);
    await tester.pumpAndSettle();
    expect(find.text('将停用：工作'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.activeScenes.single.id, 'work');
    await tester.tap(sleepButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('preset-confirm-apply')));
    await tester.pumpAndSettle();
    expect(controller.activeScenes.single.id, 'sleep');
    expect(controller.isApplied(keyword), isTrue);
    expect(rulesRepository.current.rules.any(work.ownsRule), isFalse);
    expect(rulesRepository.current.rules.any((r) => r.id == 'manual'), isTrue);
    await tester.drag(find.byType(ListView), const Offset(0, 2500));
    await tester.pumpAndSettle();
    final daily = find.byKey(const Key('preset-daily-mode'));
    await tester.ensureVisible(daily);
    await tester.pumpAndSettle();
    await tester.tap(daily);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('preset-confirm-daily')));
    await tester.pumpAndSettle();
    expect(controller.activeScenes, isEmpty);
    expect(controller.isApplied(keyword), isTrue);
    expect(rulesRepository.current.rules.any((r) => r.id == 'manual'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文件选择取消不修改库，导出文件取消后可重试', (tester) async {
    const preset = FilterPreset(id: 'share', name: '分享词库', keywords: ['促销']);
    await controller.save(preset);
    await open(tester);
    await tool(tester, '从文件导入');
    expect(find.byKey(const Key('preset-import-json')), findsNothing);
    expect(library.items.single.toJson(), preset.toJson());
    await tool(tester, '导出全部预设');
    library.exportCancelled = true;
    await tester.tap(find.byKey(const Key('preset-export-file')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('preset-export-file')), findsOneWidget);
    expect(library.exportedText, isNull);
    expect(find.text('预设 JSON 文件已保存'), findsNothing);
    library.exportCancelled = false;
    await tester.tap(find.byKey(const Key('preset-export-file')));
    await tester.pumpAndSettle();
    final exported = jsonDecode(library.exportedText!) as Map<String, dynamic>;
    expect(exported.keys, ['schemaVersion', 'presets']);
    expect(exported['presets'], [preset.toJson()]);
    expect(find.text('预设 JSON 文件已保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
