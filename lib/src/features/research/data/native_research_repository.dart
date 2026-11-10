import 'dart:convert';

import '../../../core/channel/interceptor_channel.dart';
import '../../../core/util/json_cast.dart';
import '../../../shared/domain/usage_recorder.dart';
import '../domain/research_repository.dart';
import '../domain/research_status.dart';

class NativeResearchRepository implements ResearchRepository {
  NativeResearchRepository(this._channel);
  final InterceptorChannel _channel;

  @override
  Future<bool> shareFile() async =>
      await _channel.invoke<bool>(BridgeMethod.shareResearchFile) ?? false;

  @override
  Future<ResearchStatus> end(int expectedRevision) async =>
      ResearchStatus.fromJson(
        asStringMap(
          await _channel.invoke<Map<dynamic, dynamic>>(
            BridgeMethod.endResearch,
            {'expectedRevision': expectedRevision},
          ),
        ),
      );

  @override
  Future<ResearchStatus> enroll(int expectedRevision) async =>
      ResearchStatus.fromJson(
        asStringMap(
          await _channel.invoke<Map<dynamic, dynamic>>(
            BridgeMethod.enrollResearch,
            {'expectedRevision': expectedRevision},
          ),
        ),
      );

  @override
  Future<ResearchStatus> status() async => ResearchStatus.fromJson(
    asStringMap(
      await _channel.invoke<Map<dynamic, dynamic>>(
        BridgeMethod.getResearchStatus,
      ),
    ),
  );

  @override
  Future<ResearchStatus> configure(Map<String, dynamic> changes) async =>
      ResearchStatus.fromJson(
        asStringMap(
          await _channel.invoke<Map<dynamic, dynamic>>(
            BridgeMethod.configureResearch,
            changes,
          ),
        ),
      );

  @override
  Future<void> record(UsageAction action) async {
    await _channel.invoke<void>(BridgeMethod.recordResearchAction, {
      'action': action.wire,
    });
  }

  @override
  Future<String?> preview() async {
    final content = await _channel.invoke<String>(
      BridgeMethod.previewResearchUpload,
    );
    if (content != null) {
      final map = asStringMap(jsonDecode(content));
      if (map['schemaVersion'] != 1 ||
          map['kind'] != 'notification_research_batch' ||
          map['batchId'] is! String ||
          map['hours'] is! List) {
        throw const FormatException('研究批次格式错误');
      }
    }
    return content;
  }

  @override
  Future<Map<String, dynamic>> sync() async {
    final map = asStringMap(
      await _channel.invoke<Map<dynamic, dynamic>>(
        BridgeMethod.syncResearchNow,
        {'disclosureAccepted': 2},
      ),
    );
    if (map['message'] is! String ||
        map['sent'] is! bool ||
        map['retry'] is! bool) {
      throw const FormatException('发送结果格式错误');
    }
    return map;
  }

  @override
  Future<ResearchStatus> clear() async => ResearchStatus.fromJson(
    asStringMap(
      await _channel.invoke<Map<dynamic, dynamic>>(
        BridgeMethod.clearResearchData,
      ),
    ),
  );

  @override
  Future<bool> exportFile() async =>
      await _channel.invoke<bool>(BridgeMethod.exportResearchFile) ?? false;
}
