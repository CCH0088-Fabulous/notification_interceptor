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
  bool connectOnRebind = false;
  bool throwOnRebind = false;
  int statusCalls = 0;
  int? connectAfterStatusCalls;

  @override
  Future<AccessStatus> getStatus() async {
    statusCalls++;
    if (connectAfterStatusCalls != null && statusCalls >= connectAfterStatusCalls!) {
      status = const AccessStatus(granted: true, connected: true);
    }
    if (throwOnStatus) throw StateError('boom');
    return status;
  }

  @override
  Future<void> openAccessSettings() async => openCount++;

  @override
  Future<void> requestRebind() async {
    rebindCount++;
    if (throwOnRebind) throw StateError("system rejected");
    if (connectOnRebind) status = const AccessStatus(granted: true, connected: true);
  }
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

    test('未授权时提示设置，不发送连接请求', () async {
      final repo = _FakeAccessRepository();
      final c = AccessController(repository: repo, events: const Stream.empty());
      addTearDown(c.dispose);
      await c.requestRebind();
      expect(repo.rebindCount, 0);
      expect(c.connectionMessage, contains('授予通知使用权'));
    });
    test('等待异步连接，超时后提示重新授权', () async {
      final repo = _FakeAccessRepository(status: const AccessStatus(granted: true));
      final c = AccessController(repository: repo, events: const Stream.empty(), reconnectPollInterval: Duration.zero);
      addTearDown(c.dispose);
      final pending = c.requestRebind();
      expect(c.reconnecting, isTrue);
      await c.requestRebind();
      await pending;
      expect(repo.rebindCount, 1);
      expect(c.connectionMessage, contains('关闭后重新开启'));
      expect(c.reconnecting, isFalse);
    });
    test('已连接不重复绑定，页面销毁后不再通知', () async {
      final repo = _FakeAccessRepository(status: const AccessStatus(granted: true, connected: true));
      final c = AccessController(repository: repo, events: const Stream.empty());
      await c.requestRebind();
      expect(repo.rebindCount, 0);
      expect(c.connectionMessage, contains('已连接'));
      c.dispose();
      await c.requestRebind();
    });
    test('稍后才绑定时轮询确认成功，不提前报告成功', () async {
      final repo = _FakeAccessRepository(status: const AccessStatus(granted: true))..connectAfterStatusCalls = 3;
      final c = AccessController(repository: repo, events: const Stream.empty(), reconnectPollInterval: Duration.zero);
      addTearDown(c.dispose);
      await c.requestRebind();
      expect(repo.statusCalls, 3);
      expect(c.status.isReady, isTrue);
      expect(c.connectionMessage, '监听服务已连接。');
    });
    test('系统拒绝连接时呈现失败而不是静默成功', () async {
      final repo = _FakeAccessRepository(status: const AccessStatus(granted: true))..throwOnRebind = true;
      final c = AccessController(repository: repo, events: const Stream.empty());
      addTearDown(c.dispose);
      await c.requestRebind();
      expect(c.error, contains('system rejected'));
      expect(c.connectionMessage, contains('失败'));
      expect(c.reconnecting, isFalse);
    });
    test('等待状态时销毁不再请求连接或通知界面', () async {
      final repo = _FakeAccessRepository(status: const AccessStatus(granted: true));
      final c = AccessController(repository: repo, events: const Stream.empty());
      final pending = c.requestRebind();
      c.dispose();
      await pending;
      expect(repo.rebindCount, 0);
    });
    test('超时后系统连接事件会清除旧失败提示', () async {
      final events = StreamController<Map<String, dynamic>>.broadcast();
      final repo = _FakeAccessRepository(status: const AccessStatus(granted: true));
      final c = AccessController(repository: repo, events: events.stream, reconnectPollInterval: Duration.zero);
      addTearDown(() async { c.dispose(); await events.close(); });
      await c.requestRebind();
      expect(c.connectionMessage, contains('暂未连接'));
      events.add({'type': BridgeEventType.statusChanged, 'connected': true, 'granted': true});
      await Future<void>.delayed(Duration.zero);
      expect(c.connectionMessage, '监听服务已连接。');
      expect(c.status.isReady, isTrue);
    });
    test('之后断开或撤销权限时不会继续显示已连接提示', () async {
      final repo = _FakeAccessRepository(status: const AccessStatus(granted: true, connected: true));
      final c = AccessController(repository: repo, events: const Stream.empty());
      addTearDown(c.dispose);
      await c.requestRebind();
      repo.status = const AccessStatus(granted: true);
      await c.refresh();
      expect(c.connectionMessage, contains('已断开'));
      repo.status = const AccessStatus();
      await c.refresh();
      expect(c.connectionMessage, contains('重新授权'));
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
      final repository = _FakeAccessRepository(status: const AccessStatus(granted: true))..connectOnRebind = true;
      final controller = AccessController(repository: repository, events: const Stream.empty(), reconnectPollInterval: Duration.zero);
      addTearDown(controller.dispose);

      await controller.openSettings();
      await controller.requestRebind();

      expect(repository.openCount, 1);
      expect(repository.rebindCount, 1);
    });
  });
}
