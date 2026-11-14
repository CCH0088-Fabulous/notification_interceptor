import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/presets/domain/filter_preset.dart';
import 'package:notifinterceptor/src/features/presets/domain/presets_repository.dart';
import 'package:notifinterceptor/src/features/presets/domain/preset_version.dart';
import 'package:notifinterceptor/src/features/presets/presentation/presets_controller.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_record.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_set.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_spec.dart';
import 'package:notifinterceptor/src/features/rules/domain/rules_repository.dart';
import 'package:notifinterceptor/src/features/rules/presentation/rules_controller.dart';
import 'package:notifinterceptor/src/shared/domain/decision.dart';
import 'package:notifinterceptor/src/shared/domain/rule_action.dart';

class _Presets implements PresetsRepository {
  List<FilterPreset> items = [];
  bool failLoad = false;
  bool failSave = false;
  Completer<void>? saveGate;
  List<PresetVersion> savedVersions = [];
  bool failVersions = false;
  bool fileCancelled = false;
  String? fileContent;
  String? exportedContent;
  int librarySaveCount = 0;
  @override
  Future<List<FilterPreset>> load() async {
    if (failLoad) throw StateError('预设文件损坏');
    return items;
  }

  @override
  Future<void> save(List<FilterPreset> presets) async {
    if (saveGate != null) await saveGate!.future;
    if (failSave) throw StateError('写盘失败');
    librarySaveCount++;
    items = List.of(presets);
  }

  @override
  Future<List<PresetVersion>> loadVersions() async {
    if (failVersions) throw StateError('读取版本失败');
    return savedVersions;
  }

  @override
  Future<void> saveVersion(String presetId, {String? label}) async {
    if (failSave) throw StateError('保存版本失败');
    final preset = items.singleWhere((p) => p.id == presetId);
    savedVersions = [
      PresetVersion(
        id: 'version_${savedVersions.length}',
        createdAt: 1793721600000 + savedVersions.length,
        label: label ?? '手动版本',
        preset: preset,
      ),
      ...savedVersions,
    ];
  }

  @override
  Future<String?> importFile() async => fileCancelled ? null : fileContent;

  @override
  Future<bool> exportFile(String content, {required String fileName}) async {
    if (fileCancelled) return false;
    exportedContent = content;
    return true;
  }
}

class _Rules implements RulesRepository {
  RuleSet current = const RuleSet(
    globalEnabled: false,
    defaultAction: RuleAction.logOnly,
    rules: [
      RuleSpec(
        id: 'manual_keep',
        name: '重要联系人',
        keywordsAny: ['家人'],
        action: RuleAction.allow,
      ),
      RuleSpec(id: 'manual_drop', name: '原有规则', keywordsAny: ['广告']),
    ],
  );
  bool failSave = false;
  bool failLoad = false;
  int saveCount = 0;
  @override
  Future<RuleSet> load() async {
    if (failLoad) throw StateError('读取规则失败');
    return current;
  }

