import '../../history/domain/history_entry.dart';
import '../../rules/domain/rule_set.dart';
import 'comparison_models.dart';

abstract interface class ComparisonRepository {
  Future<ComparisonEvaluation> compare({
    required RuleSet base,
    required RuleSet candidate,
    required List<HistoryEntry> samples,
  });
  Future<bool> exportFile(String content, {required String fileName});
}
