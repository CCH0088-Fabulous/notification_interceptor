import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/features/research/presentation/research_controller.dart';
import 'package:notifinterceptor/src/features/research/presentation/research_page.dart';
import '../support/fake_research_repository.dart';

void main() {
  Future<ResearchController> open(
    WidgetTester tester,
    FakeResearchRepository repo,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = ResearchController(repository: repo);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ResearchPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> reveal(WidgetTester tester, String key) async {
    await tester.scrollUntilVisible(
      find.byKey(Key(key)),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('离线同意后开始 不登记不上传 无技术配置', (tester) async {
    final repo = FakeResearchRepository();
    repo.raw.addAll({
      'pilotAvailable': true,
      'pilotEndpoint': 'https://old.example/api/research/upload',
    });
    final controller = await open(tester, repo);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byKey(const Key('research-start')));
    await tester.pumpAndSettle();
    expect(find.textContaining('事件明细保留 14 天'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(repo.configurations, isEmpty);
    await tester.tap(find.byKey(const Key('research-start')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同意并开始'));
    await tester.pumpAndSettle();
    expect(repo.configurations.single['disclosureAccepted'], 2);
    expect(repo.configurations.single['autoUpload'], false);
    expect(repo.enrollCalls, 0);
    expect(repo.syncCalls, 0);
    expect(controller.status!.configuration.enabled, true);
    expect(find.byKey(const Key('research-share')), findsOneWidget);
  });
  testWidgets('主按钮直接分享 不清空 不声称已收到', (tester) async {
    final repo = FakeResearchRepository(enabled: true);
    await open(tester, repo);
    await tester.tap(find.byKey(const Key('research-share')));
    await tester.pumpAndSettle();
    expect(repo.shareCalls, 1);
    expect(repo.clearCalls, 0);
    expect(find.textContaining('请在分享应用中选择收件人'), findsOneWidget);
    expect(find.text('发送成功'), findsNothing);
  });
  testWidgets('结束记录保留编号和分享入口 重开页面仍可分享', (tester) async {
    final repo = FakeResearchRepository(enabled: true);
    final controller = await open(tester, repo);
    await reveal(tester, 'research-end');
    await tester.tap(find.byKey(const Key('research-end')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('结束记录'));
    await tester.pumpAndSettle();
    expect(repo.endCalls, 1);
    expect(repo.clearCalls, 0);
    expect(controller.status!.configuration.participantId, 'test-install');
    expect(controller.status!.configuration.enabled, false);
    await reveal(tester, 'research-share');
    await tester.tap(find.byKey(const Key('research-share')));
    await tester.pumpAndSettle();
    expect(repo.shareCalls, 1);
  });
  testWidgets('保存取消与分享失败都保留数据 删除单独确认', (tester) async {
    final repo = FakeResearchRepository(enabled: true);
    await open(tester, repo);
    await tester.tap(find.byKey(const Key('research-save-file')));
    await tester.pumpAndSettle();
    expect(repo.exportCalls, 1);
    expect(repo.clearCalls, 0);
    repo.failShare = true;
    await tester.tap(find.byKey(const Key('research-share')));
    await tester.pumpAndSettle();
    expect(find.textContaining('原数据仍保留'), findsWidgets);
    await reveal(tester, 'research-clear');
    await tester.tap(find.byKey(const Key('research-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(repo.clearCalls, 0);
    await tester.tap(find.byKey(const Key('research-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除研究数据'));
    await tester.pumpAndSettle();
    expect(repo.clearCalls, 1);
  });
  testWidgets('规则结构继续单独同意', (tester) async {
    final repo = FakeResearchRepository(enabled: true);
    await open(tester, repo);
    await reveal(tester, 'research-rule-structures');
    await tester.tap(find.byKey(const Key('research-rule-structures')));
    await tester.pumpAndSettle();
    expect(repo.configurations, isEmpty);
    await tester.tap(find.text('同意统计结构'));
    await tester.pumpAndSettle();
    expect(repo.configurations.single['ruleDisclosureAccepted'], 2);
  });
}
