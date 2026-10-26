import '../../../core/channel/interceptor_channel.dart';
import '../../../core/util/json_cast.dart';
import '../domain/access_repository.dart';
import '../domain/access_status.dart';

class NativeAccessRepository implements AccessRepository {
  NativeAccessRepository(this._channel);

  final InterceptorChannel _channel;

  @override
  Future<AccessStatus> getStatus() async {
    final result = await _channel.invoke<Map<dynamic, dynamic>>(BridgeMethod.getStatus);
    return AccessStatus.fromJson(asStringMap(result));
  }

  @override
  Future<void> openAccessSettings() async {
    await _channel.invoke<bool>(BridgeMethod.openAccessSettings);
  }

  @override
  Future<void> requestRebind() async {
    await _channel.invoke<Map<dynamic, dynamic>>(BridgeMethod.requestRebind);
  }
}
