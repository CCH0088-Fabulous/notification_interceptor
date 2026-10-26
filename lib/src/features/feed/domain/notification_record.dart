import '../../../core/util/json_cast.dart';

/// 通知快照的 Dart 镜像。字段名与 Kotlin `NotificationSnapshot` 严格一致。
class NotificationRecord {
  const NotificationRecord({
    required this.key,
    required this.id,
    required this.packageName,
    this.appLabel,
    required this.postTime,
    this.title,
    this.text,
    this.bigText,
    this.textLines = const [],
    this.subText,
    this.tickerText,
    this.category,
    this.channelId,
    this.channelName,
    this.groupKey,
    this.isGroupSummary = false,
    this.isOngoing = false,
    this.isClearable = true,
    this.priority = 0,
    this.progress = -1,
    this.extras = const {},
  });

  final String key;
  final int id;
  final String packageName;
  final String? appLabel;
  final int postTime;
  final String? title;
  final String? text;
  final String? bigText;
  final List<String> textLines;
  final String? subText;
  final String? tickerText;
  final String? category;
  final String? channelId;
  final String? channelName;
  final String? groupKey;
  final bool isGroupSummary;
  final bool isOngoing;
  final bool isClearable;
  final int priority;
  final int progress;
  final Map<String, String> extras;

  String get displayTitle {
    if (title != null && title!.trim().isNotEmpty) return title!;
    if (appLabel != null && appLabel!.isNotEmpty) return appLabel!;
    return packageName;
  }

  String get displayBody {
    if (text != null && text!.trim().isNotEmpty) return text!;
    if (bigText != null && bigText!.trim().isNotEmpty) return bigText!;
    if (textLines.isNotEmpty) return textLines.join(' / ');
    return '（无正文）';
  }

  String get displayApp =>
      (appLabel != null && appLabel!.isNotEmpty) ? appLabel! : packageName;

  /// 与 Kotlin `NotificationSnapshot.searchableText` 保持同样的顺序。
  String get searchableText => [
        title ?? '',
        text ?? '',
        bigText ?? '',
        subText ?? '',
        ...textLines,
      ].join('\n');

  factory NotificationRecord.fromJson(Map<String, dynamic> json) {
    final rawExtras = json['extras'];
    final extras = <String, String>{};
    if (rawExtras is Map) {
      rawExtras.forEach((key, value) => extras[key.toString()] = value.toString());
    }
    return NotificationRecord(
      key: asStringOrNull(json['key']) ?? '',
      id: asInt(json['id']),
      packageName: asStringOrNull(json['packageName']) ?? '',
      appLabel: asStringOrNull(json['appLabel']),
      postTime: asInt(json['postTime']),
      title: asStringOrNull(json['title']),
      text: asStringOrNull(json['text']),
      bigText: asStringOrNull(json['bigText']),
      textLines: asStringList(json['textLines']),
      subText: asStringOrNull(json['subText']),
      tickerText: asStringOrNull(json['tickerText']),
      category: asStringOrNull(json['category']),
      channelId: asStringOrNull(json['channelId']),
      channelName: asStringOrNull(json['channelName']),
      groupKey: asStringOrNull(json['groupKey']),
      isGroupSummary: asBool(json['isGroupSummary']),
      isOngoing: asBool(json['isOngoing']),
      isClearable: asBool(json['isClearable'], fallback: true),
      priority: asInt(json['priority']),
      progress: asInt(json['progress'], fallback: -1),
      extras: extras,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'id': id,
        'packageName': packageName,
        'appLabel': appLabel,
        'postTime': postTime,
        'title': title,
        'text': text,
        'bigText': bigText,
        'textLines': textLines,
        'subText': subText,
        'tickerText': tickerText,
        'category': category,
        'channelId': channelId,
        'channelName': channelName,
        'groupKey': groupKey,
        'isGroupSummary': isGroupSummary,
        'isOngoing': isOngoing,
        'isClearable': isClearable,
        'priority': priority,
        'progress': progress,
        'extras': extras,
      };
}
