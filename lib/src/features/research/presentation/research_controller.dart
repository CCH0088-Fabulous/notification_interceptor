import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../shared/domain/usage_recorder.dart';
import '../domain/research_repository.dart';
import '../domain/research_status.dart';

class ResearchController extends ChangeNotifier implements UsageRecorder {
  ResearchController({required ResearchRepository repository})
    : _repository = repository;
  final ResearchRepository _repository;
  ResearchStatus? _status;
  bool _busy = false;
  bool _disposed = false;
  String? _error;
  ResearchStatus? get status => _status;
  bool get busy => _busy;
  String? get error => _error;

  Future<void> load() async {
    if (_busy) return;
    _busy = true;
    _error = null;
    _changed();
    try {
      _status = await _repository.status();
    } catch (error) {
      _error = error.toString();
    } finally {
      _busy = false;
      _changed();
    }
  }

  Future<void> configure(Map<String, dynamic> changes) => _run(() async {
    final current = _status;
    if (current == null) throw StateError('请先读取研究设置');
    _status = await _repository.configure({
      ...changes,
      'expectedRevision': current.configuration.revision,
    });
  });

  Future<String?> preview() => _run(_repository.preview);
  Future<void> enroll() => _run(() async {
    final current = _status;
    if (current == null || !current.configuration.enabled) {
      throw StateError('请先同意参与使用研究');
    }
    _status = await _repository.enroll(current.configuration.revision);
  });
  Future<bool> exportFile() => _fileAction(_repository.exportFile);
  Future<bool> shareFile() => _fileAction(_repository.shareFile);
  Future<bool> _fileAction(Future<bool> Function() action) => _run(() async {
    final result = await action();
    try {
      _status = await _repository.status();
    } catch (_) {
      _error = '文件操作已返回，状态暂时无法刷新';
    }
    return result;
  });
  Future<void> end() => _run(() async {
    final current = _status;
    if (current == null) throw StateError('请先读取内测数据');
    _status = await _repository.end(current.configuration.revision);
  });
  Future<void> clear() => _run(() async {
    _status = await _repository.clear();
  });
  Future<String> sync() => _run(() async {
    final result = await _repository.sync();
    // A refresh failure must not misrepresent an acknowledged upload as failed.
    try {
      _status = await _repository.status();
    } catch (_) {
      _error = '发送结果已返回，状态暂时无法刷新';
    }
    return result['message'] as String;
  });

  @override
  void record(UsageAction action) {
    if (_disposed || _status?.configuration.enabled != true) return;
    unawaited(_repository.record(action).catchError((Object _) {}));
  }

  Future<T> _run<T>(Future<T> Function() operation) async {
    if (_busy) throw StateError('请等待当前研究操作完成');
    _busy = true;
    _error = null;
    _changed();
    try {
      return await operation();
    } catch (error) {
      _error = error.toString();
      rethrow;
    } finally {
      _busy = false;
      _changed();
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
