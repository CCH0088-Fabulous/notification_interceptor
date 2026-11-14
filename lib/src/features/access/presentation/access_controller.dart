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
    Duration reconnectPollInterval = const Duration(milliseconds: 500),
  })  : _repository = repository,
        _events = events,
        _reconnectPollInterval = reconnectPollInterval {
    _subscription = _events.listen(_onEvent);
  }

  final AccessRepository _repository;
  final Stream<Map<String, dynamic>> _events;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  final Duration _reconnectPollInterval;
  bool _disposed = false;
  bool _reconnecting = false;
  String? _connectionMessage;
  bool get reconnecting => _reconnecting;
  String? get connectionMessage => _connectionMessage;

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
      _updateConnectionMessage();
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
    if (_reconnecting || _disposed) return;
    _reconnecting = true;
    _error = null;
    _connectionMessage = '正在请求系统连接监听服务…';
    notifyListeners();
    try {
      _status = await _repository.getStatus();
      if (_disposed) return;
      if (!_status.granted) {
        _connectionMessage = '请先打开系统设置，授予通知使用权。';
        return;
      }
      if (_status.isReady) {
        _connectionMessage = '监听服务已连接，无需重复连接。';
        return;
      }
      await _repository.requestRebind();
      for (var attempt = 0; attempt < 10; attempt++) {
        await Future<void>.delayed(_reconnectPollInterval);
        if (_disposed) return;
        _status = await _repository.getStatus();
        if (_status.isReady) {
          _connectionMessage = '监听服务已连接。';
          return;
        }
        if (!_status.granted) {
          _connectionMessage = '通知使用权已关闭，请在系统设置中重新授权。';
          return;
        }
      }
      _connectionMessage = '系统暂未连接。请打开系统设置，将本应用的通知使用权关闭后重新开启，再返回此页。';
    } catch (error) {
      _error = error.toString();
      _connectionMessage = '连接请求失败，请打开系统设置重新开启通知使用权。';
    } finally {
      _reconnecting = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _onEvent(Map<String, dynamic> event) {
    if (event['type'] != BridgeEventType.statusChanged) return;
    _status = _status.copyWith(
      connected: asBool(event['connected']),
      granted: asBool(event['granted'], fallback: _status.granted),
    );
    _updateConnectionMessage();
    notifyListeners();
  }

  void _updateConnectionMessage() {
    if (_connectionMessage == null) return;
    if (_status.isReady) {
      _connectionMessage = '监听服务已连接。';
      _error = null;
    } else if (!_status.granted) {
      _connectionMessage = '通知使用权已关闭，请在系统设置中重新授权。';
    } else if (!_reconnecting && _connectionMessage!.startsWith('监听服务已连接')) {
      _connectionMessage = '监听服务已断开，请重新连接。';
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    super.dispose();
  }
}
