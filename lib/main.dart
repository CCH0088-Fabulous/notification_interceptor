import 'package:flutter/material.dart';

import 'src/app/app.dart';
import 'src/core/channel/interceptor_channel.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(NotifInterceptorApp(channel: InterceptorChannel()));
}
