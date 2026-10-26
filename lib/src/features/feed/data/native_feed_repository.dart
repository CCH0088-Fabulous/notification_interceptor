import '../../../core/channel/interceptor_channel.dart';
import '../../../core/util/json_cast.dart';
import '../domain/feed_repository.dart';
import '../domain/notification_event.dart';
import '../domain/notification_record.dart';

class NativeFeedRepository implements FeedRepository {
  NativeFeedRepository(this._channel);

  final InterceptorChannel _channel;

  @override
  Stream<NotificationEvent> watch() =>
      _channel.events.map(NotificationEvent.fromJson);

  @override
  Future<List<NotificationRecord>> activeNotifications() async {
    final result = await _channel.invoke<List<dynamic>>(
      BridgeMethod.getActiveNotifications,
    );
    return asStringMapList(result).map(NotificationRecord.fromJson).toList();
  }

  @override
  Future<bool> cancel(String key) async {
    final result = await _channel.invoke<Map<dynamic, dynamic>>(
      BridgeMethod.cancel,
      {'key': key},
    );
    final map = asStringMap(result);
    return asBool(map['cancelled']);
  }
}
