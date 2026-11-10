import '../../rules/domain/quiet_hours.dart';
import '../../rules/domain/rule_spec.dart';
import '../../../shared/domain/rule_action.dart';

enum PresetKind {
  keywords('关键词预设'),
  scene('场景预设');

  const PresetKind(this.label);
  final String label;
}

/// A reusable definition, separate from the currently installed native rules.
class FilterPreset {
  const FilterPreset({
    required this.id,
    required this.name,
    this.kind = PresetKind.keywords,
    this.keywords = const [],
    this.allowKeywords = const [],
    this.packages = const [],
    this.quietHours,
  });

  final String id;
  final String name;
  final PresetKind kind;
  final List<String> keywords;
  final List<String> allowKeywords;
  final List<String> packages;
  final QuietHours? quietHours;

  static const examples = [
    FilterPreset(
      id: 'template_marketing',
      name: '减少营销打扰',
      keywords: ['限时优惠', '优惠券', '秒杀', '促销'],
      allowKeywords: ['验证码', '取件码'],
    ),
    FilterPreset(
      id: 'template_work',
      name: '工作专注',
      kind: PresetKind.scene,
      keywords: ['促销', '游戏', '直播', '热搜'],
      allowKeywords: ['会议', '验证码', '日程'],
      quietHours: QuietHours(
        fromMinutes: 9 * 60,
        toMinutes: 18 * 60,
        days: {1, 2, 3, 4, 5},
      ),
    ),
    FilterPreset(
      id: 'template_sleep',
      name: '睡眠少打扰',
      kind: PresetKind.scene,
      keywords: ['促销', '推荐', '直播', '游戏', '热搜'],
      allowKeywords: ['紧急', '验证码'],
      quietHours: QuietHours(
        fromMinutes: 22 * 60,
        toMinutes: 8 * 60,
        days: {1, 2, 3, 4, 5, 6, 7},
      ),
    ),
  ];

  List<String> validate() {
    final errors = <String>[];
    if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(id)) {
      errors.add('预设标识无效');
    }
    if (name.trim().isEmpty || name != name.trim() || name.length > 60) {
      errors.add('名称需为 1–60 个字符');
    }
    if (keywords.isEmpty) errors.add('请至少填写一个移除词');
    for (final words in [keywords, allowKeywords]) {
      if (words.length > 100 ||
          words.any(
            (word) =>
                word.trim().isEmpty || word != word.trim() || word.length > 100,
          )) {
        errors.add('每组最多 100 个词，每个词需为 1–100 个字符');
      }
    }
    if (packages.length > 100 ||
        packages.any(
          (value) =>
              value.length > 100 ||
              !RegExp(
                r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$',
              ).hasMatch(value),
        )) {
      errors.add('应用包名格式不正确，每组最多 100 个');
    }
    final hours = quietHours;
    if (kind == PresetKind.keywords && hours != null) {
      errors.add('关键词预设不设置时段，请改用场景预设');
    }
    if (hours != null &&
        (hours.fromMinutes < 0 ||
            hours.fromMinutes >= 1440 ||
            hours.toMinutes < 0 ||
            hours.toMinutes >= 1440 ||
            hours.fromMinutes == hours.toMinutes ||
            hours.days.isEmpty ||
            hours.days.any((day) => day < 1 || day > 7))) {
      errors.add('请选择不同的起止时间和至少一个生效日期');
    }
    return errors;
  }

  bool ownsRule(RuleSpec rule) =>
      rule.id == 'preset_${id}_allow' ||
      rule.id == 'preset_${id}_intercept' ||
      rule.id == 'preset:keywords:$id:allow' ||
      rule.id == 'preset:keywords:$id:intercept' ||
      rule.id == 'preset:scene:$id:allow' ||
      rule.id == 'preset:scene:$id:intercept';

  /// Stable machine-readable ownership, independent of editable names/kinds.
  /// Old underscore IDs remain owned until a preset is explicitly reapplied.
  String get _rulePrefix => 'preset:${kind.name}:$id';

  /// All groups use AND; within a keyword list any word matches. Exceptions
  /// share the same app/time scope, so a scene cannot allow outside its window.
  List<RuleSpec> toRules() {
    final errors = validate();
    if (errors.isNotEmpty) throw FormatException(errors.join('；'));
    return [
      if (allowKeywords.isNotEmpty)
        RuleSpec(
          id: '$_rulePrefix:allow',
          name: '预设「$name」· 优先保留',
          action: RuleAction.allow,
          packages: packages,
          keywordsAny: allowKeywords,
          quietHours: quietHours,
        ),
      RuleSpec(
        id: '$_rulePrefix:intercept',
        name: '预设「$name」· 拦截',
        packages: packages,
        keywordsAny: keywords,
        quietHours: quietHours,
      ),
    ];
  }

  FilterPreset copyWith({
    String? id,
    String? name,
    PresetKind? kind,
    List<String>? keywords,
    List<String>? allowKeywords,
    List<String>? packages,
    Object? quietHours = _unset,
  }) => FilterPreset(
    id: id ?? this.id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    keywords: keywords ?? this.keywords,
    allowKeywords: allowKeywords ?? this.allowKeywords,
    packages: packages ?? this.packages,
    quietHours: identical(quietHours, _unset)
        ? this.quietHours
        : quietHours as QuietHours?,
  );

  factory FilterPreset.fromJson(Map<String, dynamic> json) {
    List<String> strings(String key) {
      final value = json[key];
      if (value is! List || value.any((item) => item is! String)) {
        throw FormatException('预设 $key 格式错误');
      }
      return List<String>.unmodifiable(value.cast<String>());
    }

    final kind = PresetKind.values.where((kind) => kind.name == json['kind']);
    if (json['id'] is! String || json['name'] is! String || kind.isEmpty) {
      throw const FormatException('预设标识、名称或类型无效');
    }
    final hoursValue = json['quietHours'];
    QuietHours? hours;
    if (hoursValue != null) {
      if (hoursValue is! Map || hoursValue.keys.any((key) => key is! String)) {
        throw const FormatException('场景时段格式错误');
      }
      final rawHours = Map<String, dynamic>.from(hoursValue);
      if (rawHours['days'] is! List ||
          (rawHours['days'] as List).isEmpty ||
          (rawHours['days'] as List).length > 7 ||
          (rawHours['days'] as List).toSet().length !=
              (rawHours['days'] as List).length ||
          (rawHours['days'] as List).any((d) => d is! int || d < 1 || d > 7) ||
          rawHours['from'] is! String ||
          rawHours['to'] is! String ||
          !RegExp(
            r'^([01]\d|2[0-3]):[0-5]\d$',
          ).hasMatch(rawHours['from'] as String) ||
          !RegExp(
            r'^([01]\d|2[0-3]):[0-5]\d$',
          ).hasMatch(rawHours['to'] as String)) {
        throw const FormatException('场景时段格式错误');
      }
      hours = QuietHours.fromJson(rawHours);
    }
    final preset = FilterPreset(
      id: json['id'] as String,
      name: json['name'] as String,
      kind: kind.single,
      keywords: strings('keywords'),
      allowKeywords: strings('allowKeywords'),
      packages: strings('packages'),
      quietHours: hours,
    );
    final errors = preset.validate();
    if (errors.isNotEmpty) throw FormatException(errors.join('；'));
    return preset;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'keywords': keywords,
    'allowKeywords': allowKeywords,
    'packages': packages,
    'quietHours': quietHours?.toJson(),
  };
}

const _unset = Object();
