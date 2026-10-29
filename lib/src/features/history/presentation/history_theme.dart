import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// History and its routes share the generator's bundled Source Han Serif font.
abstract final class HistoryTheme {
  static const fontFamily = 'SourceHanSerifSC';
  static bool _licenseRegistered = false;

  static ThemeData build() {
    if (!_licenseRegistered) {
      LicenseRegistry.addLicense(() async* {
        yield LicenseEntryWithLineBreaks(
          ['Source Han Serif SC'],
          await rootBundle.loadString('assets/licenses/SourceHanSerif-OFL.txt'),
        );
      });
      _licenseRegistered = true;
    }
    const scheme = ColorScheme.light(
      primary: Colors.black,
      onPrimary: Colors.white,
      primaryContainer: Color(0xFFEAEAEA),
      onPrimaryContainer: Colors.black,
      secondary: Colors.black,
      onSecondary: Colors.white,
      secondaryContainer: Color(0xFFEAEAEA),
      onSecondaryContainer: Colors.black,
      tertiary: Color(0xFF555555),
      onTertiary: Colors.white,
      tertiaryContainer: Color(0xFFF2F2F2),
      onTertiaryContainer: Colors.black,
      error: Colors.black,
      onError: Colors.white,
      errorContainer: Colors.black,
      onErrorContainer: Colors.white,
      surface: Colors.white,
      onSurface: Colors.black,
      onSurfaceVariant: Color(0xFF666666),
      surfaceDim: Color(0xFFEEEEEE),
      surfaceBright: Colors.white,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: Colors.white,
      surfaceContainer: Color(0xFFFAFAFA),
      surfaceContainerHigh: Color(0xFFF4F4F4),
      surfaceContainerHighest: Color(0xFFEAEAEA),
      outline: Color(0xFF777777),
      outlineVariant: Color(0xFFCCCCCC),
      inverseSurface: Color(0xFF202020),
      onInverseSurface: Colors.white,
      inversePrimary: Colors.white,
      surfaceTint: Colors.transparent,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: Colors.white,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFFDDDDDD)),
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        indicatorColor: Color(0xFFEAEAEA),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFFAFAFA),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(9)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: Color(0xFFCCCCCC)),
        ),
      ),
      chipTheme: const ChipThemeData(
        selectedColor: Color(0xFFEAEAEA),
        backgroundColor: Colors.white,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      dropdownMenuTheme: const DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(Colors.white),
          surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
    );
  }
}
