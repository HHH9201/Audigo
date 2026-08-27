import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/audio_player_manager.dart';
import '../services/desktop_lifecycle_manager.dart';
import '../services/desktop_lyrics_manager.dart';
import '../services/media_cache_service.dart';
import '../services/webdav_service.dart';
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
    'audio_quality': 'flac',
    'close_action': 'ask',
    'playback_volume': 1.0,
    'auto_play_next': true,
    'gapless_playback': true,
    'wifi_only_high_quality': false,
    'download_lyrics': true,
    'download_path': '',
    'lyrics_font_size': 22,
    'save_history': true,
    'analytics_enabled': true,
    'start_minimized': false,
    'app_theme_mode': 0,
  };

  String _selectedQuality = 'flac';
  String _closeAction = 'ask';
  double _volume = 1.0;
  bool _autoPlayNext = true;
  bool _gaplessPlayback = true;
  bool _wifiOnly = false;
  bool _cacheBeforePlay = true; // 先缓存整首再播放；关闭则直接流式播放
  bool _desktopLyrics = true;
  bool _lyricsNoBackground = false;
  bool _lyricsLocked = false;
  bool _lyricsGradient = true;
  bool _downloadLyrics = true;
  String _downloadPath = '';
  int _lyricsFontSize = 22;
  bool _saveHistory = true;
  bool _analytics = true;
  bool _deduping = false;
  bool _startMinimized = false;

  // 云盘同步（WebDAV）
  bool _webdavEnabled = false;
  bool _webdavAutoUpload = true;
  bool _webdavTesting = false;
  final TextEditingController _webdavUrlController = TextEditingController();
  final TextEditingController _webdavUserController = TextEditingController();
  final TextEditingController _webdavPassController = TextEditingController();
  final TextEditingController _webdavDirController = TextEditingController();

  // 数值输入控件（默认音量 / 歌词文字大小）
  final TextEditingController _volumeController = TextEditingController();
  final FocusNode _volumeFocus = FocusNode();
  final TextEditingController _lyricsFontSizeController =
      TextEditingController();
  final FocusNode _lyricsFontSizeFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadSettings();
    // 输入框失焦时提交数值（回车提交由 TextField 的 onSubmitted 处理）
    _volumeFocus.addListener(() {
      if (!_volumeFocus.hasFocus) _commitVolumeText();
    });
    _lyricsFontSizeFocus.addListener(() {
      if (!_lyricsFontSizeFocus.hasFocus) _commitLyricsFontSizeText();
    });
  }

  @override
  void dispose() {
    _volumeController.dispose();
    _volumeFocus.dispose();
    _lyricsFontSizeController.dispose();
    _lyricsFontSizeFocus.dispose();
    _webdavUrlController.dispose();
    _webdavUserController.dispose();
    _webdavPassController.dispose();
    _webdavDirController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _selectedQuality = prefs.getString('audio_quality') ?? 'flac';
      _closeAction = prefs.getString('close_action') ?? 'ask';
      _volume = prefs.getDouble('playback_volume') ?? 1.0;
      _autoPlayNext = prefs.getBool('auto_play_next') ?? true;
      _gaplessPlayback = prefs.getBool('gapless_playback') ?? true;
      _wifiOnly = prefs.getBool('wifi_only_high_quality') ?? false;
      _cacheBeforePlay = prefs.getBool('cache_before_play') ?? true;
      _desktopLyrics = prefs.getBool('desktop_lyrics') ?? true;
      _lyricsNoBackground =
          prefs.getBool('desktop_lyrics_no_background') ?? false;
      _lyricsLocked = prefs.getBool('desktop_lyrics_locked') ?? false;
      _lyricsGradient = prefs.getBool('desktop_lyrics_gradient') ?? true;
      _downloadLyrics = prefs.getBool('download_lyrics') ?? true;
      _downloadPath = prefs.getString('download_path') ?? '';
      _lyricsFontSize = prefs.getInt('lyrics_font_size') ?? 22;
      _saveHistory = prefs.getBool('save_history') ?? true;
      _analytics = prefs.getBool('analytics_enabled') ?? true;
      _startMinimized = prefs.getBool('start_minimized') ?? false;
      _webdavEnabled = prefs.getBool('webdav_enabled') ?? false;
      _webdavAutoUpload = prefs.getBool('webdav_auto_upload') ?? true;
    });
    // 同步数值输入框文本
    _volumeController.text = '${(_volume * 100).round()}';
    _lyricsFontSizeController.text = '$_lyricsFontSize';
    _webdavUrlController.text = prefs.getString('webdav_url') ?? '';
    _webdavUserController.text = prefs.getString('webdav_user') ?? '';
    _webdavPassController.text = prefs.getString('webdav_password') ?? '';
    _webdavDirController.text = prefs.getString('webdav_dir') ?? '/';
  }

  /// 保存云盘配置并让 WebDavService 重读。
  Future<void> _commitWebdavFields() async {
    await _saveString('webdav_url', _webdavUrlController.text.trim());
    await _saveString('webdav_user', _webdavUserController.text.trim());
    await _saveString('webdav_password', _webdavPassController.text);
    var dir = _webdavDirController.text.trim();
    if (dir.isEmpty) dir = '/';
    if (!dir.startsWith('/')) dir = '/$dir';
    await _saveString('webdav_dir', dir);
    await WebDavService.instance.reload();
  }

  Future<void> _testWebdavConnection() async {
    if (_webdavTesting) return;
    setState(() => _webdavTesting = true);
    try {
      // 先保存当前输入，确保测试的是最新配置。
      await _commitWebdavFields();
      await _saveBool('webdav_enabled', true);
      if (mounted) setState(() => _webdavEnabled = true);
      final error = await WebDavService.instance.testConnection();
      if (!mounted) return;
      _showMessage(error ?? '云盘连接成功');
      if (error != null) {
        // 测试失败时回退启用状态，避免半配置状态发起同步。
        await _saveBool('webdav_enabled', false);
        if (mounted) {
          setState(() => _webdavEnabled = false);
        }
      }
    } finally {
      if (mounted) setState(() => _webdavTesting = false);
    }
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

  /// 将歌词文字大小输入框的文本提交为 12-48 的字号。
  void _commitLyricsFontSizeText() {
    final parsed = int.tryParse(_lyricsFontSizeController.text.trim());
    final size = (parsed ?? _lyricsFontSize).clamp(12, 48);
    _lyricsFontSizeController.text = '$size';
    if (size == _lyricsFontSize) return;
    setState(() => _lyricsFontSize = size);
    _saveInt('lyrics_font_size', size)
        .then((_) => DesktopLyricsManager.instance.reloadLyricsWindow());
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

  

  

  /// 云盘同步配置行：左侧标签 + 右侧输入框（失焦或回车提交）。
  Widget _webdavFieldRow(
    String label,
    TextEditingController controller, {
    bool obscure = false,
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: obscure,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: hint,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
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
              ),
              onSubmitted: (_) => _commitWebdavFields(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionPlain(String title, List<Widget> children,
      {String? description}) {
    return _section(title, children, description: description);
  }

  /// 关于页信息行：图标 + 标签 + 值，左右对齐。
  Widget _aboutRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppTheme.textSecondary),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
        ],
      ),
    );
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
          '管理播放、音质、界面与下载等偏好，让拾音更贴合你的习惯。',
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
                        horizontal: true,
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
                      if (DesktopLyricsManager.isSupported) ...[
                        _settingCell(
                          icon: Icons.desktop_windows_rounded,
                          title: '桌面歌词',
                          horizontal: true,
                          control: Switch(
                            value: _desktopLyrics,
                            onChanged: (value) {
                              // 乐观更新：先让开关立即响应，再后台执行窗口操作
                              setState(() => _desktopLyrics = value);
                              DesktopLyricsManager.instance
                                  .setEnabled(value)
                                  .then((_) =>
                                      DesktopLifecycleManager.instance
                                          .refreshTrayMenu());
                            },
                          ),
                        ),
                        _settingCell(
                          icon: Icons.format_size_rounded,
                          title: '歌词大小',
                          horizontal: true,
                          control: _inputField(
                            _lyricsFontSizeController,
                            _lyricsFontSizeFocus,
                            _commitLyricsFontSizeText,
                          ),
                        ),
                        _settingCell(
                          icon: Icons.layers_clear_rounded,
                          title: '隐藏歌词背景',
                          horizontal: true,
                          control: Switch(
                            value: _lyricsNoBackground,
                            onChanged: (value) async {
                              setState(() => _lyricsNoBackground = value);
                              final prefs =
                                  await SharedPreferences.getInstance();
                              await prefs.setBool(
                                  'desktop_lyrics_no_background', value);
                              // 重新应用样式（透明背景 + 文字描边）。
                              await DesktopLyricsManager.instance
                                  .reloadSettings();
                            },
                          ),
                        ),
                        _settingCell(
                          icon: Icons.lock_rounded,
                          title: '锁定歌词位置',
                          horizontal: true,
                          control: Switch(
                            value: _lyricsLocked,
                            onChanged: (value) async {
                              setState(() => _lyricsLocked = value);
                              await DesktopLyricsManager.instance
                                  .setLocked(value);
                            },
                          ),
                        ),
                        _settingCell(
                          icon: Icons.gradient_rounded,
                          title: '逐字渐变填充',
                          horizontal: true,
                          control: Switch(
                            value: _lyricsGradient,
                            onChanged: (value) async {
                              setState(() => _lyricsGradient = value);
                              await DesktopLyricsManager.instance
                                  .setGradient(value);
                            },
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
                _section('云盘同步', [
                  _settingTile(
                    icon: Icons.cloud_outlined,
                    title: '启用云盘同步',
                    subtitle: '播放的歌曲与歌词自动备份到云盘，接口失败时从云盘兜底播放',
                    control: Switch(
                      value: _webdavEnabled,
                      onChanged: (value) async {
                        if (value && (_webdavUrlController.text.trim().isEmpty ||
                            _webdavUserController.text.trim().isEmpty ||
                            _webdavPassController.text.isEmpty)) {
                          _showMessage('请先填写服务器地址、账号与应用密码');
                          return;
                        }
                        await _commitWebdavFields();
                        await _saveBool('webdav_enabled', value);
                        if (mounted) setState(() => _webdavEnabled = value);
                      },
                    ),
                  ),
                  _webdavFieldRow('服务器地址', _webdavUrlController,
                      hint: 'https://webdav.123pan.cn/webdav'),
                  _webdavFieldRow('账号', _webdavUserController,
                      hint: '手机号或邮箱'),
                  _webdavFieldRow('应用密码', _webdavPassController,
                      obscure: true, hint: '云盘后台生成的应用密码'),
                  _webdavFieldRow('远端目录', _webdavDirController,
                      hint: '/ （即云盘授权目录）'),
                  _settingTile(
                    icon: Icons.cloud_upload_outlined,
                    title: '自动上传',
                    subtitle: '播放成功后自动把歌曲与歌词备份到云盘（已存在则跳过）',
                    control: Switch(
                      value: _webdavAutoUpload,
                      onChanged: (value) async {
                        await _saveBool('webdav_auto_upload', value);
                        if (mounted) {
                          setState(() => _webdavAutoUpload = value);
                        }
                      },
                    ),
                  ),
                  _settingTile(
                    icon: Icons.wifi_find_outlined,
                    title: '测试连接',
                    subtitle: '保存并验证当前云盘配置',
                    control: OutlinedButton(
                      onPressed:
                          _webdavTesting ? null : _testWebdavConnection,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: _webdavTesting
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('测试连接'),
                    ),
                  ),
                ], description: 'WebDAV 云盘（123 云盘等）：歌曲与歌词的备份与兜底播放'),
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
                _sectionPlain('关于拾音', [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceWarm,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        // 应用标识：图标 + 名称 + 标语
                        Row(
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    AppTheme.accentOrange,
                                    AppTheme.accentOrange.withOpacity(0.7),
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppTheme.accentOrange
                                        .withOpacity(0.3),
                                    blurRadius: 10,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.graphic_eq_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '拾音 AudiGo',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                      color: AppTheme.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '让声音随行',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        const Divider(height: 1),
                        const SizedBox(height: 6),
                        // 信息行：图标 + 标签 + 值
                        _aboutRow(Icons.dns_rounded, '版本', '1.0.0'),
                        _aboutRow(Icons.person_rounded, '作者', 'HJH'),
                        _aboutRow(
                            Icons.code_rounded, 'GitHub', 'HHH9201/AudiGo'),
                      ],
                    ),
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
