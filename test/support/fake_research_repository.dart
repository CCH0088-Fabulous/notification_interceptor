import 'dart:convert';
import 'dart:io';

import 'package:notifinterceptor/src/features/research/domain/research_repository.dart';
import 'package:notifinterceptor/src/features/research/domain/research_status.dart';
import 'package:notifinterceptor/src/shared/domain/usage_recorder.dart';

class FakeResearchRepository implements ResearchRepository {
  FakeResearchRepository({bool enabled = false}) {
    if (enabled) {
      config.addAll({
        'enabled': true,
        'participantId': 'test-install',
        'consentAt': 123,
        'endpoint': 'https://research.example/upload',
        'hasToken': true,
        'acceptedDisclosureVersion': 2,
      });
    }
  }
  Map<String, dynamic> raw =
      jsonDecode(
            File('test/fixtures/research_status_v1.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  Map<String, dynamic> get config =>
      raw['configuration'] as Map<String, dynamic>;
  final configurations = <Map<String, dynamic>>[];
  final actions = <UsageAction>[];
  int clearCalls = 0;
  int syncCalls = 0;
  int enrollCalls = 0;
  int shareCalls = 0;
  int exportCalls = 0;
  int endCalls = 0;
  bool failShare = false;
  bool failEnroll = false;
  bool failSave = false;
  bool failStatus = false;
  bool failRecord = false;
  bool exportResult = false;
  String? previewContent =
      '{"schemaVersion":1,"kind":"notification_research_batch","batchId":"batch-1","hours":[]}';

  @override
  Future<ResearchStatus> enroll(int expectedRevision) async {
    enrollCalls++;
    if (failEnroll) {
      config['pilotPending'] = true;
      return status();
    }
    config.addAll({
      'hasToken': true,
      'pilotPending': false,
      'pilotEnrolled': true,
      'endpoint': raw['pilotEndpoint'],
      'revision': expectedRevision + 1,
    });
    return status();
  }

  @override
  Future<ResearchStatus> status() async {
    if (failStatus) throw StateError('status unavailable');
    return ResearchStatus.fromJson(
      jsonDecode(jsonEncode(raw)) as Map<String, dynamic>,
    );
  }

  @override
  Future<ResearchStatus> configure(Map<String, dynamic> changes) async {
    configurations.add(Map.of(changes));
    if (failSave) throw StateError('save failed');
    for (final key in [
      'enabled',
      'ruleStructures',
      'autoUpload',
      'wifiOnly',
      'cohort',
      'endpoint',
    ]) {
      if (changes.containsKey(key)) config[key] = changes[key];
    }
    if (config['enabled'] == true) {
      config.addAll({'participantId': 'test-install', 'consentAt': 123});
    }
    config['revision'] = (config['revision'] as int) + 1;
    if ((changes['token'] as String?)?.isNotEmpty ?? false) {
      config['hasToken'] = true;
    }
    return status();
  }

  @override
  Future<void> record(UsageAction action) async {
    if (failRecord) throw StateError('observer failed');
    actions.add(action);
  }

  @override
  Future<String?> preview() async => previewContent;
  @override
  Future<Map<String, dynamic>> sync() async {
    syncCalls++;
    return {'sent': true, 'retry': false, 'message': 'batch acknowledged'};
  }

  @override
  Future<ResearchStatus> clear() async {
    clearCalls++;
    raw =
        jsonDecode(
              File('test/fixtures/research_status_v1.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    return status();
  }

  @override
  Future<bool> exportFile() async {
    exportCalls++;
    return exportResult;
  }

  @override
  Future<bool> shareFile() async {
    shareCalls++;
    if (failShare) throw StateError('share unavailable');
    return true;
  }

  @override
  Future<ResearchStatus> end(int expectedRevision) async {
    endCalls++;
    config.addAll({
      'enabled': false,
      'endedAt': 456,
      'revision': expectedRevision + 1,
    });
    return status();
  }
}
