import '../../../core/channel/interceptor_channel.dart';
import '../../../core/util/json_cast.dart';
import '../../../shared/domain/decision.dart';
import '../../feed/domain/notification_record.dart';
import '../domain/rule_set.dart';
import '../domain/rules_repository.dart';

class NativeRulesRepository implements RulesRepository {
  NativeRulesRepository(this._channel);

  final InterceptorChannel _channel;

  @override
  Future<RuleSet> load() async {
    final result = await _channel.invoke<Map<dynamic, dynamic>>(BridgeMethod.getRules);
    return RuleSet.fromJson(asStringMap(asStringMap(result)['ruleSet']));
  }

  @override
  Future<RuleSaveResult> save(RuleSet ruleSet) async {
    final result = await _channel.invoke<Map<dynamic, dynamic>>(
      BridgeMethod.saveRules,
      {'ruleSet': ruleSet.toJson()},
    );
    final map = asStringMap(result);
    return RuleSaveResult(
      ruleSet: RuleSet.fromJson(asStringMap(map['ruleSet'])),
      issues: asStringMapList(map['issues']).map(RuleIssue.fromJson).toList(),
    );
  }

  @override
  Future<Decision> evaluate(NotificationRecord sample, {RuleSet? ruleSet}) async {
    final result = await _channel.invoke<Map<dynamic, dynamic>>(
      BridgeMethod.evaluateSample,
      {
        'sample': sample.toJson(),
        if (ruleSet != null) 'ruleSet': ruleSet.toJson(),
      },
    );
    return Decision.fromJson(asStringMap(result));
  }

  @override
  Future<List<String>> seenPackages() async {
    final result = await _channel.invoke<List<dynamic>>(BridgeMethod.getSeenPackages);
    return asStringList(result);
  }
}
