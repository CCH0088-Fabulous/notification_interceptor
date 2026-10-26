/// 平台通道只在标准编解码器支持下往返，这里统一把 `Map<Object?, Object?>`
/// 递归转换为 `Map<String, dynamic>`，避免每个仓储各写一遍。
Map<String, dynamic> asStringMap(Object? value) {
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return <String, dynamic>{};
}

List<Map<String, dynamic>> asStringMapList(Object? value) {
  if (value is List) {
    return value.whereType<Map>().map(asStringMap).toList(growable: false);
  }
  return const <Map<String, dynamic>>[];
}

List<String> asStringList(Object? value) {
  if (value is List) {
    return value.map((item) => item.toString()).toList(growable: false);
  }
  return const <String>[];
}

String? asStringOrNull(Object? value) => value?.toString();

int asInt(Object? value, {int fallback = 0}) =>
    value is num ? value.toInt() : fallback;

bool asBool(Object? value, {bool fallback = false}) =>
    value is bool ? value : fallback;
