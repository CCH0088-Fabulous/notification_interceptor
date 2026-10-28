import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/core/channel/interceptor_channel.dart';
import 'package:notifinterceptor/src/features/feed/domain/feed_repository.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_event.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_record.dart';
import 'package:notifinterceptor/src/features/feed/presentation/feed_controller.dart';
import 'package:notifinterceptor/src/shared/domain/rule_action.dart';

class _FakeFeedRepository implements FeedRepository {
  _FakeFeedRepository({this.cancelResult = true});

  final bool cancelResult;
  final List<String> cancelledKeys = [];

  @override
  Future<List<NotificationRecord>> activeNotifications() async => const [];

  @override
  Future<bool> cancel(String key) async {
    cancelledKeys.add(key);
    return cancelResult;
  }

  @override
  Stream<NotificationEvent> watch() => const Stream<NotificationEvent>.empty();
}

NotificationRecord record(String key, {String packageName = 'com.demo'}) =>
    NotificationRecord(
      key: key,
      id: 1,
      packageName: packageName,
      appLabel: 'Demo',
      postTime: 1760000000000,
      title: '标题 $key',
    );

Map<String, dynamic> postedEvent(
  NotificationRecord record, {
  String action = 'allow',
}) => {
  'type': BridgeEventType.posted,
  'record': {
    'id': 'history-${record.key}',
    'timestamp': record.postTime,
    'snapshot': record.toJson(),
    'action': action,
  },
  'decision': {
    'action': action,
    'reason': 'rule',
    'ruleId': 'r1',
    'ruleName': '规则',
  },
};

void main() {
  group('FeedController', () {
    late StreamController<Map<String, dynamic>> events;
    late _FakeFeedRepository repository;
    late FeedController controller;

    setUp(() {
      events = StreamController<Map<String, dynamic>>.broadcast();
      repository = _FakeFeedRepository();
      controller = FeedController(
        repository: repository,
        events: events.stream,
      );
    });

    tearDown(() async {
      controller.dispose();
      await events.close();
    });

    test('posted 事件按时间倒序插入并携带判定结果', () async {
      events.add(postedEvent(record('a'), action: 'intercept'));
      await Future<void>.delayed(Duration.zero);
      events.add(postedEvent(record('b')));
      await Future<void>.delayed(Duration.zero);

      expect(controller.items.map((item) => item.record.key), ['b', 'a']);
      expect(controller.items.last.decision?.action, RuleAction.intercept);
      expect(controller.interceptCount, 1);
      expect(controller.items.first.record.title, '标题 b');
      expect(controller.items.first.record.packageName, 'com.demo');
      expect(controller.items.first.record.appLabel, 'Demo');
      expect(controller.items.first.record.postTime, 1760000000000);
    });

    test('真实原生事件保留正文，取消操作使用快照中的 key', () async {
      const snapshot = NotificationRecord(
        key: 'native-key',
        id: 42,
        packageName: 'dev.poc.notifgen',
        appLabel: '通知生成器',
        postTime: 1760000000000,
        title: '项目讨论',
        text: '明天下午三点开会',
      );
      events.add(postedEvent(snapshot, action: 'intercept'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.items.single.record.text, '明天下午三点开会');
      expect(controller.items.single.record.id, 42);
      await controller.cancel(controller.items.single.record);
      expect(repository.cancelledKeys, ['native-key']);
    });

    test('兼容平铺快照，忽略缺少通知身份的错误事件', () async {
      events.add({
        ...postedEvent(record('flat')),
        'record': record('flat').toJson(),
      });
      events.add({
        'type': BridgeEventType.posted,
        'record': {'id': 'history-only'},
      });
      await Future<void>.delayed(Duration.zero);
      expect(controller.items.single.record.key, 'flat');
    });

    test('同一 key 的通知更新不会重复插入', () async {
      events.add(postedEvent(record('a')));
      await Future<void>.delayed(Duration.zero);
      events.add(postedEvent(record('a')));
      await Future<void>.delayed(Duration.zero);

      expect(controller.items, hasLength(1));
    });

    test('removed 事件把对应项标记为已移除', () async {
      events.add(postedEvent(record('a')));
      await Future<void>.delayed(Duration.zero);
      events.add({'type': BridgeEventType.removed, 'key': 'a'});
      await Future<void>.delayed(Duration.zero);

      expect(controller.items.single.removed, isTrue);
    });

    test('列表上限为 maxItems，超出后丢弃最旧记录', () async {
      for (var i = 0; i < FeedController.maxItems + 5; i++) {
        events.add(postedEvent(record('k$i')));
      }
      await Future<void>.delayed(Duration.zero);

      expect(controller.items, hasLength(FeedController.maxItems));
      expect(
        controller.items.first.record.key,
        'k${FeedController.maxItems + 4}',
      );
    });

    test('cancel 成功时标记移除，失败时保留', () async {
      events.add(postedEvent(record('a')));
      await Future<void>.delayed(Duration.zero);

      expect(await controller.cancel(controller.items.single.record), isTrue);
      expect(controller.items.single.removed, isTrue);
      expect(repository.cancelledKeys, ['a']);
    });

    test('cancel 失败时不改变本地状态', () async {
      final failing = FeedController(
        repository: _FakeFeedRepository(cancelResult: false),
        events: const Stream.empty(),
      );
      addTearDown(failing.dispose);
      expect(await failing.cancel(record('a')), isFalse);
      expect(failing.items, isEmpty);
    });
  });
}