  @override
  Future<RuleSaveResult> save(RuleSet ruleSet) async {
    if (failSave) throw StateError('规则写盘失败');
    saveCount++;
    current = ruleSet;
    return RuleSaveResult(ruleSet: ruleSet, issues: []);
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
  Future<List<String>> seenPackages() async => [];
}

void main() {
  const preset = FilterPreset(
    id: 'p1',
    name: '营销',
    keywords: ['优惠'],
    allowKeywords: ['验证码'],
  );
  late _Presets library;
  late _Rules nativeRules;
  late RulesController rules;
  late PresetsController controller;
  setUp(() async {
    library = _Presets();
    nativeRules = _Rules();
    rules = RulesController(repository: nativeRules);
    controller = PresetsController(repository: library, rules: rules);
    await rules.load();
    await controller.load();
  });
  tearDown(() {
    controller.dispose();
    rules.dispose();
  });

  test('保存不启用；应用幂等且保留手动规则、全局关闭与默认动作', () async {
    await controller.save(preset);
    expect(nativeRules.saveCount, 0);
    expect(controller.isApplied(preset), false);
    // An external rule added after the UI loaded must survive activation.
    nativeRules.current = nativeRules.current.copyWith(
      rules: [
        ...nativeRules.current.rules,
        const RuleSpec(id: 'external', name: '新外部规则', keywordsAny: ['新闻']),
      ],
    );
    await controller.apply(preset);
    await controller.apply(preset);
    expect(nativeRules.current.rules.map((r) => r.id), [
      'manual_keep',
      'preset:keywords:p1:allow',
      'preset:keywords:p1:intercept',
      'manual_drop',
      'external',
    ]);
    expect(nativeRules.current.globalEnabled, false);
    expect(nativeRules.current.defaultAction, RuleAction.logOnly);
    expect(controller.isApplied(preset), true);
    await controller.deactivate(preset);
    expect(nativeRules.current.rules.map((r) => r.id), [
      'manual_keep',
      'manual_drop',
      'external',
    ]);
    expect(controller.presets, hasLength(1));
  });

  test('多个预设可叠加，优先保留排在拦截前；仅停用目标预设', () async {
    final second = preset.copyWith(id: 'p2', name: '资讯', keywords: ['热搜']);
    await controller.save(preset);
    await controller.save(second);
    await controller.apply(preset);
    await controller.apply(second);
    final firstDrop = nativeRules.current.rules.indexWhere(
      (r) => r.action == RuleAction.intercept,
    );
    expect(
      nativeRules.current.rules
          .take(firstDrop)
          .every((r) => r.action == RuleAction.allow),
      true,
    );
    expect(controller.isApplied(preset), true);
    expect(controller.isApplied(second), true);
    await controller.deactivate(preset);
    expect(controller.hasAppliedRules(preset), false);
    expect(controller.isApplied(second), true);
  });

  test('编辑库不偷偷更改运行规则，重新应用更新且不重复', () async {
    await controller.save(preset);
    await controller.apply(preset);
    final edited = preset.copyWith(keywords: ['新品']);
    await controller.save(edited);
    expect(controller.hasAppliedRules(edited), true);
    expect(controller.isApplied(edited), false);
    expect(nativeRules.current.rules.lastWhere(preset.ownsRule).keywordsAny, [
      '优惠',
    ]);
    await expectLater(controller.apply(preset), throwsStateError);
    await controller.apply(edited);
    expect(controller.isApplied(edited), true);
    expect(nativeRules.current.rules.where(preset.ownsRule), hasLength(2));
  });

  test('删除先停用且不影响其他规则；保存失败保留库并可重试', () async {
    await controller.save(preset);
    await controller.apply(preset);
    library.failSave = true;
    await expectLater(controller.remove(preset), throwsStateError);
    expect(controller.presets, hasLength(1));
    expect(controller.hasAppliedRules(preset), false);
    library.failSave = false;
    await controller.remove(preset);
    expect(controller.presets, isEmpty);
    expect(nativeRules.current.rules.map((r) => r.id), [
      'manual_keep',
      'manual_drop',
    ]);
  });

  test('规则写入或读取失败不报成功、不删库、不丢原有规则', () async {
    await controller.save(preset);
    nativeRules.failSave = true;
    await expectLater(controller.apply(preset), throwsStateError);
    expect(controller.hasAppliedRules(preset), false);
    expect(rules.ruleSet.rules, hasLength(2));
    nativeRules.failSave = false;
    await controller.apply(preset);
    nativeRules.failLoad = true;
    await expectLater(controller.remove(preset), throwsStateError);
    expect(controller.presets, hasLength(1));
    expect(controller.isApplied(preset), true);
  });

  test('读库失败禁止保存覆盖；写库失败保留原数据', () async {
    await controller.save(preset);
    library.failSave = true;
    await expectLater(
      controller.save(preset.copyWith(name: '新名称')),
      throwsStateError,
    );
    expect(controller.presets.single.name, '营销');
    library.failLoad = true;
    await controller.load();
    expect(controller.error, isNotNull);
    await expectLater(controller.save(preset), throwsStateError);
    expect(library.items.single.name, '营销');
  });

  test('并发操作被拒绝，持久化完成后可重新加载并恢复预设', () async {
    library.saveGate = Completer<void>();
    final saving = controller.save(preset);
    await expectLater(
      controller.save(preset.copyWith(id: 'p2')),
      throwsStateError,
    );
    library.saveGate!.complete();
    await saving;
    final reloaded = PresetsController(repository: library, rules: rules);
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.presets.single.toJson(), preset.toJson());
  });

