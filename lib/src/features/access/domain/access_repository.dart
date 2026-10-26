import 'access_status.dart';

/// 通知使用权的查询与引导。实现位于 data 层。
abstract interface class AccessRepository {
  Future<AccessStatus> getStatus();

  Future<void> openAccessSettings();

  Future<void> requestRebind();
}
