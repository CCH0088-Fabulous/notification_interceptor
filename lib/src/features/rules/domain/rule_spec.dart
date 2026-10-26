import '../../../core/util/json_cast.dart';
import '../../../shared/domain/rule_action.dart';
import 'quiet_hours.dart';

/// 条件组之间的组合方式。all = AND（默认），any = OR。
enum MatchMode {
  all('all', '全部满足'),
  any('any', '任一满足');

  const MatchMode(this.wire, this.label);

  final String wire;
  final String label;

  static MatchMode fromWire(Object? value) {
    final raw = value?.toString();
    for (final mode in MatchMode.values) {
      if (mode.wire == raw) return mode;
    }
    return MatchMode.all;
  }
}

/// 单条规则。字段名与 Kotlin `RuleSpec` 的 JSON 契约一致。
class RuleSpec {
  const RuleSpec({
    required this.id,
    required this.name,
    this.enabled = true,
    this.action = RuleAction.intercept,
    this.mode = MatchMode.all,
    this.packages = const [],
    this.keywordsAny = const [],
    this.titleRegex,
    this.textRegex,
    this.channelIds = const [],
    this.isOngoing,
    this.isClearable,
    this.quietHours,
  });

  final String id;
  final String name;
  final bool enabled;
  final RuleAction action;
  final MatchMode mode;
  final List<String> packages;
  final List<String> keywordsAny;
  final String? titleRegex;
  final String? textRegex;
  final List<String> channelIds;
  final bool? isOngoing;
  final bool? isClearable;
  final QuietHours? quietHours;

  bool get hasAnyCondition =>
      packages.any((item) => item.trim().isNotEmpty) ||
      keywordsAny.any((item) => item.trim().isNotEmpty) ||
      (titleRegex?.trim().isNotEmpty ?? false) ||
      (textRegex?.trim().isNotEmpty ?? false) ||
      channelIds.any((item) => item.trim().isNotEmpty) ||
      isOngoing != null ||
      isClearable != null ||
      quietHours != null;

  /// 条件摘要，列表页展示用。
  String get summary {
    final parts = <String>[];
    if (packages.isNotEmpty) parts.add('应用 ${packages.length} 个');
    if (keywordsAny.isNotEmpty) parts.add('关键词 ${keywordsAny.join('/')}');
    if (titleRegex?.isNotEmpty ?? false) parts.add('标题正则');
    if (textRegex?.isNotEmpty ?? false) parts.add('正文正则');
    if (channelIds.isNotEmpty) parts.add('渠道 ${channelIds.join('/')}');
    if (isOngoing != null) parts.add(isOngoing! ? '含常驻' : '非常驻');
    if (isClearable != null) parts.add(isClearable! ? '可清除' : '不可清除');
    if (quietHours != null) parts.add('静默 ${quietHours!.label}');
    if (parts.isEmpty) return '无条件（不会命中）';
    return parts.join(' · ');
  }

  RuleSpec copyWith({
    String? id,
    String? name,
    bool? enabled,
    RuleAction? action,
    MatchMode? mode,
    List<String>? packages,
    List<String>? keywordsAny,
    Object? titleRegex = _unset,
    Object? textRegex = _unset,
    List<String>? channelIds,
    Object? isOngoing = _unset,
    Object? isClearable = _unset,
    Object? quietHours = _unset,
  }) =>
      RuleSpec(
        id: id ?? this.id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        action: action ?? this.action,
        mode: mode ?? this.mode,
        packages: packages ?? this.packages,
        keywordsAny: keywordsAny ?? this.keywordsAny,
        titleRegex: identical(titleRegex, _unset) ? this.titleRegex : titleRegex as String?,
        textRegex: identical(textRegex, _unset) ? this.textRegex : textRegex as String?,
        channelIds: channelIds ?? this.channelIds,
        isOngoing: identical(isOngoing, _unset) ? this.isOngoing : isOngoing as bool?,
        isClearable: identical(isClearable, _unset) ? this.isClearable : isClearable as bool?,
        quietHours: identical(quietHours, _unset) ? this.quietHours : quietHours as QuietHours?,
      );

  factory RuleSpec.fromJson(Map<String, dynamic> json) {
    final match = asStringMap(json['match']);
    final quiet = match['quietHours'];
    final rawOngoing = match['isOngoing'];
    final rawClearable = match['isClearable'];
    return RuleSpec(
      id: asStringOrNull(json['id']) ?? '',
      name: asStringOrNull(json['name']) ?? '',
      enabled: asBool(json['enabled'], fallback: true),
      action: RuleAction.fromWire(json['action']),
      mode: MatchMode.fromWire(match['mode']),
      packages: asStringList(match['packages']).where((e) => e.trim().isNotEmpty).toList(),
      keywordsAny: asStringList(match['keywordsAny']).where((e) => e.trim().isNotEmpty).toList(),
      titleRegex: (asStringOrNull(match['titleRegex'])?.trim().isEmpty ?? true)
          ? null
          : asStringOrNull(match['titleRegex']),
      textRegex: (asStringOrNull(match['textRegex'])?.trim().isEmpty ?? true)
          ? null
          : asStringOrNull(match['textRegex']),
      channelIds: asStringList(match['channelIds']).where((e) => e.trim().isNotEmpty).toList(),
      isOngoing: rawOngoing is bool ? rawOngoing : null,
      isClearable: rawClearable is bool ? rawClearable : null,
      quietHours: quiet is Map ? QuietHours.fromJson(asStringMap(quiet)) : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'action': action.wire,
        'match': {
          'mode': mode.wire,
          'packages': packages,
          'keywordsAny': keywordsAny,
          'titleRegex': titleRegex,
          'textRegex': textRegex,
          'channelIds': channelIds,
          'isOngoing': isOngoing,
          'isClearable': isClearable,
          'quietHours': quietHours?.toJson(),
        },
      };
}

const Object _unset = Object();
