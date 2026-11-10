import '../../../shared/domain/usage_recorder.dart';
import 'research_status.dart';

abstract interface class ResearchRepository {
  Future<ResearchStatus> status();
  Future<ResearchStatus> enroll(int expectedRevision);
  Future<ResearchStatus> configure(Map<String, dynamic> changes);
  Future<void> record(UsageAction action);
  Future<String?> preview();
  Future<Map<String, dynamic>> sync();
  Future<ResearchStatus> clear();
  Future<bool> exportFile();
  Future<bool> shareFile();
  Future<ResearchStatus> end(int expectedRevision);
}
