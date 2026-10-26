import '../../../core/channel/interceptor_channel.dart';
import '../../../core/util/json_cast.dart';
import '../../../shared/domain/rule_action.dart';
import '../domain/history_entry.dart';
import '../domain/history_query.dart';
import '../domain/history_repository.dart';

class NativeHistoryRepository implements HistoryRepository {
  NativeHistoryRepository(this._channel);

  final InterceptorChannel _channel;

  @override
  Future<List<HistoryEntry>> query(HistoryQuery query) async {
    final result = await _channel.invoke<List<dynamic>>(
      BridgeMethod.getHistory,
      query.toArguments(),
    );
    return asStringMapList(result).map(HistoryEntry.fromJson).toList();
  }

  @override
  Future<void> clear() async {
    await _channel.invoke<bool>(BridgeMethod.clearHistory);
  }

  @override
  Future<HistoryStats> stats() async {
    final result = asStringMap(
      await _channel.invoke<Map<dynamic, dynamic>>(BridgeMethod.getStats),
    );
    final byAction = <RuleAction, int>{};
    asStringMap(result['byAction']).forEach((key, value) {
      byAction[RuleAction.fromWire(key)] = asInt(value);
    });
    final topPackages = <MapEntry<String, int>>[];
    asStringMap(result['topPackages']).forEach((key, value) {
      topPackages.add(MapEntry(key, asInt(value)));
    });
    topPackages.sort((a, b) => b.value.compareTo(a.value));
    return HistoryStats(
      total: asInt(result['total']),
      byAction: byAction,
      topPackages: topPackages,
    );
  }

  @override
  Future<String> exportJson() async {
    return await _channel.invoke<String>(BridgeMethod.exportHistory) ?? '[]';
  }
}
