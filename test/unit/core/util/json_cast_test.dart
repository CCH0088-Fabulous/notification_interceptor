import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/core/util/json_cast.dart';

void main() {
  group('json_cast', () {
    test('asStringMap 把任意 Map 的 key 转成字符串', () {
      final result = asStringMap({1: 'a', 'b': 2});
      expect(result, {'1': 'a', 'b': 2});
      expect(asStringMap(null), isEmpty);
      expect(asStringMap('not a map'), isEmpty);
    });

    test('asStringMapList 过滤掉非 Map 元素', () {
      final result = asStringMapList([
        {'a': 1},
        'x',
        {2: 'b'},
      ]);
      expect(result, hasLength(2));
      expect(result.first['a'], 1);
      expect(result.last['2'], 'b');
    });

    test('数值与布尔解析带默认值', () {
      expect(asInt(3.9), 3);
      expect(asInt('3', fallback: 7), 7);
      expect(asInt(null, fallback: -1), -1);
      expect(asBool(true), isTrue);
      expect(asBool('true', fallback: false), isFalse);
      expect(asStringOrNull(null), isNull);
      expect(asStringList(['a', 1]), ['a', '1']);
    });
  });
}
