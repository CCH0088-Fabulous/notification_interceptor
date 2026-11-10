import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/core/channel/interceptor_channel.dart';
import 'package:notifinterceptor/src/features/research/data/native_research_repository.dart';
import 'package:notifinterceptor/src/shared/domain/usage_recorder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('test/research-contract');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final repository = NativeResearchRepository(
    InterceptorChannel(methodChannel: method),
  );
  late Map<String, dynamic> fixture;
  setUp(() {
    fixture =
        jsonDecode(
              File('test/fixtures/research_status_v1.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
  });
  tearDown(() => messenger.setMockMethodCallHandler(method, null));

  test('读取状态符合协议 拒绝令牌泄漏和非法计数', () async {
    messenger.setMockMethodCallHandler(method, (_) async => fixture);
    expect((await repository.status()).configuration.enabled, false);
    (fixture['configuration'] as Map)['token'] = 'should-not-return';
    await expectLater(repository.status(), throwsFormatException);
    (fixture['configuration'] as Map).remove('token');
    (fixture['statistics'] as Map)['pendingHours'] = -1;
    await expectLater(repository.status(), throwsFormatException);
  });

  test('配置参数仅经集中桥接发送 记录只携带枚举代码', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call);
      return call.method == BridgeMethod.configureResearch ? fixture : null;
    });
    await repository.configure({
      'enabled': true,
      'expectedRevision': 0,
      'disclosureAccepted': 1,
    });
    await repository.record(UsageAction.sceneSwitch);
    expect(calls[0].method, BridgeMethod.configureResearch);
    expect((calls[0].arguments as Map)['disclosureAccepted'], 1);
    expect(calls[1].method, BridgeMethod.recordResearchAction);
    expect(calls[1].arguments, {'action': 'scene_switch'});
  });

  test('预览校验类型和版本 取消导出不当成功', () async {
    Object? response;
    messenger.setMockMethodCallHandler(method, (_) async => response);
    expect(await repository.preview(), isNull);
    response =
        '{"schemaVersion":2,"kind":"notification_research_batch","batchId":"id","hours":[]}';
    await expectLater(repository.preview(), throwsFormatException);
    response =
        '{"schemaVersion":1,"kind":"notification_research_batch","batchId":"id","hours":[]}';
    expect(await repository.preview(), contains('notification_research_batch'));
    response = false;
    expect(await repository.exportFile(), false);
  });

  test('手动发送携带明确同意 并保留未确认的业务结果', () async {
    MethodCall? captured;
    messenger.setMockMethodCallHandler(method, (call) async {
      captured = call;
      return {
        'sent': false,
        'retry': false,
        'message': 'missing batch acknowledgement',
      };
    });
    expect((await repository.sync())['sent'], false);
    expect(captured!.method, BridgeMethod.syncResearchNow);
    expect(captured!.arguments, {'disclosureAccepted': 2});
  });

  test('自动登记只传期望版本 不向 Dart 暴露凭证', () async {
    MethodCall? captured;
    messenger.setMockMethodCallHandler(method, (call) async {
      captured = call;
      fixture['pilotAvailable'] = true;
      fixture['pilotEndpoint'] = 'https://example.test/api/research/upload';
      (fixture['configuration'] as Map)['pilotEnrolled'] = true;
      return fixture;
    });
    expect((await repository.enroll(7)).configuration.pilotEnrolled, true);
    expect(captured!.method, BridgeMethod.enrollResearch);
    expect(captured!.arguments, {'expectedRevision': 7});
    (fixture['configuration'] as Map)['pilotPending'] = 'invalid';
    await expectLater(repository.status(), throwsFormatException);
  });
}
