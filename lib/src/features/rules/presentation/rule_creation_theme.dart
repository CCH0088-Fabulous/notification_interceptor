import 'package:flutter/material.dart';

import '../../../app/theme.dart';

/// Rule creation, editing and their dialogs use the same offline theme.
abstract final class RuleCreationTheme {
  static ThemeData build() => AppTheme.build();
}
