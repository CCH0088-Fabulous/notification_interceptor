import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_record.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_event.dart';
import 'package:notifinterceptor/src/features/history/domain/history_entry.dart';
import 'package:notifinterceptor/src/shared/domain/decision.dart';
import 'package:notifinterceptor/src/shared/domain/rule_action.dart';

void main() {
  group('NotificationRecord', () {
    test('系统隐藏内容时明确标注，原始数据与匹配字段不变', () {
      const record = NotificationRecord(
        key: 'redacted',
        id: 1,
        packageName: 'dev.poc.notifgen',
        appLabel: '通知生成器',
        postTime: 1760000000000,
        title: '通知生成器',
        text: 'Sensitive notification content hidden',
      );
      expect(record.isContentHidden, isTrue);
      expect(record.displayTitle, '通知内容已隐藏');
      expect(record.displayBody, '系统已隐藏通知内容，无法读取原文');
      expect(record.title, '通知生成器');
      expect(record.toJson()['text'], 'Sensitive notification content hidden');
      expect(
        record.searchableText,
        contains('Sensitive notification content hidden'),
      );
    });

    test('正文仅提到系统隐藏提示的普通消息不被误判', () {
      const record = NotificationRecord(
        key: 'normal',
        id: 1,
        packageName: 'com.chat',
        postTime: 1,
        title: '技术讨论',
        text: '遇到 Sensitive notification content hidden 怎么办？',
      );
      expect(record.isContentHidden, isFalse);
      expect(record.displayTitle, '技术讨论');
      expect(record.displayBody, record.text);
    });
    test('能解析完整快照并保持字段一致', () {
      final json =
          jsonDecode(
                File('test/fixtures/history_entry_v1.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      final record = NotificationRecord.fromJson(
        json['snapshot'] as Map<String, dynamic>,
      );

      expect(record.key, '0|com.example.shop|1|null|10001');
      expect(record.packageName, 'com.example.shop');
      expect(record.displayApp, '示例商城');
      expect(record.displayTitle, '限时优惠');
      expect(record.textLines, ['行1', '行2']);
      expect(record.channelName, '营销');
      expect(record.extras['android.title'], '限时优惠');

      final roundTrip = NotificationRecord.fromJson(record.toJson());
      expect(roundTrip.toJson(), record.toJson());
    });

    test('字段缺失时使用安全默认值，不抛异常', () {
      final record = NotificationRecord.fromJson({'packageName': 'com.x'});

      expect(record.key, isEmpty);
      expect(record.title, isNull);
      expect(record.textLines, isEmpty);
      expect(record.isClearable, isTrue);
      expect(record.progress, -1);
      expect(record.displayTitle, 'com.x');
      expect(record.displayBody, '（无正文）');
    });

    test('数字类型为 double 时也能解析为 int（编解码器差异）', () {
      final record = NotificationRecord.fromJson({
        'postTime': 1760000000000.0,
        'priority': 2.0,
        'progress': 50.0,
      });

      expect(record.postTime, 1760000000000);
      expect(record.priority, 2);
      expect(record.progress, 50);
    });
  });

  test('事件解码器按原生信封读取 snapshot，实时与仓储订阅共用同一解析', () {
    final history =
        jsonDecode(
              File('test/fixtures/history_entry_v1.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final event = NotificationEvent.fromJson({
      'type': 'posted',
      'record': history,
      'decision': {'action': 'intercept', 'reason': 'rule'},
    });
    expect(event.record!.key, '0|com.example.shop|1|null|10001');
    expect(event.record!.displayTitle, '限时优惠');
    expect(event.record!.postTime, history['snapshot']['postTime']);
    expect(event.decision!.shouldIntercept, true);
  });

  group('HistoryEntry', () {
    test('能解析固件并往返一致', () {
      final json =
          jsonDecode(
                File('test/fixtures/history_entry_v1.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      final entry = HistoryEntry.fromJson(json);

      expect(entry.id, 'h1');
      expect(entry.action, RuleAction.intercept);
      expect(entry.matchedRuleName, '屏蔽电商营销');
      expect(entry.cancelStatus, CancelStatus.success);
      expect(HistoryEntry.fromJson(entry.toJson()).toJson(), entry.toJson());
    });

    test('未知枚举值回退为安全默认值', () {
      final json =
          jsonDecode(
                File('test/fixtures/history_entry_v1.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      final entry = HistoryEntry.fromJson({
        ...json,
        'action': 'future-action',
        'cancelStatus': 'x',
      });

      expect(entry.action, RuleAction.allow);
      expect(entry.cancelStatus, CancelStatus.notAttempted);
    });
  });

  group('Decision', () {
    test('describe 覆盖各判定来源', () {
      expect(const Decision(reason: 'disabled').describe(), '全局规则已关闭');
      expect(const Decision(reason: 'self').describe(), '本应用自身通知');
      expect(
        const Decision(reason: 'rule', ruleId: 'r1', ruleName: '营销').describe(),
        contains('营销'),
      );
      expect(const Decision().describe(), contains('默认动作'));
    });

    test('只有 intercept 才应拦截', () {
      expect(
        const Decision(action: RuleAction.intercept).shouldIntercept,
        isTrue,
      );
      expect(
        const Decision(action: RuleAction.logOnly).shouldIntercept,
        isFalse,
      );
      expect(const Decision(action: RuleAction.allow).shouldIntercept, isFalse);
    });
  });
}
