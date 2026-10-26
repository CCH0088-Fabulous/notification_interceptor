import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/core/util/time_format.dart';

void main() {
  group('time_format', () {
    test('formatClock 补零并处理非法时间', () {
      final millis = DateTime(2026, 10, 17, 9, 5, 3).millisecondsSinceEpoch;
      expect(formatClock(millis), '09:05:03');
      expect(formatClock(0), '--:--:--');
    });

    test('formatRelative 输出人类可读相对时间', () {
      final now = DateTime(2026, 10, 17, 12, 0, 0);
      expect(formatRelative(now.millisecondsSinceEpoch - 1000, now: now), '刚刚');
      expect(formatRelative(now.millisecondsSinceEpoch - 30 * 1000, now: now), '30 秒前');
      expect(formatRelative(now.millisecondsSinceEpoch - 5 * 60 * 1000, now: now), '5 分钟前');
      expect(formatRelative(now.millisecondsSinceEpoch - 3 * 3600 * 1000, now: now), '3 小时前');
      expect(formatRelative(now.millisecondsSinceEpoch - 2 * 86400 * 1000, now: now), '2 天前');
    });

    test('分钟数解析与格式化互为逆运算', () {
      expect(formatMinutesOfDay(22 * 60), '22:00');
      expect(formatMinutesOfDay(8 * 60 + 5), '08:05');
      expect(parseMinutesOfDay('22:00'), 22 * 60);
      expect(parseMinutesOfDay('08:05'), 8 * 60 + 5);
      expect(parseMinutesOfDay('24:00'), isNull);
      expect(parseMinutesOfDay('12:60'), isNull);
      expect(parseMinutesOfDay('abc'), isNull);
    });
  });
}
