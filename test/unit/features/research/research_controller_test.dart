import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/research/presentation/research_controller.dart';
import 'package:notifinterceptor/src/shared/domain/usage_recorder.dart';

import '../../../support/fake_research_repository.dart';

void main() {
  test('未参与前不记录 开启显式同意后只发送枚举事件 退出清空镜像', () async {
    final repository = FakeResearchRepository();
    final controller = ResearchController(repository: repository);
    addTearDown(controller.dispose);
    await controller.load();
    controller.record(UsageAction.sceneSwitch);
    expect(repository.actions, isEmpty);
    await controller.configure({'enabled': true, 'disclosureAccepted': 1});
    expect(repository.configurations.single['expectedRevision'], 0);
    controller.record(UsageAction.sceneSwitch);
    await Future<void>.delayed(Duration.zero);
    expect(repository.actions, [UsageAction.sceneSwitch]);
    expect(await controller.exportFile(), false);
    await controller.clear();
    expect(controller.status!.configuration.enabled, false);
    controller.record(UsageAction.sceneSwitch);
    expect(repository.actions, hasLength(1));
  });

  test('写入失败保留旧状态 采集观察者异常不影响功能', () async {
    final repository = FakeResearchRepository(enabled: true);
    final controller = ResearchController(repository: repository);
    addTearDown(controller.dispose);
    await controller.load();
    repository.failSave = true;
    await expectLater(
      controller.configure({'ruleStructures': true}),
      throwsStateError,
    );
    expect(controller.status!.configuration.ruleStructures, false);
    expect(controller.error, contains('save failed'));
    expect(controller.busy, false);
    repository.failRecord = true;
    controller.record(UsageAction.presetRestore);
    await Future<void>.delayed(Duration.zero);
  });

  test('已确认发送后刷新失败 不虚报发送失败', () async {
    final repository = FakeResearchRepository(enabled: true);
    final controller = ResearchController(repository: repository);
    addTearDown(controller.dispose);
    await controller.load();
    repository.failStatus = true;
    expect(await controller.sync(), 'batch acknowledged');
    expect(controller.error, contains('状态暂时无法刷新'));
    expect(repository.syncCalls, 1);
  });
}
