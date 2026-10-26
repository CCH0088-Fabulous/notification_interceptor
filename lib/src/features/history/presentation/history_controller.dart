import 'package:flutter/foundation.dart';

import '../../../shared/domain/rule_action.dart';
import '../domain/history_entry.dart';
import '../domain/history_query.dart';
import '../domain/history_repository.dart';

/// 历史检索：筛选条件变化即重新查询，数据量上限由原生侧保证（1000 条）。
class HistoryController extends ChangeNotifier {
  HistoryController({required HistoryRepository repository}) : _repository = repository;

  final HistoryRepository _repository;

  HistoryQuery _query = const HistoryQuery();
  List<HistoryEntry> _entries = const [];
  HistoryStats _stats = const HistoryStats();
  bool _loading = false;
  String? _error;

  HistoryQuery get query => _query;
  List<HistoryEntry> get entries => _entries;
  HistoryStats get stats => _stats;
  bool get loading => _loading;
  String? get error => _error;

  Future<void> load() async {
    _loading = true;
    notifyListeners();
    try {
      _entries = await _repository.query(_query);
      _stats = await _repository.stats();
      _error = null;
    } catch (error) {
      _error = error.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> setActionFilter(RuleAction? action) {
    _query = _query.copyWith(action: action);
    return load();
  }

  Future<void> setPackageFilter(String? packageName) {
    _query = _query.copyWith(
      packageName: (packageName?.trim().isEmpty ?? true) ? null : packageName!.trim(),
    );
    return load();
  }

  Future<void> clear() async {
    try {
      await _repository.clear();
      _entries = const [];
      _stats = const HistoryStats();
      _error = null;
    } catch (error) {
      _error = error.toString();
    }
    notifyListeners();
  }

  Future<String> exportJson() => _repository.exportJson();
}
