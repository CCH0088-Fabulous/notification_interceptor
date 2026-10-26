import '../../../shared/domain/rule_action.dart';

/// 历史检索条件。全部为空时等价于"最新 N 条"。
class HistoryQuery {
  const HistoryQuery({
    this.limit = 100,
    this.offset = 0,
    this.packageName,
    this.action,
    this.since,
  });

  final int limit;
  final int offset;
  final String? packageName;
  final RuleAction? action;
  final int? since;

  HistoryQuery copyWith({
    int? limit,
    int? offset,
    Object? packageName = _unset,
    Object? action = _unset,
    int? since,
  }) =>
      HistoryQuery(
        limit: limit ?? this.limit,
        offset: offset ?? this.offset,
        packageName:
            identical(packageName, _unset) ? this.packageName : packageName as String?,
        action: identical(action, _unset) ? this.action : action as RuleAction?,
        since: since ?? this.since,
      );

  Map<String, dynamic> toArguments() => {
        'limit': limit,
        'offset': offset,
        if (packageName != null && packageName!.isNotEmpty) 'packageName': packageName,
        if (action != null) 'action': action!.wire,
        if (since != null) 'since': since,
      };
}

const Object _unset = Object();

/// 统计信息，设置页与历史页顶部展示。
class HistoryStats {
  const HistoryStats({
    this.total = 0,
    this.byAction = const {},
    this.topPackages = const [],
  });

  final int total;
  final Map<RuleAction, int> byAction;
  final List<MapEntry<String, int>> topPackages;
}