  test('场景互斥切换一次写入，保留常用词、手动规则和全局设置', () async {
    final work = FilterPreset.examples[1].copyWith(id: 'work');
    final sleep = FilterPreset.examples[2].copyWith(id: 'sleep');
    await controller.save(preset);
    await controller.save(work);
    await controller.save(sleep);
    await controller.apply(preset);
    await controller.apply(work);
    expect(controller.activeScenes.map((p) => p.id), ['work']);
    final savesBefore = nativeRules.saveCount;
    await controller.switchScene(sleep);
    expect(nativeRules.saveCount, savesBefore + 1);
    expect(controller.hasAppliedRules(work), false);
    expect(controller.isApplied(preset), true);
    expect(controller.isApplied(sleep), true);
    expect(controller.activeScenes.map((p) => p.id), ['sleep']);
    expect(nativeRules.current.globalEnabled, false);
    expect(nativeRules.current.defaultAction, RuleAction.logOnly);
    expect(
      nativeRules.current.rules
          .where((r) => r.id.startsWith('manual_'))
          .map((r) => r.id),
      ['manual_keep', 'manual_drop'],
    );
    await controller.deactivateScenes();
    expect(controller.activeScenes, isEmpty);
    expect(controller.isApplied(preset), true);
  });

  test('场景切换写入失败保留旧场景，旧版多个场景仅显式切换时归一', () async {
    final work = FilterPreset.examples[1].copyWith(id: 'work');
    final sleep = FilterPreset.examples[2].copyWith(id: 'sleep');
    await controller.save(work);
    await controller.save(sleep);
    nativeRules.current = nativeRules.current.copyWith(
      rules: [
        ...nativeRules.current.rules,
        ...work.toRules().map(
          (r) => r.copyWith(
            id: r.action == RuleAction.allow
                ? 'preset_work_allow'
                : 'preset_work_intercept',
          ),
        ),
        ...sleep.toRules().map(
          (r) => r.copyWith(
            id: r.action == RuleAction.allow
                ? 'preset_sleep_allow'
                : 'preset_sleep_intercept',
          ),
        ),
      ],
    );
    await rules.load();
    expect(controller.activeScenes, hasLength(2));
    nativeRules.failSave = true;
    await expectLater(controller.switchScene(sleep), throwsStateError);
    expect(controller.activeScenes, hasLength(2));
    nativeRules.failSave = false;
    await controller.switchScene(sleep);
    expect(controller.activeScenes.map((p) => p.id), ['sleep']);
    expect(
      nativeRules.current.rules.any((r) => r.id.startsWith('preset_')),
      false,
    );
  });

  test('预设类别编辑后按已安装来源识别场景，不偷偷应用未确认修改', () async {
    final work = FilterPreset.examples[1].copyWith(id: 'work');
    final sleep = FilterPreset.examples[2].copyWith(id: 'sleep');
    await controller.save(work);
    await controller.save(sleep);
    await controller.apply(work);
    await controller.save(
      work.copyWith(kind: PresetKind.keywords, quietHours: null),
    );
    expect(controller.activeScenes.map((p) => p.id), ['work']);
    await controller.switchScene(sleep);
    expect(controller.hasAppliedRules(work), false);

    await controller.save(preset);
    await controller.apply(preset);
    await controller.save(preset.copyWith(kind: PresetKind.scene));
    await controller.switchScene(sleep);
    expect(controller.hasAppliedRules(preset), true);
    expect(
      nativeRules.current.rules
          .where(preset.ownsRule)
          .every((r) => r.id.startsWith('preset:keywords:')),
      true,
    );
  });

