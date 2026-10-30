import 'package:flutter/material.dart';

class WfColors {
  static const primary = Color(0xFF2E7DFF);
  static const primaryDark = Color(0xFF1558C7);
  static const accent = Color(0xFF23C3A6);
  static const background = Color(0xFF0B1220);
  static const surface = Color(0xFF141C2B);
  static const surfaceLight = Color(0xFF1D2739);
  static const bubbleMine = Color(0xFF2E7DFF);
  static const bubbleTheirs = Color(0xFF1E2837);
  static const danger = Color(0xFFEF4444);
  static const warning = Color(0xFFF59E0B);
  static const textMuted = Color(0xFF8A97AB);
}

class WfTheme {
  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    final scheme = ColorScheme.fromSeed(
      seedColor: WfColors.primary,
      brightness: Brightness.dark,
    ).copyWith(
      primary: WfColors.primary,
      secondary: WfColors.accent,
      surface: WfColors.surface,
      error: WfColors.danger,
    );
    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: WfColors.background,
      canvasColor: WfColors.background,
      appBarTheme: const AppBarTheme(
        backgroundColor: WfColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white),
      ),
      cardTheme: CardTheme(
        color: WfColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: WfColors.surfaceLight,
        hintStyle: const TextStyle(color: WfColors.textMuted),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: WfColors.primary, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: WfColors.danger, width: 1.2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          side: const BorderSide(color: WfColors.surfaceLight),
          foregroundColor: Colors.white,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: WfColors.primary),
      ),
      dividerColor: Colors.white10,
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      listTileTheme: const ListTileThemeData(iconColor: Colors.white70),
    );
  }

  static ThemeData light() {
    final base = ThemeData.light(useMaterial3: true);
    return base.copyWith(
      colorScheme: ColorScheme.fromSeed(seedColor: WfColors.primary),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      ),
      appBarTheme: const AppBarTheme(centerTitle: false, elevation: 0),
    );
  }
}
