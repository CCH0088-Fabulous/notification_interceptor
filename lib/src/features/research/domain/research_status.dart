import 'research_configuration.dart';

class ResearchStatus {
  const ResearchStatus({
    required this.configuration,
    this.totals = const {},
    this.cohorts = const {},
    this.recentHours = const [],
    this.eventCount = 0,
    this.hourCount = 0,
    this.pendingHours = 0,
    this.pendingBatches = 0,
    this.lastSuccessAt = 0,
    this.lastMessage = '',
    this.captureFailures = 0,
    this.retentionDroppedEvents = 0,
    this.retentionDroppedHours = 0,
    this.retentionDroppedBatches = 0,
    this.settingsError,
    this.debugLoopbackAllowed = false,
    this.backgroundScheduled = false,
    this.pilotAvailable = false,
    this.pilotEndpoint = '',
    this.offlineMode = true,
    this.firstHourBucket = 0,
    this.firstEventAt = 0,
    this.lastPreparedAt = 0,
  });

  final ResearchConfiguration configuration;
  final Map<String, int> totals;
  final Map<String, Map<String, int>> cohorts;
  final List<Map<String, dynamic>> recentHours;
  final int eventCount;
  final int hourCount;
  final int pendingHours;
  final int pendingBatches;
  final int lastSuccessAt;
  final String lastMessage;
  final int captureFailures;
  final int retentionDroppedEvents;
  final int retentionDroppedHours;
  final int retentionDroppedBatches;
  final String? settingsError;
  final bool debugLoopbackAllowed;
  final bool backgroundScheduled;
  final bool pilotAvailable;
  final String pilotEndpoint;
  final bool offlineMode;
  final int firstHourBucket;
  final int firstEventAt;
  final int lastPreparedAt;

  factory ResearchStatus.fromJson(Map<String, dynamic> json) {
    if ((json.containsKey('pilotAvailable') &&
            json['pilotAvailable'] is! bool) ||
        (json.containsKey('pilotEndpoint') &&
            json['pilotEndpoint'] is! String)) {
      throw const FormatException('内测接收方配置格式错误');
    }
    final config = _map(json['configuration']);
    final stats = _map(json['statistics']);
    final groups = _map(stats['cohorts']);
    if (stats['recentHours'] is! List ||
        stats['lastMessage'] is! String ||
        json['debugLoopbackAllowed'] is! bool ||
        json['backgroundScheduled'] is! bool ||
        (json['settingsError'] != null && json['settingsError'] is! String)) {
      throw const FormatException('研究状态格式错误');
    }
    return ResearchStatus(
      configuration: ResearchConfiguration.fromJson(config),
      totals: _counts(stats['totals']),
      cohorts: Map.unmodifiable(groups.map((k, v) => MapEntry(k, _counts(v)))),
      recentHours: List.unmodifiable(
        (stats['recentHours'] as List).map((row) {
          final hour = _map(row);
          if (hour['bucketStart'] is! int ||
              hour['utcOffsetMinutes'] is! int ||
              !['pilot', 'demo'].contains(hour['cohort'])) {
            throw const FormatException('小时汇总格式错误');
          }
          return Map<String, dynamic>.unmodifiable({
            ...hour,
            'metrics': _counts(hour['metrics']),
          });
        }),
      ),
      eventCount: _number(stats, 'eventCount'),
      hourCount: _number(stats, 'hourCount'),
      pendingHours: _number(stats, 'pendingHours'),
      pendingBatches: _number(stats, 'pendingBatches'),
      lastSuccessAt: _number(stats, 'lastSuccessAt'),
      lastMessage: stats['lastMessage'] as String,
      captureFailures: _number(json, 'captureFailures'),
      retentionDroppedEvents: _number(stats, 'retentionDroppedEvents'),
      retentionDroppedHours: _number(stats, 'retentionDroppedHours'),
      retentionDroppedBatches: _number(stats, 'retentionDroppedBatches'),
      settingsError: json['settingsError'] as String?,
      debugLoopbackAllowed: json['debugLoopbackAllowed'] as bool,
      backgroundScheduled: json['backgroundScheduled'] as bool,
      pilotAvailable: json['pilotAvailable'] as bool? ?? false,
      pilotEndpoint: json['pilotEndpoint'] as String? ?? '',
      offlineMode: json['offlineMode'] as bool? ?? true,
      firstHourBucket: stats['firstHourBucket'] as int? ?? 0,
      firstEventAt: stats['firstEventAt'] as int? ?? 0,
      lastPreparedAt: stats['lastPreparedAt'] as int? ?? 0,
    );
  }

  static Map<String, dynamic> _map(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const FormatException('研究对象格式错误');
    }
    return value.cast<String, dynamic>();
  }

  static int _number(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! int || value < 0) throw const FormatException('研究计数格式错误');
    return value;
  }

  static Map<String, int> _counts(Object? value) {
    final map = _map(value);
    return Map.unmodifiable(
      map.map((key, _) => MapEntry(key, _number(map, key))),
    );
  }
}
