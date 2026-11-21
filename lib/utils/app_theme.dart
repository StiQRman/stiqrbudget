import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  final BuildContext context;
  AppColors(this.context);

  static AppColors of(BuildContext context) => AppColors(context);

  bool get isDark => Theme.of(context).brightness == Brightness.dark;

  // Backgrounds
  Color get scaffoldBg => isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC);
  Color get cardBg => isDark ? const Color(0xFF1E293B) : Colors.white;
  Color get surfaceSecondary => isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9);
  Color get modalBg => isDark ? const Color(0xFF1E293B) : Colors.white;

  // Borders & Dividers
  Color get border => isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
  Color get divider => isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);

  // Typography
  Color get textPrimary => isDark ? Colors.white : const Color(0xFF0F172A);
  Color get textSecondary => isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
  Color get textMuted => isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8);

  // Inputs
  Color get inputFill => isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC);
  Color get inputBorder => isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1);

  // Icons
  Color get iconPrimary => isDark ? Colors.white : const Color(0xFF0F172A);
  Color get iconSecondary => isDark ? Colors.white70 : const Color(0xFF475569);
  Color get iconMuted => isDark ? Colors.white60 : const Color(0xFF64748B);

  // Accents (Consistent across themes)
  Color get primary => const Color(0xFF6366F1); // Indigo
  Color get secondary => const Color(0xFF06B6D4); // Cyan
  Color get success => const Color(0xFF10B981); // Emerald
  Color get danger => const Color(0xFFEF4444); // Red
  Color get warning => const Color(0xFFF59E0B); // Amber
}

class AppTheme {
  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      primaryColor: const Color(0xFF6366F1),
      scaffoldBackgroundColor: const Color(0xFF0F172A),
      cardColor: const Color(0xFF1E293B),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF6366F1),
        secondary: Color(0xFF06B6D4),
        surface: Color(0xFF1E293B),
        onSurface: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF0F172A),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      textTheme: GoogleFonts.interTextTheme(
        ThemeData.dark().textTheme,
      ).copyWith(
        titleLarge: GoogleFonts.outfit(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
        bodyLarge: GoogleFonts.inter(
          color: Colors.white70,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF1E293B),
        labelStyle: GoogleFonts.inter(color: const Color(0xFF94A3B8)),
        floatingLabelStyle: GoogleFonts.inter(color: const Color(0xFF6366F1)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF334155)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF334155)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF6366F1), width: 2),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xFF1E293B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
    );
  }

  static ThemeData get lightTheme {
    return ThemeData(
      brightness: Brightness.light,
      primaryColor: const Color(0xFF6366F1),
      scaffoldBackgroundColor: const Color(0xFFF8FAFC),
      cardColor: Colors.white,
      colorScheme: const ColorScheme.light(
        primary: Color(0xFF6366F1),
        secondary: Color(0xFF06B6D4),
        surface: Colors.white,
        onSurface: Color(0xFF0F172A),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFF8FAFC),
        foregroundColor: Color(0xFF0F172A),
        elevation: 0,
      ),
      textTheme: GoogleFonts.interTextTheme(
        ThemeData.light().textTheme,
      ).copyWith(
        titleLarge: GoogleFonts.outfit(
          color: const Color(0xFF0F172A),
          fontWeight: FontWeight.bold,
        ),
        bodyLarge: GoogleFonts.inter(
          color: const Color(0xFF334155),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        labelStyle: GoogleFonts.inter(color: const Color(0xFF64748B)),
        floatingLabelStyle: GoogleFonts.inter(color: const Color(0xFF6366F1)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF6366F1), width: 2),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
    );
  }
}
