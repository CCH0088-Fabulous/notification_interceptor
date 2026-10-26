import 'notification_event.dart';
import 'notification_record.dart';

abstract interface class FeedRepository {
  Stream<NotificationEvent> watch();

  Future<List<NotificationRecord>> activeNotifications();

  Future<bool> cancel(String key);
}
