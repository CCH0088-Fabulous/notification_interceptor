import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared by all interceptor pages and routes, using the generator's bundled font.
abstract final class AppTheme {
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
      visualDensity: VisualDensity.adaptivePlatformDensity,
      scaffoldBackgroundColor: Colors.white,
      canvasColor: Colors.white,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.white,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
          systemNavigationBarColor: Colors.white,
          systemNavigationBarIconBrightness: Brightness.dark,
        ),
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
        contentPadding: const EdgeInsets.all(15),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          minimumSize: const Size(48, 48),
        ),
      ),
      chipTheme: const ChipThemeData(
        showCheckmark: true,
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
      timePickerTheme: const TimePickerThemeData(
        backgroundColor: Colors.white,
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      dropdownMenuTheme: const DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(Colors.white),
          surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: Colors.black,
        contentTextStyle: TextStyle(
          fontFamily: fontFamily,
          color: Colors.white,
        ),
        actionTextColor: Colors.white,
      ),
      tooltipTheme: const TooltipThemeData(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
        textStyle: TextStyle(fontFamily: fontFamily, color: Colors.white),
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: Colors.black,
        selectionColor: Color(0xFFDDDDDD),
        selectionHandleColor: Colors.black,
      ),
    );
  }
}

/// The product keeps a white theme even when Android is in dark mode.
ThemeData buildAppTheme(Brightness brightness) => AppTheme.build();
