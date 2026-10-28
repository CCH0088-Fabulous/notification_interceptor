import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/access/domain/access_repository.dart';
import 'package:notifinterceptor/src/features/access/domain/access_status.dart';
import 'package:notifinterceptor/src/features/access/presentation/access_controller.dart';
import 'package:notifinterceptor/src/features/feed/domain/feed_repository.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_event.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_record.dart';
import 'package:notifinterceptor/src/features/feed/presentation/feed_controller.dart';
import 'package:notifinterceptor/src/features/history/domain/history_entry.dart';
import 'package:notifinterceptor/src/features/history/domain/history_query.dart';
import 'package:notifinterceptor/src/features/history/domain/history_repository.dart';
import 'package:notifinterceptor/src/features/history/presentation/history_controller.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_set.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_spec.dart';
import 'package:notifinterceptor/src/features/rules/domain/rules_repository.dart';
import 'package:notifinterceptor/src/features/rules/presentation/rules_controller.dart';
import 'package:notifinterceptor/src/shared/domain/decision.dart';
import 'package:notifinterceptor/src/shared/domain/rule_action.dart';
import 'package:notifinterceptor/src/shared/widgets/app_scaffold.dart';

class _Access implements AccessRepository {
  @override
  Future<AccessStatus> getStatus() async =>
      const AccessStatus(granted: true, connected: true, sdkInt: 36);

  @override
  Future<void> openAccessSettings() async {}

  @override
  Future<void> requestRebind() async {}
}

class _Feed implements FeedRepository {
  @override
  Future<List<NotificationRecord>> activeNotifications() async => const [
    NotificationRecord(
      key: 'k1',
      id: 1,
      packageName: 'com.demo.shop',
      appLabel: '演示商城',
      postTime: 1760000000000,
      title: '限时优惠',
      text: '今日秒杀开始',
      channelName: '营销',
    ),
    NotificationRecord(
      key: 'summary',
      id: 2,
      packageName: 'com.demo.shop',
      appLabel: '演示商城',
      postTime: 1760000000000,
      title: '系统分组汇总',
      isGroupSummary: true,
    ),
  ];

  @override
  Future<bool> cancel(String key) async => true;

  @override
  Stream<NotificationEvent> watch() => const Stream.empty();
}

class _Rules implements RulesRepository {
  RuleSet ruleSet = const RuleSet(
    rules: [
      RuleSpec(id: 'r1', name: '屏蔽营销', packages: ['com.demo.shop']),
    ],
  );

  @override
  Future<RuleSet> load() async => ruleSet;

  @override
  Future<RuleSaveResult> save(RuleSet rules) async {
    ruleSet = rules;
    return RuleSaveResult(ruleSet: rules, issues: const []);
  }

  @override
  Future<Decision> evaluate(
    NotificationRecord sample, {
    RuleSet? ruleSet,
  }) async => const Decision();

  @override
  Future<List<String>> seenPackages() async => const ['com.demo.shop'];
}

class _History implements HistoryRepository {
  @override
  Future<void> clear() async {}

  @override
  Future<String> exportJson() async => '[]';

  @override
  Future<List<HistoryEntry>> query(HistoryQuery query) async => [
    HistoryEntry(
      id: 'h1',
      timestamp: 1760000000000,
      record: const NotificationRecord(
        key: 'k1',
        id: 1,
        packageName: 'com.demo.shop',
        postTime: 1760000000000,
        title: '限时优惠',
      ),
      action: RuleAction.intercept,
      matchedRuleName: '屏蔽营销',
    ),
  ];

  @override
  Future<HistoryStats> stats() async =>
      const HistoryStats(total: 1, byAction: {RuleAction.intercept: 1});
}

void main() {
  testWidgets('四个 tab 均可渲染且不抛异常', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final events = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(events.close);

    final access = AccessController(
      repository: _Access(),
      events: events.stream,
    );
    final feed = FeedController(repository: _Feed(), events: events.stream);
    final rules = RulesController(repository: _Rules());
    final history = HistoryController(repository: _History());
    addTearDown(() {
      access.dispose();
      feed.dispose();
      rules.dispose();
      history.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: AppScaffold(
          access: access,
          feed: feed,
          rules: rules,
          history: history,
        ),
      ),
    );
    await access.refresh();
    await feed.refreshActive();
    await rules.load();
    await history.load();
    await tester.pumpAndSettle();

    // 实时页：应显示监听状态与通知卡片
    expect(find.text('监听中'), findsOneWidget);
    expect(find.text('限时优惠'), findsOneWidget);
    expect(find.text('系统分组汇总'), findsNothing);
    expect(feed.items, hasLength(2)); // 实时源记录保留，页面只显示具体消息。
    expect(find.text('本次会话：1 条 · 拦截 0 条'), findsOneWidget);

    await tester.tap(find.text('规则'));
    await tester.pumpAndSettle();
    expect(find.text('屏蔽营销'), findsOneWidget);
    expect(find.text('新建规则'), findsOneWidget);

    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(find.text('共 1 条'), findsOneWidget);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('通知使用权'), findsOneWidget);
    expect(find.text('能力边界（必读）'), findsOneWidget);
  });

  testWidgets('未授权时实时页展示授权引导', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final events = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(events.close);

    final access = AccessController(
      repository: _AccessDenied(),
      events: events.stream,
    );
    final feed = FeedController(repository: _Feed(), events: events.stream);
    final rules = RulesController(repository: _Rules());
    final history = HistoryController(repository: _History());
    addTearDown(() {
      access.dispose();
      feed.dispose();
      rules.dispose();
      history.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: AppScaffold(
          access: access,
          feed: feed,
          rules: rules,
          history: history,
        ),
      ),
    );
    await access.refresh();
    await tester.pumpAndSettle();

    expect(find.text('尚未授予「通知使用权」'), findsOneWidget);
    // 顶部横幅与空态各有一个引导按钮
    expect(find.text('去授权'), findsWidgets);
  });
}

class _AccessDenied implements AccessRepository {
  @override
  Future<AccessStatus> getStatus() async => const AccessStatus();

  @override
  Future<void> openAccessSettings() async {}

  @override
  Future<void> requestRebind() async {}
}
