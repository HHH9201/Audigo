import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/audio_player_manager.dart';
import '../services/desktop_lifecycle_manager.dart';
import '../services/desktop_lyrics_manager.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _settingDefaults = <String, Object>{
    'audio_quality': '128k',
    'close_action': 'ask',
    'playback_volume': 0.5,
    'auto_play_next': true,
    'gapless_playback': true,
    'wifi_only_high_quality': false,
    'show_lyrics': true,
    'taskbar_lyrics': true,
    'download_lyrics': true,
    'save_history': true,
    'analytics_enabled': true,
    'start_minimized': false,
    'app_theme_mode': 0,
  };

  String _selectedQuality = '128k';
  String _closeAction = 'ask';
  double _volume = 0.5;
  bool _autoPlayNext = true;
  bool _gaplessPlayback = true;
  bool _wifiOnly = false;
  bool _showLyrics = true;
  bool _taskbarLyrics = true;
  bool _downloadLyrics = true;
  bool _saveHistory = true;
  bool _analytics = true;
  bool _startMinimized = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _selectedQuality = prefs.getString('audio_quality') ?? '128k';
      _closeAction = prefs.getString('close_action') ?? 'ask';
      _volume = prefs.getDouble('playback_volume') ?? 0.5;
      _autoPlayNext = prefs.getBool('auto_play_next') ?? true;
      _gaplessPlayback = prefs.getBool('gapless_playback') ?? true;
      _wifiOnly = prefs.getBool('wifi_only_high_quality') ?? false;
      _showLyrics = prefs.getBool('show_lyrics') ?? true;
      _taskbarLyrics = prefs.getBool('taskbar_lyrics') ?? true;
      _downloadLyrics = prefs.getBool('download_lyrics') ?? true;
      _saveHistory = prefs.getBool('save_history') ?? true;
      _analytics = prefs.getBool('analytics_enabled') ?? true;
      _startMinimized = prefs.getBool('start_minimized') ?? false;
    });
  }

  Future<void> _saveString(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  Future<void> _saveBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  Future<void> _saveQuality(String quality) async {
    await _saveString('audio_quality', quality);
    if (!mounted) return;
    setState(() => _selectedQuality = quality);
    await context.read<AudioPlayerManager>().reloadSettings();
  }

  Future<void> _saveVolume(double value) async {
    setState(() => _volume = value);
    context.read<AudioPlayerManager>().setVolume(value);
  }

  Future<void> _setSaveHistory(bool value) async {
    await _saveBool('save_history', value);
    if (!mounted) return;
    setState(() => _saveHistory = value);
  }

  Future<void> _savePlayerBool(
    String key,
    bool value,
    void Function() updateState,
  ) async {
    final player = context.read<AudioPlayerManager>();
    await _saveBool(key, value);
    if (!mounted) return;
    setState(updateState);
    await player.reloadSettings();
  }

  Future<void> _refreshControllers() async {
    final themeController = context.read<ThemeController>();
    final player = context.read<AudioPlayerManager>();
    await _loadSettings();
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final themeIndex = (prefs.getInt('app_theme_mode') ?? 0).clamp(
      0,
      AppThemeMode.values.length - 1,
    );
    await themeController.setMode(AppThemeMode.values[themeIndex]);
    if (!mounted) return;
    await player.reloadSettings();
  }

  Future<void> _exportSettings() async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出设置',
      fileName: 'musichub-settings.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (path == null || path.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final settings = <String, Object>{};
    for (final entry in _settingDefaults.entries) {
      settings[entry.key] = prefs.get(entry.key) ?? entry.value;
    }
    await File(path).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'settings': settings,
      }),
    );
    if (mounted) _showMessage('设置已导出');
  }

  bool _isValidSetting(String key, Object value) {
    return switch (key) {
      'audio_quality' => {'128k', '320k', 'flac'}.contains(value),
      'close_action' => {'ask', 'minimize', 'exit'}.contains(value),
      'playback_volume' => value is double && value >= 0 && value <= 1,
      'app_theme_mode' =>
        value is int && value >= 0 && value < AppThemeMode.values.length,
      _ => true,
    };
  }

  Future<void> _importSettings() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '导入设置',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = result?.files.single.path;
    if (path == null || path.isEmpty) return;
    try {
      final decoded = jsonDecode(await File(path).readAsString());
      if (decoded is! Map || decoded['settings'] is! Map) {
        throw const FormatException('无效的设置文件');
      }
      final imported = Map<String, dynamic>.from(decoded['settings'] as Map);
      final prefs = await SharedPreferences.getInstance();
      for (final entry in _settingDefaults.entries) {
        final value = imported[entry.key];
        if (value == null ||
            value.runtimeType != entry.value.runtimeType ||
            !_isValidSetting(entry.key, value)) {
          continue;
        }
        switch (value) {
          case bool boolValue:
            await prefs.setBool(entry.key, boolValue);
          case int intValue:
            await prefs.setInt(entry.key, intValue);
          case double doubleValue:
            await prefs.setDouble(entry.key, doubleValue);
          case String stringValue:
            await prefs.setString(entry.key, stringValue);
        }
      }
      await _refreshControllers();
      if (mounted) _showMessage('设置已导入');
    } on Object {
      if (mounted) _showMessage('设置文件无效或无法读取');
    }
  }

  Future<void> _resetSettings() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重置设置'),
        content: const Text('将所有偏好设置恢复为默认值，播放数据和账号信息不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final prefs = await SharedPreferences.getInstance();
    for (final key in _settingDefaults.keys) {
      await prefs.remove(key);
    }
    await _refreshControllers();
    if (mounted) _showMessage('设置已重置');
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _section(String title, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderWarm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgWarm,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          children: [
            Text(
              '偏好设置',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 20),
            _section('播放设置', [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自动播放下一首'),
                subtitle: const Text('当前歌曲结束后继续播放列表中的下一首'),
                value: _autoPlayNext,
                onChanged: (value) => _savePlayerBool(
                  'auto_play_next',
                  value,
                  () => _autoPlayNext = value,
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('无缝播放'),
                subtitle: const Text('连续播放时尽量减少歌曲之间的停顿'),
                value: _gaplessPlayback,
                onChanged: (value) => _savePlayerBool(
                  'gapless_playback',
                  value,
                  () => _gaplessPlayback = value,
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('默认音量'),
                subtitle: Slider(
                  value: _volume,
                  onChanged: _saveVolume,
                ),
                trailing: Text('${(_volume * 100).round()}%'),
              ),
            ]),
            _section('音质设置', [
              DropdownButtonFormField<String>(
                value: _selectedQuality,
                decoration: const InputDecoration(labelText: '流媒体音质'),
                items: const [
                  DropdownMenuItem(
                      value: '128k', child: Text('标准品质 (128Kbps)')),
                  DropdownMenuItem(
                      value: '320k', child: Text('高品质 HQ (320Kbps)')),
                  DropdownMenuItem(
                      value: 'flac', child: Text('无损品质 SQ (FLAC)')),
                ],
                onChanged: (value) {
                  if (value != null) _saveQuality(value);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('仅 Wi-Fi 使用高音质'),
                value: _wifiOnly,
                onChanged: (value) => _savePlayerBool(
                  'wifi_only_high_quality',
                  value,
                  () => _wifiOnly = value,
                ),
              ),
            ]),
            _section('界面设置', [
              DropdownButtonFormField<AppThemeMode>(
                value: context.watch<ThemeController>().mode,
                decoration: const InputDecoration(labelText: '界面主题'),
                items: const [
                  DropdownMenuItem(
                      value: AppThemeMode.light, child: Text('浅色')),
                  DropdownMenuItem(value: AppThemeMode.dark, child: Text('深色')),
                  DropdownMenuItem(
                      value: AppThemeMode.frosted, child: Text('磨砂')),
                  DropdownMenuItem(
                      value: AppThemeMode.frostedDark, child: Text('磨砂黑')),
                ],
                onChanged: (mode) {
                  if (mode != null) {
                    context.read<ThemeController>().setMode(mode);
                  }
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('显示歌词'),
                value: _showLyrics,
                onChanged: (value) => _savePlayerBool(
                  'show_lyrics',
                  value,
                  () => _showLyrics = value,
                ),
              ),
              if (DesktopLyricsManager.isSupported)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('桌面歌词'),
                  subtitle: const Text('显示透明置顶的独立逐字歌词窗口'),
                  value: _taskbarLyrics,
                  onChanged: (value) async {
                    await DesktopLyricsManager.instance.setEnabled(value);
                    await DesktopLifecycleManager.instance.refreshTrayMenu();
                    if (mounted) setState(() => _taskbarLyrics = value);
                  },
                ),
            ]),
            _section('下载设置', [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('下载歌曲时同时保存歌词'),
                value: _downloadLyrics,
                onChanged: (value) async {
                  await _saveBool('download_lyrics', value);
                  if (mounted) setState(() => _downloadLyrics = value);
                },
              ),
            ]),
            _section('应用行为', [
              DropdownButtonFormField<String>(
                value: _closeAction,
                decoration: const InputDecoration(labelText: '关闭窗口时'),
                items: const [
                  DropdownMenuItem(value: 'ask', child: Text('询问')),
                  DropdownMenuItem(value: 'minimize', child: Text('最小化到系统托盘')),
                  DropdownMenuItem(value: 'exit', child: Text('直接退出')),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  await _saveString('close_action', value);
                  if (mounted) setState(() => _closeAction = value);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启动时最小化'),
                value: _startMinimized,
                onChanged: (value) async {
                  await _saveBool('start_minimized', value);
                  if (mounted) setState(() => _startMinimized = value);
                },
              ),
            ]),
            _section('隐私设置', [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('保存播放历史'),
                value: _saveHistory,
                onChanged: _setSaveHistory,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('记录本地播放统计'),
                value: _analytics,
                onChanged: (value) async {
                  await _saveBool('analytics_enabled', value);
                  if (mounted) setState(() => _analytics = value);
                },
              ),
            ]),
            _section('设置数据', [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _importSettings,
                    icon: const Icon(Icons.file_upload_outlined),
                    label: const Text('导入'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _exportSettings,
                    icon: const Icon(Icons.file_download_outlined),
                    label: const Text('导出'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _resetSettings,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('重置'),
                  ),
                ],
              ),
            ]),
            _section('关于 MusicHub', const [
              Text('版本: 1.0.0'),
              SizedBox(height: 4),
              Text('作者: HJH'),
              SizedBox(height: 4),
              Text('GitHub: https://github.com/HHH9201/MusicHub'),
            ]),
          ],
        ),
      ),
    );
  }
}
