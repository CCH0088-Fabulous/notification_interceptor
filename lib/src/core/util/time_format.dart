/// 时间格式化：历史列表用绝对时间，实时流用相对时间。
String formatClock(int epochMillis) {
  if (epochMillis <= 0) return '--:--:--';
  final time = DateTime.fromMillisecondsSinceEpoch(epochMillis);
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  final second = time.second.toString().padLeft(2, '0');
  return '$hour:$minute:$second';
}

String formatRelative(int epochMillis, {DateTime? now}) {
  if (epochMillis <= 0) return '未知时间';
  final current = now ?? DateTime.now();
  final diff = current.difference(DateTime.fromMillisecondsSinceEpoch(epochMillis));
  if (diff.inSeconds < 5) return '刚刚';
  if (diff.inSeconds < 60) return '${diff.inSeconds} 秒前';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  return '${diff.inDays} 天前';
}

/// 分钟数 → HH:mm，rules 编辑器与原生 QuietHours 使用同一表示。
String formatMinutesOfDay(int minutes) {
  final hour = (minutes ~/ 60).toString().padLeft(2, '0');
  final minute = (minutes % 60).toString().padLeft(2, '0');
  return '$hour:$minute';
}

/// HH:mm → 分钟数，非法输入返回 null。
int? parseMinutesOfDay(String value) {
  final parts = value.trim().split(':');
  if (parts.length != 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return hour * 60 + minute;
}
