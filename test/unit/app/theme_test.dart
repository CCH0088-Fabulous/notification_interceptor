import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifinterceptor/src/app/theme.dart';
import 'package:notifinterceptor/src/features/history/presentation/history_theme.dart';
import 'package:notifinterceptor/src/features/rules/presentation/rule_creation_theme.dart';

void main() {
  test('all entry points share the offline monochrome theme in dark mode', () {
    final theme = AppTheme.build();
    expect(HistoryTheme.build(), theme);
    expect(RuleCreationTheme.build(), theme);
    expect(buildAppTheme(Brightness.dark), theme);
    expect(theme.brightness, Brightness.light);
    expect(theme.scaffoldBackgroundColor, Colors.white);
    expect(theme.colorScheme.primary, Colors.black);
    expect(theme.colorScheme.onSurface, Colors.black);
    expect(theme.dialogTheme.backgroundColor, Colors.white);
    expect(theme.timePickerTheme.backgroundColor, Colors.white);
    expect(theme.bottomSheetTheme.backgroundColor, Colors.white);
    expect(theme.popupMenuTheme.color, Colors.white);
    expect(theme.navigationBarTheme.backgroundColor, Colors.white);
    for (final style in [
      theme.textTheme.displayLarge,
      theme.textTheme.headlineLarge,
      theme.textTheme.titleLarge,
      theme.textTheme.titleMedium,
      theme.textTheme.bodyLarge,
      theme.textTheme.bodyMedium,
      theme.textTheme.labelLarge,
      theme.snackBarTheme.contentTextStyle,
      theme.tooltipTheme.textStyle,
    ]) {
      expect(style?.fontFamily, AppTheme.fontFamily);
    }
  });
}