  test('命名版本和恢复只更新词库；删除后可恢复并保留其他预设', () async {
    await controller.save(preset);
    await controller.saveVersion(preset, label: '演示前');
    final version = controller.versions.single;
    expect(version.label, '演示前');
    expect(nativeRules.saveCount, 0);
    await controller.apply(preset);
    final edited = preset.copyWith(keywords: ['上新']);
    await controller.save(edited);
    await controller.apply(edited);
    final running = jsonEncode(nativeRules.current.toJson());
    await controller.restoreVersion(version);
    expect(controller.presets.single.keywords, ['优惠']);
    expect(jsonEncode(nativeRules.current.toJson()), running);
    expect(controller.isApplied(preset), false);
    await controller.remove(preset);
    final other = preset.copyWith(id: 'other', name: '另一个');
    await controller.save(other);
    await controller.restoreVersion(version);
    expect(controller.presets.map((p) => p.id), ['other', 'p1']);
    expect(controller.hasAppliedRules(preset), false);
    final unknown = PresetVersion(
      id: 'missing',
      createdAt: version.createdAt,
      label: '不存在',
      preset: preset,
    );
    await expectLater(controller.restoreVersion(unknown), throwsStateError);
  });

  test('导入预览处理同ID冲突，只入库；过期预览和坏内容不能覆盖数据', () async {
    await controller.save(preset);
    await controller.apply(preset);
    final beforeRules = jsonEncode(nativeRules.current.toJson());
    final imported = preset.copyWith(name: '外部版本', keywords: ['新品']);
    final added = preset.copyWith(id: 'added', name: '新增');
    final raw = jsonEncode({
      'schemaVersion': 1,
      'presets': [imported.toJson(), added.toJson()],
    });
    var plan = controller.previewImport(raw);
    expect(plan.addedCount, 1);
    expect(plan.updatedCount, 1);
    await controller.importPresets(plan);
    expect(controller.presets.first.name, '营销');
    expect(controller.presets, hasLength(2));
    plan = controller.previewImport(raw);
    await controller.importPresets(plan, replaceExisting: true);
    expect(controller.presets.first.name, '外部版本');
    expect(jsonEncode(nativeRules.current.toJson()), beforeRules);
    final stale = controller.previewImport(raw);
    await controller.save(added.copyWith(name: '本机新编辑'));
    final saves = library.librarySaveCount;
    await expectLater(
      controller.importPresets(stale, replaceExisting: true),
      throwsStateError,
    );
    expect(library.librarySaveCount, saves);
    expect(() => controller.previewImport('{bad'), throwsFormatException);
    expect(
      jsonDecode(controller.exportJson()).keys,
      unorderedEquals(['schemaVersion', 'presets']),
    );
  });

  test('文件取消不写库，导出不含版本和运行规则，版本刷新失败不误报保存失败', () async {
    await controller.save(preset);
    await controller.saveVersion(preset);
    final saves = library.librarySaveCount;
    library.fileCancelled = true;
    expect(await controller.importFile(), isNull);
    expect(await controller.exportFile(controller.exportJson()), false);
    expect(library.librarySaveCount, saves);
    expect(nativeRules.saveCount, 0);
    library.fileCancelled = false;
    expect(
      await controller.exportFile(controller.exportJson(ids: {'p1'})),
      true,
    );
    final exported = jsonDecode(library.exportedContent!) as Map;
    expect(exported.keys, unorderedEquals(['schemaVersion', 'presets']));
    library.failVersions = true;
    await controller.save(preset.copyWith(name: '已保存'));
    expect(controller.presets.single.name, '已保存');
    expect(controller.versions, isEmpty);
    expect(controller.error, contains('预设已保存'));
  });

