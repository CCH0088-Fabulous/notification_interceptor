import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/channel/interceptor_channel.dart';
import '../../../shared/domain/decision.dart';
import '../domain/feed_item.dart';
import '../domain/notification_event.dart';
import '../domain/feed_repository.dart';
import '../domain/notification_record.dart';

/// 实时通知流。只保留最近 [maxItems] 条，避免长时间运行内存增长。
class FeedController extends ChangeNotifier {
  FeedController({
    required FeedRepository repository,
    required Stream<Map<String, dynamic>> events,
  }) : _repository = repository {
    _subscription = events.listen(_onEvent, onError: _onStreamError);
  }

  static const int maxItems = 200;

  final FeedRepository _repository;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  final List<FeedItem> _items = [];
  bool _loading = false;
  String? _error;

  List<FeedItem> get items => List.unmodifiable(_items);
  bool get loading => _loading;
  String? get error => _error;
  int get interceptCount =>
      _items.where((item) => item.decision?.shouldIntercept ?? false).length;

  Future<void> refreshActive() async {
    _loading = true;
    notifyListeners();
    try {
      final records = await _repository.activeNotifications();
      for (final record in records) {
        _insert(FeedItem(record: record, existing: true));
      }
      _error = null;
    } catch (error) {
      _error = error.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<bool> cancel(NotificationRecord record) async {
    try {
      final cancelled = await _repository.cancel(record.key);
      if (cancelled) {
        _markRemoved(record.key);
      }
      return cancelled;
    } catch (error) {
      _error = error.toString();
      notifyListeners();
      return false;
    }
  }

  void clearList() {
    _items.clear();
    notifyListeners();
  }

  /// 供规则试运行使用：取当前活动通知作为样例。
  Future<List<NotificationRecord>> loadSamples() =>
      _repository.activeNotifications();

  void _onEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case BridgeEventType.posted:
        final parsed = NotificationEvent.fromJson(event);
        final record = parsed.record;
        if (record == null ||
            record.key.isEmpty ||
            record.packageName.isEmpty) {
          return;
        }
        _insert(
          FeedItem(
            record: record,
            decision: parsed.decision ?? const Decision(reason: 'unknown'),
            existing: parsed.existing,
          ),
        );
        _error = null;
        notifyListeners();
      case BridgeEventType.removed:
        final key = event['key']?.toString();
        if (key == null) return;
        _markRemoved(key);
        notifyListeners();
      default:
        return;
    }
  }

  void _insert(FeedItem item) {
    final index = _items.indexWhere(
      (existing) => existing.record.key == item.record.key,
    );
    // 存量快照不覆盖已经带判定结果的实时记录。
    if (index >= 0 && item.decision == null && _items[index].decision != null) {
      return;
    }
    _items.removeWhere((existing) => existing.record.key == item.record.key);
    _items.insert(0, item);
    if (_items.length > maxItems) {
      _items.removeRange(maxItems, _items.length);
    }
  }

  void _markRemoved(String key) {
    final index = _items.indexWhere((item) => item.record.key == key);
    if (index >= 0) {
      _items[index] = _items[index].copyWith(removed: true);
    }
  }

  void _onStreamError(Object error) {
    _error = error.toString();
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
