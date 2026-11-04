import '../../../core/channel/interceptor_channel.dart';
import '../../../core/util/json_cast.dart';
import '../../../shared/domain/decision.dart';
import '../../../shared/domain/rule_action.dart';
import '../../history/domain/history_entry.dart';
import '../../rules/domain/rule_set.dart';
import '../domain/comparison_models.dart';
import '../domain/comparison_repository.dart';

class NativeComparisonRepository implements ComparisonRepository {
  NativeComparisonRepository(this._channel);
  final InterceptorChannel _channel;

  @override
  Future<ComparisonEvaluation> compare({
    required RuleSet base,
    required RuleSet candidate,
    required List<HistoryEntry> samples,
  }) async {
    final response = asStringMap(
      await _channel.invoke<Map<dynamic, dynamic>>(
        BridgeMethod.compareRuleSets,
        {
          'baseRuleSet': base.toJson(),
          'candidateRuleSet': candidate.toJson(),
          'samples': samples
              .map(
                (e) => {
                  'entryId': e.id,
                  'timestamp': e.timestamp,
                  'record': Map<String, dynamic>.of(e.record.toJson())
                    ..remove('extras'),
                },
              )
              .toList(),
        },
      ),
    );
    if (response['rows'] is! List ||
        response['evaluatedAt'] is! int ||
        (response['evaluatedAt'] as int) <= 0 ||
        response['zoneId'] is! String ||
        (response['zoneId'] as String).trim().isEmpty) {
      throw const FormatException('批量对比结果格式错误');
    }
    final rows = <ComparisonDecisionPair>[];
    final rawRows = response['rows'] as List;
    if (rawRows.length != samples.length) {
      throw const FormatException('批量对比结果数量不一致');
    }
    for (var i = 0; i < rawRows.length; i++) {
      final row = asStringMap(rawRows[i]);
      if (row['entryId'] != samples[i].id ||
          row['before'] is! Map ||
          row['after'] is! Map) {
        throw const FormatException('批量对比样本顺序不一致');
      }
      rows.add(
        ComparisonDecisionPair(
          entryId: samples[i].id,
          before: _decision(row['before']),
          after: _decision(row['after']),
        ),
      );
    }
    return ComparisonEvaluation(
      rows: List.unmodifiable(rows),
      evaluatedAt: response['evaluatedAt'] as int,
      zoneId: response['zoneId'] as String,
      baseIssues: _issues(response['baseIssues']),
      candidateIssues: _issues(response['candidateIssues']),
    );
  }

  static List<RuleIssue> _issues(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List) throw const FormatException('规则校验提示格式无效');
    return raw
        .map((item) {
          if (item is! Map) throw const FormatException('规则校验提示格式无效');
          final json = asStringMap(item);
          if (json['ruleId'] is! String ||
              json['field'] is! String ||
              json['message'] is! String) {
            throw const FormatException('规则校验提示字段无效');
          }
          return RuleIssue.fromJson(json);
        })
        .toList(growable: false);
  }

  static Decision _decision(Object? raw) {
    final json = asStringMap(raw);
    if (!RuleAction.values.any((action) => action.wire == json['action']) ||
        !['rule', 'default', 'disabled', 'self'].contains(json['reason']) ||
        (json['ruleId'] != null && json['ruleId'] is! String) ||
        (json['ruleName'] != null && json['ruleName'] is! String) ||
        (json['reason'] == 'rule' &&
            (json['ruleId'] is! String || json['ruleName'] is! String))) {
      throw const FormatException('原生对比动作或命中信息无效');
    }
    return Decision.fromJson(json);
  }

  @override
  Future<bool> exportFile(String content, {required String fileName}) async =>
      await _channel.invoke<bool>(BridgeMethod.exportComparisonFile, {
        'content': content,
        'fileName': fileName,
      }) ??
      false;
}
