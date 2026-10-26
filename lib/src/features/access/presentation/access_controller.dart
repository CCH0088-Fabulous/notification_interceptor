import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/channel/interceptor_channel.dart';
import '../../../core/util/json_cast.dart';
import '../domain/access_repository.dart';
import '../domain/access_status.dart';

/// 通知使用权状态。状态变化同时来自主动刷新与原生 statusChanged 事件。
class AccessController extends ChangeNotifier {
  AccessController({
    required AccessRepository repository,
    required Stream<Map<String, dynamic>> events,
  })  : _repository = repository,
        _events = events {
    _subscription = _events.listen(_onEvent);
  }

  final AccessRepository _repository;
  final Stream<Map<String, dynamic>> _events;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  AccessStatus _status = const AccessStatus();
  bool _loading = false;
  String? _error;

  AccessStatus get status => _status;
  bool get loading => _loading;
  String? get error => _error;

  Future<void> refresh() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _status = await _repository.getStatus();
    } catch (error) {
      _error = error.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> openSettings() async {
    try {
      await _repository.openAccessSettings();
    } catch (error) {
      _error = error.toString();
      notifyListeners();
    }
  }

  Future<void> requestRebind() async {
    try {
      await _repository.requestRebind();
      await refresh();
    } catch (error) {
      _error = error.toString();
      notifyListeners();
    }
  }

  void _onEvent(Map<String, dynamic> event) {
    if (event['type'] != BridgeEventType.statusChanged) return;
    _status = _status.copyWith(
      connected: asBool(event['connected']),
      granted: asBool(event['granted'], fallback: _status.granted),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
