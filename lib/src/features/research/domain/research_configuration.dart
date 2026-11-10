class ResearchConfiguration {
  const ResearchConfiguration({
    this.enabled = false,
    this.ruleStructures = false,
    this.autoUpload = false,
    this.wifiOnly = true,
    this.cohort = 'pilot',
    this.endpoint = '',
    this.hasToken = false,
    this.participantId = '',
    this.consentAt = 0,
    this.revision = 0,
    this.pilotPending = false,
    this.pilotEnrolled = false,
    this.endedAt = 0,
    this.acceptedDisclosureVersion = 0,
  });

  final bool enabled;
  final bool ruleStructures;
  final bool autoUpload;
  final bool wifiOnly;
  final String cohort;
  final String endpoint;
  final bool hasToken;
  final String participantId;
  final int consentAt;
  final int revision;
  final bool pilotPending;
  final bool pilotEnrolled;
  final int endedAt;
  final int acceptedDisclosureVersion;
  bool get hasStudy => participantId.isNotEmpty;

  factory ResearchConfiguration.fromJson(Map<String, dynamic> json) {
    for (final key in ['endedAt', 'acceptedDisclosureVersion']) {
      if (json.containsKey(key) &&
          (json[key] is! int || (json[key] as int) < 0)) {
        throw const FormatException('内测周期格式错误');
      }
    }
    for (final key in ['pilotPending', 'pilotEnrolled']) {
      if (json.containsKey(key) && json[key] is! bool) {
        throw const FormatException('内测连接状态格式错误');
      }
    }
    for (final key in [
      'enabled',
      'ruleStructures',
      'autoUpload',
      'wifiOnly',
      'hasToken',
    ]) {
      if (json[key] is! bool) throw const FormatException('研究开关格式错误');
    }
    for (final key in ['cohort', 'endpoint', 'participantId']) {
      if (json[key] is! String) throw const FormatException('研究配置格式错误');
    }
    for (final key in ['consentAt', 'revision']) {
      if (json[key] is! int || (json[key] as int) < 0) {
        throw const FormatException('研究配置版本错误');
      }
    }
    if (!['pilot', 'demo'].contains(json['cohort']) ||
        ![1, 2].contains(json['disclosureVersion'])) {
      throw const FormatException('不支持的研究配置');
    }
    if (json.containsKey('token') || json.containsKey('encryptedToken')) {
      throw const FormatException('研究响应包含不应返回的令牌');
    }
    return ResearchConfiguration(
      enabled: json['enabled'] as bool,
      ruleStructures: json['ruleStructures'] as bool,
      autoUpload: json['autoUpload'] as bool,
      wifiOnly: json['wifiOnly'] as bool,
      cohort: json['cohort'] as String,
      endpoint: json['endpoint'] as String,
      hasToken: json['hasToken'] as bool,
      participantId: json['participantId'] as String,
      consentAt: json['consentAt'] as int,
      revision: json['revision'] as int,
      pilotPending: json['pilotPending'] as bool? ?? false,
      pilotEnrolled: json['pilotEnrolled'] as bool? ?? false,
      endedAt: json['endedAt'] as int? ?? 0,
      acceptedDisclosureVersion:
          json['acceptedDisclosureVersion'] as int? ??
          json['disclosureVersion'] as int,
    );
  }
}
