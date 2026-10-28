import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// 仅覆盖规则编辑路由，其余页面维持原样。
abstract final class RuleCreationTheme {
  static bool _licenseRegistered = false;

  static ThemeData build() {
    if (!_licenseRegistered) {
      LicenseRegistry.addLicense(() async* {
        yield LicenseEntryWithLineBreaks([
          'Noto Serif SC',
        ], await rootBundle.loadString('assets/licenses/NotoSerifSC-OFL.txt'));
      });
      _licenseRegistered = true;
    }
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: Colors.white,
      colorScheme: const ColorScheme.light(
        primary: Colors.black,
        onPrimary: Colors.white,
        secondary: Colors.black,
        onSecondary: Colors.white,
        secondaryContainer: Color(0xFFEAEAEA),
        onSecondaryContainer: Colors.black,
        surface: Colors.white,
        onSurface: Colors.black,
        surfaceTint: Colors.transparent,
        error: Colors.black,
        onError: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
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
    );
    // google_fonts directly downloads static font resources and caches them;
    // no notification text is sent to the font service.
    return base.copyWith(
      textTheme: GoogleFonts.notoSerifScTextTheme(base.textTheme),
    );
  }
}
