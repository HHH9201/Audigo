import 'package:flutter/material.dart';

enum AppThemeMode { system, light, dark, frosted, frostedDark }

class AppTheme {
  static _ThemePalette _palette = _ThemePalette.light;

  static Color get bgWarm => _palette.background;
  static Color get surfaceWhite => _palette.surface;
  static Color get surfaceWarm => _palette.surfaceVariant;
  static Color get accentOrange => _palette.accent;
  static Color get textPrimary => _palette.textPrimary;
  static Color get textSecondary => _palette.textSecondary;
  static Color get borderWarm => _palette.border;

  static ThemeData get lightTheme => themeFor(AppThemeMode.light);

  static void apply(AppThemeMode mode) {
    _palette = _paletteFor(mode);
  }

  /// 将“跟随系统”解析为具体明暗主题。
  static AppThemeMode resolveSystem(AppThemeMode mode, Brightness brightness) {
    if (mode != AppThemeMode.system) return mode;
    return brightness == Brightness.dark
        ? AppThemeMode.dark
        : AppThemeMode.light;
  }

  static _ThemePalette _paletteFor(AppThemeMode mode,
      {Brightness brightness = Brightness.light}) {
    final resolved = resolveSystem(mode, brightness);
    return switch (resolved) {
      AppThemeMode.light => _ThemePalette.light,
      AppThemeMode.dark => _ThemePalette.dark,
      AppThemeMode.frosted => _ThemePalette.frosted,
      AppThemeMode.frostedDark => _ThemePalette.frostedDark,
      AppThemeMode.system =>
        brightness == Brightness.dark
            ? _ThemePalette.dark
            : _ThemePalette.light,
    };
  }

  static ThemeData themeFor(AppThemeMode mode,
      {Brightness brightness = Brightness.light}) {
    final palette = _paletteFor(mode, brightness: brightness);
    final resolved = resolveSystem(mode, brightness);
    final effectiveBrightness =
        resolved == AppThemeMode.dark || resolved == AppThemeMode.frostedDark
            ? Brightness.dark
            : Brightness.light;
    return ThemeData(
      useMaterial3: true,
      brightness: effectiveBrightness,
      scaffoldBackgroundColor: palette.background,
      primaryColor: palette.accent,
      colorScheme: ColorScheme.fromSeed(
        seedColor: palette.accent,
        brightness: effectiveBrightness,
        primary: palette.accent,
        surface: palette.surface,
        onSurface: palette.textPrimary,
      ),
      fontFamilyFallback: const [
        'Segoe UI',
        'Microsoft YaHei',
        'PingFang SC',
        'sans-serif',
      ],
      cardTheme: CardThemeData(
        color: palette.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: palette.border),
        ),
      ),
      dividerColor: palette.border,
      dialogTheme: DialogThemeData(backgroundColor: palette.surface),
      inputDecorationTheme:
          InputDecorationTheme(fillColor: palette.surfaceVariant),
    );
  }
}

class _ThemePalette {
  const _ThemePalette({
    required this.background,
    required this.surface,
    required this.surfaceVariant,
    required this.accent,
    required this.textPrimary,
    required this.textSecondary,
    required this.border,
    required this.isDark,
  });

  final Color background;
  final Color surface;
  final Color surfaceVariant;
  final Color accent;
  final Color textPrimary;
  final Color textSecondary;
  final Color border;
  final bool isDark;

  static const light = _ThemePalette(
    background: Color(0xFFFCF9F6),
    surface: Color(0xFFFFFFFF),
    surfaceVariant: Color(0xFFF7F4F0),
    accent: Color(0xFFE87A43),
    textPrimary: Color(0xFF111827),
    textSecondary: Color(0xFF64748B),
    border: Color(0xFFF3EFEA),
    isDark: false,
  );
  static const dark = _ThemePalette(
    background: Color(0xFF0F172A),
    surface: Color(0xFF1E293B),
    surfaceVariant: Color(0xFF334155),
    accent: Color(0xFF8B5CF6),
    textPrimary: Color(0xFFF8FAFC),
    textSecondary: Color(0xFFCBD5E1),
    border: Color(0xFF475569),
    isDark: true,
  );
  static const frosted = _ThemePalette(
    background: Color(0xFFEFF0F5),
    surface: Color(0xFFF9F9FC),
    surfaceVariant: Color(0xFFE7E8F0),
    accent: Color(0xFF6366F1),
    textPrimary: Color(0xFF141419),
    textSecondary: Color(0xFF626273),
    border: Color(0xFFD8DAE5),
    isDark: false,
  );
  static const frostedDark = _ThemePalette(
    background: Color(0xFF0F0F14),
    surface: Color(0xFF19191F),
    surfaceVariant: Color(0xFF24242C),
    accent: Color(0xFF8B5CF6),
    textPrimary: Color(0xFFF0F0F5),
    textSecondary: Color(0xFFB5B5C3),
    border: Color(0xFF34343E),
    isDark: true,
  );
}
