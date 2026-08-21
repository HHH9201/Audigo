import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';

class ThemeController extends ChangeNotifier {
  static const _preferenceKey = 'app_theme_mode';

  ThemeController._(this._mode) {
    AppTheme.apply(_mode);
  }

  AppThemeMode _mode;
  AppThemeMode get mode => _mode;
  ThemeData get theme => AppTheme.themeFor(_mode);

  static Future<ThemeController> load() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_preferenceKey) ?? 0;
    final safeIndex = index.clamp(0, AppThemeMode.values.length - 1);
    return ThemeController._(AppThemeMode.values[safeIndex]);
  }

  Future<void> setMode(AppThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    AppTheme.apply(mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_preferenceKey, mode.index);
    notifyListeners();
  }

  Future<void> cycle() {
    return setMode(
      AppThemeMode.values[(_mode.index + 1) % AppThemeMode.values.length],
    );
  }
}
