import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';

class ThemeController extends ChangeNotifier {
  static const _preferenceKey = 'app_theme_mode';

  ThemeController._(this._mode) {
    AppTheme.apply(_mode);
    WidgetsBinding.instance.platformDispatcher.onPlatformBrightnessChanged =
        _handleBrightnessChanged;
  }

  AppThemeMode _mode;
  AppThemeMode get mode => _mode;

  Brightness get _systemBrightness =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness;

  /// 解析后的实际主题模式（跟随系统时映射为明/暗）。
  AppThemeMode get resolvedMode =>
      AppTheme.resolveSystem(_mode, _systemBrightness);

  ThemeData get theme => AppTheme.themeFor(_mode, brightness: _systemBrightness);

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

  void _handleBrightnessChanged() {
    // 仅当处于“跟随系统”模式时，系统明暗变化才需要刷新主题。
    if (_mode == AppThemeMode.system) {
      AppTheme.apply(_mode);
      notifyListeners();
    }
  }

  Future<void> cycle() {
    return setMode(
      AppThemeMode.values[(_mode.index + 1) % AppThemeMode.values.length],
    );
  }
}
