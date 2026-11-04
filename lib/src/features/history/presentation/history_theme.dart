import 'package:flutter/material.dart';

import '../../../app/theme.dart';

/// Compatibility entry point for history widgets using the shared app theme.
abstract final class HistoryTheme {
  static const fontFamily = AppTheme.fontFamily;

  static ThemeData build() => AppTheme.build();
}
