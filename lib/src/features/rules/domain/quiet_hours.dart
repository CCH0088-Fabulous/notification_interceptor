import '../../../core/util/json_cast.dart';
import '../../../core/util/time_format.dart';

/// 静默时段。天数 1=周一 … 7=周日；跨天区间按起始日判定（与 Kotlin 侧一致）。
class QuietHours {
  const QuietHours({
    required this.fromMinutes,
    required this.toMinutes,
    required this.days,
  });

  final int fromMinutes;
  final int toMinutes;
  final Set<int> days;

  bool get isCrossMidnight => fromMinutes > toMinutes;

  String get label =>
      '${formatMinutesOfDay(fromMinutes)}–${formatMinutesOfDay(toMinutes)}';

  String get daysLabel {
    if (days.length == 7) return '每天';
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    final sorted = days.toList()..sort();
    return sorted.map((day) => '周${names[day - 1]}').join(' ');
  }

  /// 与原生 RuleEngine 相同的判定逻辑，供编辑器预览与单元测试使用。
  bool matches(int epochMillis) {
    if (days.isEmpty) return false;
    if (fromMinutes == toMinutes) return false;

    final now = DateTime.fromMillisecondsSinceEpoch(epochMillis);
    final minute = now.hour * 60 + now.minute;
    // Dart 的 weekday: 1=周一 … 7=周日，与 ISO 一致。
    if (!isCrossMidnight) {
      return minute >= fromMinutes && minute < toMinutes && days.contains(now.weekday);
    }
    final startDay = minute >= fromMinutes
        ? now.weekday
        : now.subtract(const Duration(days: 1)).weekday;
    final inWindow = minute >= fromMinutes || minute < toMinutes;
    return inWindow && days.contains(startDay);
  }

  QuietHours copyWith({
    int? fromMinutes,
    int? toMinutes,
    Set<int>? days,
  }) =>
      QuietHours(
        fromMinutes: fromMinutes ?? this.fromMinutes,
        toMinutes: toMinutes ?? this.toMinutes,
        days: days ?? this.days,
      );

  factory QuietHours.fromJson(Map<String, dynamic> json) {
    final from = parseMinutesOfDay(asStringOrNull(json['from']) ?? '') ?? 22 * 60;
    final to = parseMinutesOfDay(asStringOrNull(json['to']) ?? '') ?? 8 * 60;
    final days = (json['days'] is List)
        ? asStringList(json['days']).map(int.tryParse).whereType<int>().where((d) => d >= 1 && d <= 7).toSet()
        : <int>{1, 2, 3, 4, 5, 6, 7};
    return QuietHours(
      fromMinutes: from,
      toMinutes: to,
      days: days.isEmpty ? {1, 2, 3, 4, 5, 6, 7} : days,
    );
  }

  Map<String, dynamic> toJson() => {
        'from': formatMinutesOfDay(fromMinutes),
        'to': formatMinutesOfDay(toMinutes),
        'days': (days.toList()..sort()),
      };
}
