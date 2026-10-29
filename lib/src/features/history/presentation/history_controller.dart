import 'package:flutter/foundation.dart';

import '../../../shared/domain/rule_action.dart';
import '../domain/history_entry.dart';
import '../domain/history_overview.dart';
import '../domain/history_query.dart';
import '../domain/history_repository.dart';

/// 一次读取本地完整窗口，列表检索与日期统计分开，避免取前100条后漏搜。
class HistoryController extends ChangeNotifier {
  HistoryController({
    required HistoryRepository repository,
    DateTime Function()? now,
  }) : _repository = repository,
       _now = now ?? DateTime.now;

  final HistoryRepository _repository;
  final DateTime Function() _now;
  HistoryQuery _query = const HistoryQuery();
  List<HistoryEntry> _allEntries = const [];
  HistoryStats _stats = const HistoryStats();
  HistoryPeriod _period = HistoryPeriod.today;
  String _search = '';
  HistoryRuleKey? _ruleFilter;
  bool _loading = false;
  String? _error;
  int _revision = 0;

  HistoryQuery get query => _query;
  List<HistoryEntry> get allEntries => List.unmodifiable(_allEntries);
  HistoryStats get stats => _stats; // 设置页保留原始数量（包含系统汇总）。
  HistoryPeriod get period => _period;
  String get search => _search;
  HistoryRuleKey? get ruleFilter => _ruleFilter;
  bool get loading => _loading;
  String? get error => _error;

  List<HistoryEntry> get periodEntries {
    final since = _period.since(_now());
    return _allEntries
        .where(
          (entry) =>
              !entry.record.isGroupSummary &&
              (since == null || entry.timestamp >= since),
        )
        .toList(growable: false);
  }

  HistoryOverview get overview => HistoryOverview(periodEntries);

  List<HistoryEntry> get entries {
    final needle = _search.toLowerCase();
    return periodEntries
        .where((entry) {
          if (_query.action != null && entry.action != _query.action) {
            return false;
          }
          if (_query.packageName != null &&
              entry.record.packageName != _query.packageName) {
            return false;
          }
          if (_ruleFilter != null && historyRuleKey(entry) != _ruleFilter) {
            return false;
          }
          return needle.isEmpty ||
              [
                entry.record.displayTitle,
                entry.record.displayBody,
                entry.record.searchableText,
                entry.record.displayApp,
                entry.record.packageName,
                entry.matchedRuleName ?? '',
              ].join('\n').toLowerCase().contains(needle);
        })
        .toList(growable: false);
  }

  Map<String, String> get applications {
    final result = <String, String>{};
    for (final entry in periodEntries) {
      result.putIfAbsent(
        entry.record.packageName,
        () => entry.record.displayApp,
      );
    }
    return result;
  }

  Future<void> load() async {
    final revision = ++_revision;
    _loading = true;
    notifyListeners();
    try {
      final entries = await _repository.query(const HistoryQuery(limit: 1000));
      final stats = await _repository.stats();
      if (revision != _revision) return;
      _allEntries = [...entries]
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
      _stats = stats;
      _error = null;
    } catch (error) {
      if (revision == _revision) _error = error.toString();
    } finally {
      if (revision == _revision) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> setActionFilter(RuleAction? action) async {
    _query = _query.copyWith(action: action);
    notifyListeners();
  }

  Future<void> setPackageFilter(String? packageName) async {
    _query = _query.copyWith(
      packageName: (packageName?.trim().isEmpty ?? true)
          ? null
          : packageName!.trim(),
    );
    notifyListeners();
  }

  void setSearch(String text) {
    _search = text.trim();
    notifyListeners();
  }

  void setPeriod(HistoryPeriod period) {
    _period = period;
    notifyListeners();
  }

  void setRuleFilter(HistoryRuleKey? key) {
    _ruleFilter = key;
    notifyListeners();
  }

  void resetFilters() {
    _query = const HistoryQuery();
    _search = '';
    _ruleFilter = null;
    notifyListeners();
  }

  Future<void> clear() async {
    final revision = ++_revision; // 旧查询的回包不可让已清空的内容重新出现。
    _loading = true;
    notifyListeners();
    try {
      await _repository.clear();
      if (revision != _revision) return;
      _allEntries = const [];
      _stats = const HistoryStats();
      _query = const HistoryQuery();
      _search = '';
      _ruleFilter = null;
      _period = HistoryPeriod.today;
      _error = null;
    } catch (error) {
      if (revision == _revision) _error = error.toString();
    } finally {
      if (revision == _revision) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<String> exportJson() => _repository.exportJson();

  @override
  void dispose() {
    _revision++;
    super.dispose();
  }
}
