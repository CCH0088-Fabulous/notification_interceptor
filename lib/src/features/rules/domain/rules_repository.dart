import '../../../shared/domain/decision.dart';
import '../../feed/domain/notification_record.dart';
import 'rule_set.dart';

abstract interface class RulesRepository {
  Future<RuleSet> load();

  Future<RuleSaveResult> save(RuleSet ruleSet);

  /// 试运行：用原生引擎（唯一实现）对样例做判定，避免 Dart 侧出现第二套匹配逻辑。
  Future<Decision> evaluate(NotificationRecord sample, {RuleSet? ruleSet});

  Future<List<String>> seenPackages();
}
