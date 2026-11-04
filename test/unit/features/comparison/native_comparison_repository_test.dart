import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/core/channel/interceptor_channel.dart';
import 'package:notifinterceptor/src/features/comparison/data/native_comparison_repository.dart';
import 'package:notifinterceptor/src/features/feed/domain/notification_record.dart';
import 'package:notifinterceptor/src/features/history/domain/history_entry.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_set.dart';
import 'package:notifinterceptor/src/features/rules/domain/rule_spec.dart';
import 'package:notifinterceptor/src/shared/domain/rule_action.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('test/comparison-contract');
  final repository = NativeComparisonRepository(
    InterceptorChannel(methodChannel: method),
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const base = RuleSet(defaultAction: RuleAction.logOnly);
  const candidate = RuleSet(
    rules: [
      RuleSpec(id: 'drop', name: '移出促销', keywordsAny: ['促销']),
    ],
  );
  const samples = [
    HistoryEntry(
      id: 'history-1',
      timestamp: 1793973600000,
      record: NotificationRecord(
        key: 'same-notification-key',
        id: 7,
        packageName: 'com.demo.shop',
        postTime: 1760000000000,
        title: '促销提醒',
        extras: {'private-debug': 'not-needed-for-replay'},
      ),
      action: RuleAction.allow,
    ),
    HistoryEntry(
      id: 'history-2',
      timestamp: 1793973601000,
      record: NotificationRecord(
        key: 'same-notification-key',
        id: 7,
        packageName: 'com.demo.shop',
        postTime: 1760000001000,
        title: '普通更新',
      ),
      action: RuleAction.intercept,
      cancelStatus: CancelStatus.success,
    ),
  ];

  Map<String, Object?> decision(String action, {String reason = 'default'}) => {
    'action': action,
    'reason': reason,
    'ruleId': reason == 'rule' ? 'drop' : null,
    'ruleName': reason == 'rule' ? '移出促销' : null,
  };

  Map<String, Object?> response() => {
    'evaluatedAt': 1793973602000,
    'zoneId': 'Asia/Shanghai',
    'baseIssues': <Object?>[],
    'candidateIssues': <Object?>[],
    'rows': [
      {
        'entryId': 'history-1',
        'before': decision('log_only'),
        'after': decision('intercept', reason: 'rule'),
      },
      {
        'entryId': 'history-2',
        'before': decision('log_only'),
        'after': decision('allow'),
      },
    ],
  };

  tearDown(() => messenger.setMockMethodCallHandler(method, null));

  test('真实codec传递完整两套规则和历史事件时间，不使用通知postTime', () async {
    MethodCall? captured;
    messenger.setMockMethodCallHandler(method, (call) async {
      captured = call;
      return response();
    });
    final result = await repository.compare(
      base: base,
      candidate: candidate,
      samples: samples,
    );
    expect(captured!.method, BridgeMethod.compareRuleSets);
    final arguments = captured!.arguments as Map;
    expect(arguments['baseRuleSet'], base.toJson());
    expect(arguments['candidateRuleSet'], candidate.toJson());
    final sent = arguments['samples'] as List;
    expect(
      sent.map((s) => (s as Map)['timestamp']),
      samples.map((s) => s.timestamp),
    );
    expect(
      (sent.first as Map)['timestamp'],
      isNot(samples.first.record.postTime),
    );
    final record = (sent.first as Map)['record'] as Map;
    expect(record['postTime'], samples.first.record.postTime);
    expect(record.containsKey('extras'), false);
    expect(result.rows.map((row) => row.entryId), ['history-1', 'history-2']);
    expect(result.rows.first.before.action, RuleAction.logOnly);
    expect(result.rows.first.after.action, RuleAction.intercept);
    expect(result.rows.first.after.ruleId, 'drop');
    expect(result.rows.last.after.action, RuleAction.allow);
    expect(result.zoneId, 'Asia/Shanghai');
    expect(result.evaluatedAt, 1793973602000);
  });

  test('原生两侧静态告警完整关联，不当作已实际移除的状态', () async {
    final raw = response()
      ..['baseIssues'] = [
        {'ruleId': 'old', 'field': 'titleRegex', 'message': '标题正则无效'},
      ]
      ..['candidateIssues'] = [
        {'ruleId': 'new', 'field': 'match', 'message': '规则无条件'},
      ];
    messenger.setMockMethodCallHandler(method, (_) async => raw);
    final result = await repository.compare(
      base: base,
      candidate: candidate,
      samples: samples,
    );
    expect(result.baseIssues.single.ruleId, 'old');
    expect(result.candidateIssues.single.ruleId, 'new');
    expect(result.candidateIssues.single.field, 'match');
  });

  test('缺失、多余或乱序样本结果拒绝，不能把决定关联到错误记录', () async {
    final valid = response();
    final rows = valid['rows'] as List;
    for (final badRows in [
      [],
      [rows.first],
      [rows.last, rows.first],
      [rows.first, rows.last, rows.last],
      [
        rows.first,
        {'entryId': 'wrong', 'before': {}, 'after': {}},
      ],
    ]) {
      messenger.setMockMethodCallHandler(
        method,
        (_) async => {...valid, 'rows': badRows},
      );
      await expectLater(
        repository.compare(base: base, candidate: candidate, samples: samples),
        throwsFormatException,
      );
    }
  });

  test('未知动作、错误类型或缺失命中信息拒绝而不是静默放行', () async {
    final valid = response();
    final second = (valid['rows'] as List).last;
    for (final invalid in <Object?>[
      {},
      decision('unknown'),
      {'action': 'allow'},
      decision('allow', reason: 'unknown'),
      {...decision('allow'), 'ruleId': 7},
      {...decision('allow'), 'ruleName': true},
      'not-a-decision',
    ]) {
      messenger.setMockMethodCallHandler(
        method,
        (_) async => {
          ...valid,
          'rows': [
            {
              'entryId': 'history-1',
              'before': decision('allow'),
              'after': invalid,
            },
            second,
          ],
        },
      );
      await expectLater(
        repository.compare(base: base, candidate: candidate, samples: samples),
        throwsFormatException,
      );
    }
  });

  test('无效生成时间、时区和告警结构整体拒绝', () async {
    for (final bad in <Map<String, Object?>>[
      {'evaluatedAt': 0},
      {'evaluatedAt': 1.5},
      {'zoneId': ''},
      {'zoneId': false},
      {'baseIssues': 'not-a-list'},
      {
        'candidateIssues': [4],
      },
      {
        'candidateIssues': [
          {'ruleId': 'bad', 'field': 3, 'message': 'bad'},
        ],
      },
    ]) {
      messenger.setMockMethodCallHandler(
        method,
        (_) async => {...response(), ...bad},
      );
      await expectLater(
        repository.compare(base: base, candidate: candidate, samples: samples),
        throwsFormatException,
      );
    }
  });

  test('报告文件独立导出方法支持超过预设2MiB的内容，取消返回false', () async {
    MethodCall? captured;
    var cancelled = true;
    messenger.setMockMethodCallHandler(method, (call) async {
      captured = call;
      return !cancelled;
    });
    final content = 'x' * (2 * 1024 * 1024 + 1);
    expect(
      await repository.exportFile(content, fileName: 'batch-report.json'),
      false,
    );
    expect(captured!.method, BridgeMethod.exportComparisonFile);
    expect(captured!.method, isNot(BridgeMethod.exportPresetFile));
    final args = captured!.arguments as Map;
    expect(args['fileName'], 'batch-report.json');
    expect((args['content'] as String).length, content.length);
    cancelled = false;
    expect(await repository.exportFile('{}', fileName: 'again.json'), true);
  });

  test('原生计算或文件错误继续向调用方传递', () async {
    messenger.setMockMethodCallHandler(method, (_) async {
      throw PlatformException(code: 'RULE_COMPARISON', message: '样本时间无效');
    });
    await expectLater(
      repository.compare(base: base, candidate: candidate, samples: samples),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      repository.exportFile('{}', fileName: 'report.json'),
      throwsA(isA<Exception>()),
    );
  });
}
