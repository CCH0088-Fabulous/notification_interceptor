import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/core/channel/interceptor_channel.dart';
import 'package:notifinterceptor/src/features/access/domain/access_repository.dart';
import 'package:notifinterceptor/src/features/access/domain/access_status.dart';
import 'package:notifinterceptor/src/features/access/presentation/access_controller.dart';

class _FakeAccessRepository implements AccessRepository {
  _FakeAccessRepository({this.status = const AccessStatus(), this.throwOnStatus = false});

  AccessStatus status;
  bool throwOnStatus;
  int openCount = 0;
  int rebindCount = 0;

  @override
  Future<AccessStatus> getStatus() async {
    if (throwOnStatus) throw StateError('boom');
    return status;
  }

  @override
  Future<void> openAccessSettings() async => openCount++;

  @override
  Future<void> requestRebind() async => rebindCount++;
}

void main() {
  group('AccessController', () {
    test('refresh 后暴露权限与服务状态', () async {
      final controller = AccessController(
        repository: _FakeAccessRepository(
          status: const AccessStatus(granted: true, connected: true, sdkInt: 36),
        ),
        events: const Stream.empty(),
      );
      addTearDown(controller.dispose);

      await controller.refresh();

      expect(controller.status.isReady, isTrue);
      expect(controller.status.sdkInt, 36);
      expect(controller.loading, isFalse);
      expect(controller.error, isNull);
    });

    test('已授权但未连接时 isReady 为 false', () async {
      final controller = AccessController(
        repository: _FakeAccessRepository(
          status: const AccessStatus(granted: true, connected: false),
        ),
        events: const Stream.empty(),
      );
      addTearDown(controller.dispose);

      await controller.refresh();

      expect(controller.status.granted, isTrue);
      expect(controller.status.isReady, isFalse);
    });

    test('statusChanged 事件更新连接状态', () async {
      final events = StreamController<Map<String, dynamic>>.broadcast();
      final controller = AccessController(
        repository: _FakeAccessRepository(),
        events: events.stream,
      );
      addTearDown(() async {
        controller.dispose();
        await events.close();
      });

      events.add({
        'type': BridgeEventType.statusChanged,
        'connected': true,
        'granted': true,
      });
      await Future<void>.delayed(Duration.zero);

      expect(controller.status.isReady, isTrue);
    });

    test('其它事件类型被忽略', () async {
      final events = StreamController<Map<String, dynamic>>.broadcast();
      final controller = AccessController(
        repository: _FakeAccessRepository(),
        events: events.stream,
      );
      addTearDown(() async {
        controller.dispose();
        await events.close();
      });

      events.add({'type': BridgeEventType.posted});
      await Future<void>.delayed(Duration.zero);

      expect(controller.status.isReady, isFalse);
    });

    test('getStatus 抛错时记录 error 且不崩溃', () async {
      final controller = AccessController(
        repository: _FakeAccessRepository(throwOnStatus: true),
        events: const Stream.empty(),
      );
      addTearDown(controller.dispose);

      await controller.refresh();

      expect(controller.error, contains('boom'));
      expect(controller.loading, isFalse);
    });

    test('openSettings 与 requestRebind 转发到仓储', () async {
      final repository = _FakeAccessRepository();
      final controller = AccessController(repository: repository, events: const Stream.empty());
      addTearDown(controller.dispose);

      await controller.openSettings();
      await controller.requestRebind();

      expect(repository.openCount, 1);
      expect(repository.rebindCount, 1);
    });
  });
}
