import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/audio_player_manager.dart';
import '../services/desktop_lifecycle_manager.dart';
import '../services/desktop_lyrics_manager.dart';
import '../services/media_cache_service.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../widgets/app_toast.dart';

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
    'download_path': '',
    'lyrics_font_size': 22,
    'lyrics_offset_x': 0,
    'lyrics_offset_y': 0,
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
  bool _cacheBeforePlay = true; // 先缓存整首再播放；关闭则直接流式播放
  bool _showLyrics = true;
  bool _taskbarLyrics = true;
  bool _downloadLyrics = true;
  String _downloadPath = '';
  int _lyricsFontSize = 22;
  int _lyricsOffsetX = 0;
  int _lyricsOffsetY = 0;
  bool _saveHistory = true;
  bool _analytics = true;
  bool _deduping = false;
  bool _startMinimized = false;

  // 数值输入控件（默认音量）
  final TextEditingController _volumeController = TextEditingController();
  final FocusNode _volumeFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadSettings();
    // 输入框失焦时提交数值（回车提交由 TextField 的 onSubmitted 处理）
    _volumeFocus.addListener(() {
      if (!_volumeFocus.hasFocus) _commitVolumeText();
    });
  }

  @override
  void dispose() {
    _volumeController.dispose();
    _volumeFocus.dispose();
    super.dispose();
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
      _cacheBeforePlay = prefs.getBool('cache_before_play') ?? true;
      _showLyrics = prefs.getBool('show_lyrics') ?? true;
      _taskbarLyrics = prefs.getBool('taskbar_lyrics') ?? true;
      _downloadLyrics = prefs.getBool('download_lyrics') ?? true;
      _downloadPath = prefs.getString('download_path') ?? '';
      _lyricsFontSize = prefs.getInt('lyrics_font_size') ?? 22;
      _lyricsOffsetX = prefs.getInt('lyrics_offset_x') ?? 0;
      _lyricsOffsetY = prefs.getInt('lyrics_offset_y') ?? 0;
      _saveHistory = prefs.getBool('save_history') ?? true;
      _analytics = prefs.getBool('analytics_enabled') ?? true;
      _startMinimized = prefs.getBool('start_minimized') ?? false;
    });
    // 同步数值输入框文本
    _volumeController.text = '${(_volume * 100).round()}';
  }

  Future<void> _saveString(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  Future<void> _saveBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  Future<void> _saveInt(String key, int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, value);
  }

  Future<void> _pickDownloadPath() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择下载目录',
    );
    if (path == null || path.isEmpty) return;
    final directoryExists = await Directory(path).exists();
    if (!directoryExists) {
      _showMessage('文件夹不存在，请重新选择');
      return;
    }
    await _saveString('download_path', path);
    if (!mounted) return;
    setState(() => _downloadPath = path);
    _showMessage('下载路径已更新');
  }

  Future<void> _saveQuality(String quality) async {
    await _saveString('audio_quality', quality);
    if (!mounted) return;
    setState(() => _selectedQuality = quality);
    await context.read<AudioPlayerManager>().reloadSettings();
  }

  Future<void> _dedupeCache() async {
    if (_deduping) return;
    setState(() => _deduping = true);
    try {
      final cache = await MediaCacheService.instance;
      final freed = await cache.dedupeAudioCache();
      if (!mounted) return;
      _showMessage(
          '已去重，释放 ${(freed / (1024 * 1024)).toStringAsFixed(1)} MB');
    } finally {
      if (mounted) setState(() => _deduping = false);
    }
  }

  Future<void> _saveVolume(double value) async {
    setState(() => _volume = value);
    context.read<AudioPlayerManager>().setVolume(value);
  }

  /// 将默认音量输入框的文本提交为 0-100 的百分比。
  void _commitVolumeText() {
    final parsed = int.tryParse(_volumeController.text.trim());
    final percent = (parsed ?? (_volume * 100).round()).clamp(0, 100);
    _volumeController.text = '$percent';
    _saveVolume(percent / 100);
  }

  Future<void> _setOffsetX(int value) async {
    final clamped = value.clamp(-300, 300);
    setState(() => _lyricsOffsetX = clamped);
    await _saveInt('lyrics_offset_x', clamped);
    await DesktopLyricsManager.instance.reloadLyricsWindow();
  }

  Future<void> _setOffsetY(int value) async {
    final clamped = value.clamp(-60, 60);
    setState(() => _lyricsOffsetY = clamped);
    await _saveInt('lyrics_offset_y', clamped);
    await DesktopLyricsManager.instance.reloadLyricsWindow();
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

  void _showMessage(String message) {
    AppToast.show(context, message);
  }

  /// Section 标题 + 描述
  Widget _sectionHeader(String title, [String? description]) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
              color: AppTheme.textPrimary,
            ),
          ),
          if (description != null) ...[
            const SizedBox(height: 3),
            Text(
              description,
              style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  /// 分组容器：一个整体圆角卡片，内部用细分割线连接各设置项
  Widget _groupCard(List<Widget> children) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderWarm),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: List.generate(children.length * 2 - 1, (i) {
          if (i.isEven) return children[i ~/ 2];
          return Divider(
            height: 1,
            thickness: 1,
            indent: 16,
            endIndent: 16,
            color: AppTheme.borderWarm,
          );
        }),
      ),
    );
  }

  /// 统一的分组 Section（标题 + 描述 + 分组列表）
  Widget _section(String title, List<Widget> children, {String? description}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(title, description),
          _groupCard(children),
        ],
      ),
    );
  }

  /// 行式设置项：左侧信息（轻图标 + 名称 + 说明），右侧控件
  Widget _settingTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required Widget control,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Icon(
              icon,
              size: 17,
              color: AppTheme.textSecondary.withOpacity(0.7),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            control,
          ],
        ),
      ),
    );
  }

  /// 设置项单元格。默认"文字在上、控件在下"；[horizontal] 为 true 时
  /// 改为"文字在左、控件在右"（用于开关类控件）。
  Widget _settingCell({
    required IconData icon,
    required String title,
    String? subtitle,
    required Widget control,
    bool horizontal = false,
  }) {
    if (horizontal) {
      return Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        decoration: BoxDecoration(
          color: AppTheme.surfaceWarm,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 15,
              color: AppTheme.textSecondary.withOpacity(0.7),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.3,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            control,
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceWarm,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 15,
                color: AppTheme.textSecondary.withOpacity(0.7),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 3),
            Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.3,
                color: AppTheme.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Align(alignment: Alignment.centerLeft, child: control),
        ],
      ),
    );
  }

  /// 一排三个的网格容器
  Widget _gridOfThree(List<Widget> cells) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellWidth = (constraints.maxWidth - 24) / 3;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final cell in cells)
              SizedBox(width: cellWidth, child: cell),
          ],
        );
      },
    );
  }

  /// 纯数字输入框（回车或失焦提交）。
  Widget _inputField(
    TextEditingController controller,
    FocusNode focusNode,
    VoidCallback onCommit, {
    String? suffix,
    double width = 92,
  }) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppTheme.borderWarm),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppTheme.accentOrange),
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppTheme.borderWarm),
          ),
          suffixText: suffix,
        ),
        onSubmitted: (_) => onCommit(),
      ),
    );
  }

  

  

  Widget _sectionPlain(String title, List<Widget> children,
      {String? description}) {
    return _section(title, children, description: description);
  }

  /// 页面顶部：简洁标题 + 说明。
  Widget _buildPageHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.tune_rounded, size: 22, color: AppTheme.accentOrange),
            const SizedBox(width: 10),
            Text(
              '偏好设置',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: AppTheme.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '管理播放、音质、界面与下载等偏好，让 MusicHub 更贴合你的习惯。',
          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgWarm,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              children: [
                _buildPageHeader(),
                _section('播放设置', [
                  _settingTile(
                    icon: Icons.playlist_play_rounded,
                    title: '自动播放下一首',
                    subtitle: '当前歌曲结束后继续播放列表中的下一首',
                    control: Switch(
                      value: _autoPlayNext,
                      onChanged: (value) => _savePlayerBool(
                        'auto_play_next',
                        value,
                        () => _autoPlayNext = value,
                      ),
                    ),
                  ),
                  _settingTile(
                    icon: Icons.waves_rounded,
                    title: '无缝播放',
                    subtitle: '连续播放时尽量减少歌曲之间的停顿',
                    control: Switch(
                      value: _gaplessPlayback,
                      onChanged: (value) => _savePlayerBool(
                        'gapless_playback',
                        value,
                        () => _gaplessPlayback = value,
                      ),
                    ),
                  ),
                  _settingTile(
                    icon: Icons.volume_up_rounded,
                    title: '默认音量',
                    subtitle: '0 - 100%',
                    control: _inputField(
                      _volumeController,
                      _volumeFocus,
                      _commitVolumeText,
                      suffix: '%',
                    ),
                  ),
                ], description: '控制播放行为与默认音量'),
                _section('音质设置', [
                  _settingTile(
                    icon: Icons.high_quality_rounded,
                    title: '流媒体音质',
                    subtitle: '当前播放的音频清晰度',
                    control: DropdownButton<String>(
                      value: _selectedQuality,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(
                            value: '128k', child: Text('标准品质 (128K)')),
                        DropdownMenuItem(
                            value: '320k', child: Text('高品质 HQ (320K)')),
                        DropdownMenuItem(
                            value: 'flac', child: Text('无损品质 SQ (FLAC)')),
                      ],
                      onChanged: (value) {
                        if (value != null) _saveQuality(value);
                      },
                    ),
                  ),
                  _settingTile(
                    icon: Icons.wifi_rounded,
                    title: '仅 Wi-Fi 使用高音质',
                    control: Switch(
                      value: _wifiOnly,
                      onChanged: (value) => _savePlayerBool(
                        'wifi_only_high_quality',
                        value,
                        () => _wifiOnly = value,
                      ),
                    ),
                  ),
                  _settingTile(
                    icon: Icons.sd_storage_rounded,
                    title: '先缓存整首再播放',
                    subtitle:
                        '开启：播放前将整首缓存到本地再播，启动更稳、断网可续。'
                        '关闭：获取 URL 后直接流式播放，不落整首缓存。',
                    control: Switch(
                      value: _cacheBeforePlay,
                      onChanged: (value) => _savePlayerBool(
                        'cache_before_play',
                        value,
                        () => _cacheBeforePlay = value,
                      ),
                    ),
                  ),
                  _settingTile(
                    icon: Icons.cleaning_services_rounded,
                    title: '去重缓存（只留最高音质）',
                    subtitle: '同一首歌的低音质缓存会被删除，仅保留质量最高的一份',
                    control: OutlinedButton(
                      onPressed: _deduping ? null : _dedupeCache,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(88, 36),
                        padding:
                            const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      child: Text(_deduping ? '去重中...' : '去重'),
                    ),
                  ),
                ], description: '在线播放码率与缓存策略'),
                _section('界面设置', [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: _gridOfThree([
                      _settingCell(
                        icon: Icons.palette_rounded,
                        title: '界面主题',
                        control: DropdownButton<AppThemeMode>(
                          value: context.watch<ThemeController>().mode,
                          underline: const SizedBox.shrink(),
                          isDense: true,
                          items: const [
                            DropdownMenuItem(
                                value: AppThemeMode.system, child: Text('跟随系统')),
                            DropdownMenuItem(
                                value: AppThemeMode.light, child: Text('浅色')),
                            DropdownMenuItem(
                                value: AppThemeMode.dark, child: Text('深色')),
                            DropdownMenuItem(
                                value: AppThemeMode.frosted, child: Text('磨砂')),
                            DropdownMenuItem(
                                value: AppThemeMode.frostedDark,
                                child: Text('磨砂黑')),
                          ],
                          onChanged: (mode) {
                            if (mode != null) {
                              context.read<ThemeController>().setMode(mode);
                            }
                          },
                        ),
                      ),
                      _settingCell(
                        icon: Icons.lyrics_rounded,
                        title: '显示歌词',
                        horizontal: true,
                        control: Switch(
                          value: _showLyrics,
                          onChanged: (value) => _savePlayerBool(
                            'show_lyrics',
                            value,
                            () => _showLyrics = value,
                          ),
                        ),
                      ),
                      if (DesktopLyricsManager.isSupported) ...[
                        _settingCell(
                          icon: Icons.desktop_windows_rounded,
                          title: '桌面歌词',
                          subtitle: '透明置顶的独立逐字歌词窗口',
                          horizontal: true,
                          control: Switch(
                            value: _taskbarLyrics,
                            onChanged: (value) async {
                              await DesktopLyricsManager.instance
                                  .setEnabled(value);
                              await DesktopLifecycleManager.instance
                                  .refreshTrayMenu();
                              if (mounted) {
                                setState(() => _taskbarLyrics = value);
                              }
                            },
                          ),
                        ),
                        _settingCell(
                          icon: Icons.format_size_rounded,
                          title: '歌词文字大小',
                          subtitle: '12 - 48',
                          horizontal: true,
                          control: SliderTheme(
                            data: SliderThemeData(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 5),
                              activeTrackColor: AppTheme.accentOrange,
                              inactiveTrackColor: AppTheme.borderWarm,
                              thumbColor: AppTheme.accentOrange,
                            ),
                            child: Slider(
                              value: _lyricsFontSize.toDouble(),
                              min: 12,
                              max: 48,
                              divisions: 36,
                              label: '$_lyricsFontSize',
                              onChanged: (value) async {
                                final size = value.round();
                                setState(() => _lyricsFontSize = size);
                                await _saveInt('lyrics_font_size', size);
                                await DesktopLyricsManager.instance
                                    .reloadLyricsWindow();
                              },
                            ),
                          ),
                        ),
                        _settingCell(
                          icon: Icons.swap_horiz_rounded,
                          title: '桌面歌词水平位置',
                          subtitle: '-300 ~ 300',
                          horizontal: true,
                          control: SliderTheme(
                            data: SliderThemeData(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 5),
                              activeTrackColor: AppTheme.accentOrange,
                              inactiveTrackColor: AppTheme.borderWarm,
                              thumbColor: AppTheme.accentOrange,
                            ),
                            child: Slider(
                              value: _lyricsOffsetX.toDouble(),
                              min: -300,
                              max: 300,
                              divisions: 600,
                              label: '$_lyricsOffsetX',
                              onChanged: (value) async {
                                final offset = value.round();
                                setState(() => _lyricsOffsetX = offset);
                                await _setOffsetX(offset);
                              },
                            ),
                          ),
                        ),
                        _settingCell(
                          icon: Icons.swap_vert_rounded,
                          title: '桌面歌词垂直位置',
                          subtitle: '-60 ~ 60',
                          horizontal: true,
                          control: SliderTheme(
                            data: SliderThemeData(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 5),
                              activeTrackColor: AppTheme.accentOrange,
                              inactiveTrackColor: AppTheme.borderWarm,
                              thumbColor: AppTheme.accentOrange,
                            ),
                            child: Slider(
                              value: _lyricsOffsetY.toDouble(),
                              min: -60,
                              max: 60,
                              divisions: 120,
                              label: '$_lyricsOffsetY',
                              onChanged: (value) async {
                                final offset = value.round();
                                setState(() => _lyricsOffsetY = offset);
                                await _setOffsetY(offset);
                              },
                            ),
                          ),
                        ),
                      ],
                    ]),
                  ),
                ], description: '主题、歌词显示与桌面歌词'),
                _section('下载设置', [
                  _settingTile(
                    icon: Icons.download_rounded,
                    title: '下载歌曲时同时保存歌词',
                    control: Switch(
                      value: _downloadLyrics,
                      onChanged: (value) async {
                        await _saveBool('download_lyrics', value);
                        if (mounted) setState(() => _downloadLyrics = value);
                      },
                    ),
                  ),
                  _settingTile(
                    icon: Icons.folder_rounded,
                    title: '下载路径',
                    subtitle:
                        _downloadPath.isEmpty ? '默认：每次下载时选择' : _downloadPath,
                    control: OutlinedButton(
                      onPressed: _pickDownloadPath,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('选择文件夹'),
                    ),
                  ),
                ], description: '下载时的歌词与存储位置'),
                _section('应用行为', [
                  _settingTile(
                    icon: Icons.power_settings_new_rounded,
                    title: '关闭窗口时',
                    control: DropdownButton<String>(
                      value: _closeAction,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(value: 'ask', child: Text('询问')),
                        DropdownMenuItem(
                            value: 'minimize', child: Text('最小化到系统托盘')),
                        DropdownMenuItem(value: 'exit', child: Text('直接退出')),
                      ],
                      onChanged: (value) async {
                        if (value == null) return;
                        await _saveString('close_action', value);
                        if (mounted) setState(() => _closeAction = value);
                      },
                    ),
                  ),
                  _settingTile(
                    icon: Icons.minimize_rounded,
                    title: '启动时最小化',
                    control: Switch(
                      value: _startMinimized,
                      onChanged: (value) async {
                        await _saveBool('start_minimized', value);
                        if (mounted) setState(() => _startMinimized = value);
                      },
                    ),
                  ),
                ], description: '窗口关闭与启动行为'),
                _section('隐私设置', [
                  _settingTile(
                    icon: Icons.history_rounded,
                    title: '保存播放历史',
                    control: Switch(
                      value: _saveHistory,
                      onChanged: _setSaveHistory,
                    ),
                  ),
                  _settingTile(
                    icon: Icons.bar_chart_rounded,
                    title: '记录本地播放统计',
                    control: Switch(
                      value: _analytics,
                      onChanged: (value) async {
                        await _saveBool('analytics_enabled', value);
                        if (mounted) setState(() => _analytics = value);
                      },
                    ),
                  ),
                ], description: '本地数据记录开关'),
                _sectionPlain('关于 MusicHub', [
                  Text(
                    '版本: 1.0.0',
                    style:
                        TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '作者: HJH',
                    style:
                        TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'GitHub: https://github.com/HHH9201/MusicHub',
                    style:
                        TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                  ),
                ], description: '应用版本与项目信息'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
