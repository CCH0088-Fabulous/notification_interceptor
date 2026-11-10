enum UsageAction {
  pageFeed('page_feed'),
  pageRules('page_rules'),
  pageHistory('page_history'),
  pageSettings('page_settings'),
  openPresets('open_presets'),
  openComparison('open_comparison'),
  comparisonCompleted('comparison_completed'),
  sceneSwitch('scene_switch'),
  sceneEnd('scene_end'),
  presetApply('preset_apply'),
  presetRestore('preset_restore'),
  presetImport('preset_import'),
  presetExport('preset_export');

  const UsageAction(this.wire);
  final String wire;
}

/// Optional, best-effort observer. Product operations must not depend on it.
abstract interface class UsageRecorder {
  void record(UsageAction action);
}
