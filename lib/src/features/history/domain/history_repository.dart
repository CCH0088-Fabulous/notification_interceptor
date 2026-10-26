import 'history_entry.dart';
import 'history_query.dart';

abstract interface class HistoryRepository {
  Future<List<HistoryEntry>> query(HistoryQuery query);

  Future<void> clear();

  Future<HistoryStats> stats();

  Future<String> exportJson();
}