  test('旧版场景改为词库时只迁移运行规则ID，随后切换能移除旧场景', () async {
    final work = FilterPreset.examples[1].copyWith(id: 'work');
    final sleep = FilterPreset.examples[2].copyWith(id: 'sleep');
    await controller.save(work);
    await controller.save(sleep);
    final legacy = work
        .toRules()
        .map(
          (rule) => rule.copyWith(
            id: rule.action == RuleAction.allow
                ? 'preset_work_allow'
                : 'preset_work_intercept',
            name: '用户已改名的规则',
            enabled: rule.action != RuleAction.allow,
            titleRegex: '促销|直播',
            channelIds: ['marketing'],
            isClearable: true,
          ),
        )
        .toList();
    // The native file is newer than the controller mirror. Migration must use
    // that fresh file and preserve even manually edited conditions and order.
    nativeRules.current = nativeRules.current.copyWith(
      rules: [...nativeRules.current.rules, ...legacy],
    );
    final original = nativeRules.current;
    final saves = nativeRules.saveCount;
    await controller.save(
      work.copyWith(kind: PresetKind.keywords, quietHours: null),
    );
    expect(nativeRules.saveCount, saves + 1);
    final expected = original.copyWith(
      rules: original.rules
          .map(
            (rule) => work.ownsRule(rule)
                ? rule.copyWith(
                    id: rule.action == RuleAction.allow
                        ? 'preset:scene:work:allow'
                        : 'preset:scene:work:intercept',
                  )
                : rule,
          )
          .toList(),
    );
    expect(nativeRules.current.toJson(), expected.toJson());
    expect(controller.presets.first.kind, PresetKind.keywords);
    expect(controller.activeScenes.map((scene) => scene.id), ['work']);
    await controller.switchScene(sleep);
    expect(controller.hasAppliedRules(work), false);
    expect(controller.isApplied(sleep), true);
    expect(nativeRules.current.globalEnabled, false);
    expect(nativeRules.current.defaultAction, RuleAction.logOnly);
  });

  test('旧词库改场景保留原运行类别，迁移或库写入失败均可安全重试', () async {
    await controller.save(preset);
    final legacy = preset
        .toRules()
        .map(
          (rule) => rule.copyWith(
            id: rule.action == RuleAction.allow
                ? 'preset_p1_allow'
                : 'preset_p1_intercept',
          ),
        )
        .toList();
    nativeRules.current = nativeRules.current.copyWith(
      rules: [...nativeRules.current.rules, ...legacy],
    );
    final original = nativeRules.current;
    final changed = preset.copyWith(kind: PresetKind.scene);
    nativeRules.failSave = true;
    await expectLater(controller.save(changed), throwsStateError);
    expect(nativeRules.current.toJson(), original.toJson());
    expect(controller.presets.single.kind, PresetKind.keywords);

    nativeRules.failSave = false;
    library.failSave = true;
    await expectLater(controller.save(changed), throwsStateError);
    final migrated = original.copyWith(
      rules: original.rules
          .map(
            (rule) => preset.ownsRule(rule)
                ? rule.copyWith(
                    id: rule.action == RuleAction.allow
                        ? 'preset:keywords:p1:allow'
                        : 'preset:keywords:p1:intercept',
                  )
                : rule,
          )
          .toList(),
    );
    expect(nativeRules.current.toJson(), migrated.toJson());
    expect(controller.presets.single.kind, PresetKind.keywords);

    library.failSave = false;
    final writesBeforeRetry = nativeRules.saveCount;
    await controller.save(changed);
    expect(nativeRules.saveCount, writesBeforeRetry);
    expect(controller.activeScenes, isEmpty);
    final sleep = FilterPreset.examples[2].copyWith(id: 'sleep');
    await controller.save(sleep);
    await controller.switchScene(sleep);
    expect(controller.hasAppliedRules(preset), true);
    expect(
      nativeRules.current.rules
          .where(preset.ownsRule)
          .map((rule) => rule.toJson()),
      migrated.rules.where(preset.ownsRule).map((rule) => rule.toJson()),
    );

    // A collision must be rejected before any rule file is written.
    nativeRules.current = nativeRules.current.copyWith(
      rules: [...nativeRules.current.rules, legacy.first],
    );
    final beforeCollision = nativeRules.current.toJson();
    final writesBeforeCollision = nativeRules.saveCount;
    await expectLater(
      rules.renameManagedRuleIds({
        'preset_p1_allow': 'preset:keywords:p1:allow',
      }),
      throwsStateError,
    );
    expect(nativeRules.current.toJson(), beforeCollision);
    expect(nativeRules.saveCount, writesBeforeCollision);
  });
}
