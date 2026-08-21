import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import '../services/audio_player_manager.dart';
import '../services/desktop_lifecycle_manager.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'discover_screen.dart';
import 'history_screen.dart';
import 'local_music_screen.dart';
import 'downloads_screen.dart';
import 'favorites_screen.dart';
import 'account_playlists_screen.dart';
import 'album_default_screen.dart';
import 'album_detail_screen.dart';
import 'settings_screen.dart';
import '../widgets/bottom_player_bar.dart';
import '../widgets/auth_dialog.dart';
import '../services/music_api_service.dart';

class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _NavigationState {
  final int pageIndex;
  final AlbumDetailDestination? detail;

  _NavigationState(this.pageIndex, {this.detail});
}

class _MainScaffoldState extends State<MainScaffold> {
  _NavigationState _navigationState = _NavigationState(0);
  final List<_NavigationState> _backStack = [];
  final List<_NavigationState> _forwardStack = [];
  final List<int> _pageVersions = List.filled(10, 0);

  int get _selectedIndex => _navigationState.pageIndex;
  String _searchQuery = '';
  bool _sidebarExpanded = true;
  bool _showRightSidebar = false;
  int _rightSidebarTab = 0; // 0: 播放列表, 1: 歌词
  bool _isLoggedIn = false;
  String? _userAvatar;

  @override
  void initState() {
    super.initState();
    _refreshUserStatus();
  }

  Future<void> _refreshUserStatus() async {
    final userRes = await MusicApiService.getUserDetail();
    if (mounted) {
      setState(() {
        if (userRes['success'] == true && userRes['data'] != null) {
          _isLoggedIn = true;
          _userAvatar = userRes['data']['pic'];
        } else {
          _isLoggedIn = false;
          _userAvatar = null;
        }
      });
    }
  }

  final TextEditingController _searchController = TextEditingController();

  void _navigateTo(int index) {
    if (index == _selectedIndex && _navigationState.detail == null) return;
    _navigateToState(_NavigationState(index));
  }

  void _openDetail(AlbumDetailDestination detail) {
    if (detail.id.isEmpty) return;
    _navigateToState(_NavigationState(_selectedIndex, detail: detail));
  }

  void _navigateToState(_NavigationState state) {
    setState(() {
      _backStack.add(_navigationState);
      _forwardStack.clear();
      _navigationState = state;
    });
  }

  void _goBack() {
    if (_backStack.isEmpty) return;
    setState(() {
      _forwardStack.add(_navigationState);
      _navigationState = _backStack.removeLast();
    });
  }

  void _goForward() {
    if (_forwardStack.isEmpty) return;
    setState(() {
      _backStack.add(_navigationState);
      _navigationState = _forwardStack.removeLast();
    });
  }

  Widget _buildCurrentPage() {
    final detail = _navigationState.detail;
    if (detail != null) {
      return AlbumDetailScreen(
        key: ValueKey(
          'detail-${detail.type}-${detail.id}-${_pageVersions[_selectedIndex]}',
        ),
        destination: detail,
        onBack: _goBack,
      );
    }

    final key = ValueKey('$_selectedIndex-${_pageVersions[_selectedIndex]}');
    switch (_selectedIndex) {
      case 0:
        return HomeScreen(key: key);
      case 1:
        return SearchScreen(
          key: key,
          initialQuery: _searchQuery,
          onOpenDetail: _openDetail,
        );
      case 2:
        return DiscoverScreen(key: key, onOpenDetail: _openDetail);
      case 3:
        return HistoryScreen(key: key);
      case 4:
        return LocalMusicScreen(key: key);
      case 5:
        return DownloadsScreen(key: key);
      case 6:
        return FavoritesScreen(key: key);
      case 7:
        return AccountPlaylistsScreen(key: key, onOpenDetail: _openDetail);
      case 8:
        return AlbumDefaultScreen(key: key);
      default:
        return SettingsScreen(key: key);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<AudioPlayerManager>();

    return Scaffold(
      backgroundColor: AppTheme.bgWarm,
      body: Column(
        children: [
          // 1. 顶部自定义标题栏 (完全等比复刻原版)
          _buildCustomTitleBar(context),

          // 2. 中间主体 (左侧导航栏 + 主内容区 + 可选右侧栏)
          Expanded(
            child: Row(
              children: [
                _buildSidebar(context),
                Expanded(
                  child: Container(
                    color: Colors.transparent,
                    child: _buildCurrentPage(),
                  ),
                ),
                if (_showRightSidebar &&
                    (_rightSidebarTab == 0 || player.showLyrics))
                  _buildRightSidebar(context, player),
              ],
            ),
          ),

          // 3. 底部固定播放栏 (完全等比复刻原版 80px 高度)
          BottomPlayerBar(
            onTogglePlaylist: () {
              setState(() {
                if (_showRightSidebar && _rightSidebarTab == 0) {
                  _showRightSidebar = false;
                } else {
                  _showRightSidebar = true;
                  _rightSidebarTab = 0;
                }
              });
            },
            onToggleLyrics: () {
              setState(() {
                if (_showRightSidebar && _rightSidebarTab == 1) {
                  _showRightSidebar = false;
                } else {
                  _showRightSidebar = true;
                  _rightSidebarTab = 1;
                }
              });
            },
          ),
        ],
      ),
    );
  }

  // 顶部导航栏
  Widget _buildCustomTitleBar(BuildContext context) {
    return GestureDetector(
      onPanStart: (details) {
        windowManager.startDragging();
      },
      onDoubleTap: () async {
        if (await windowManager.isMaximized()) {
          windowManager.unmaximize();
        } else {
          windowManager.maximize();
        }
      },
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: AppTheme.bgWarm,
          border: const Border(
              bottom: BorderSide(color: Color(0x15000000), width: 1)),
        ),
        child: Row(
          children: [
            // Logo
            Row(
              children: [
                Text(
                  "Music",
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.textPrimary,
                    letterSpacing: -0.5,
                  ),
                ),
                ShaderMask(
                  shaderCallback: (bounds) => const LinearGradient(
                    colors: [Color(0xFFE87A43), Color(0xFFFF955C)],
                  ).createShader(bounds),
                  child: const Text(
                    "Hub",
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 16),

            // 导航前进后退与主页刷新
            Row(
              children: [
                _buildTitleBtn(Icons.arrow_back, "后退", _goBack),
                _buildTitleBtn(Icons.arrow_forward, "前进", _goForward),
                _buildTitleBtn(Icons.home, "主页", () => _navigateTo(0)),
                _buildTitleBtn(Icons.sync, "刷新", () {
                  setState(() => _pageVersions[_selectedIndex]++);
                }),
              ],
            ),
            const SizedBox(width: 24),

            // 中间搜索栏
            Expanded(
              child: Center(
                child: Container(
                  width: 320,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0x15000000)),
                  ),
                  child: TextField(
                    controller: _searchController,
                    onSubmitted: (val) {
                      final query = val.trim();
                      if (query.isNotEmpty) {
                        if (_selectedIndex == 1 &&
                            _navigationState.detail == null &&
                            query == _searchQuery) {
                          setState(() => _pageVersions[1]++);
                        } else {
                          setState(() => _searchQuery = query);
                          _navigateTo(1);
                        }
                      }
                    },
                    decoration: InputDecoration(
                      hintText: "搜索...",
                      hintStyle: TextStyle(
                          fontSize: 13, color: AppTheme.textSecondary),
                      prefixIcon: Icon(Icons.search,
                          size: 16, color: AppTheme.textSecondary),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 7),
                    ),
                    style: TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                  ),
                ),
              ),
            ),

            // 右侧用户与设置按钮 + Windows 窗口控制三键
            Row(
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  width: 30,
                  height: 30,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    icon: _isLoggedIn &&
                            _userAvatar != null &&
                            _userAvatar!.isNotEmpty
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(15),
                            child: Image.network(_userAvatar!,
                                width: 24,
                                height: 24,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Icon(
                                    Icons.account_circle,
                                    size: 20,
                                    color: AppTheme.accentOrange)),
                          )
                        : Icon(Icons.account_circle_outlined,
                            size: 18,
                            color: AppTheme.textPrimary.withOpacity(0.75)),
                    tooltip: _isLoggedIn ? "用户信息" : "登录",
                    onPressed: () {
                      AuthDialog.show(context, () {
                        _refreshUserStatus();
                      });
                    },
                  ),
                ),
                _buildTitleBtn(
                  Icons.nightlight_round_outlined,
                  "切换主题",
                  () => context.read<ThemeController>().cycle(),
                ),
                _buildTitleBtn(
                  Icons.settings_outlined,
                  "设置",
                  () => _navigateTo(9),
                ),
                const SizedBox(width: 6),
                const SizedBox(
                  height: 14,
                  child: VerticalDivider(width: 1, color: Color(0x20000000)),
                ),
                const SizedBox(width: 6),
                // 窗口控制三键
                _buildTitleBtn(
                    Icons.remove, "最小化", () => windowManager.minimize()),
                _buildTitleBtn(Icons.crop_square, "最大化/还原", () async {
                  if (await windowManager.isMaximized()) {
                    windowManager.unmaximize();
                  } else {
                    windowManager.maximize();
                  }
                }),
                _buildTitleBtn(Icons.close, "关闭", _handleClose),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleClose() {
    return DesktopLifecycleManager.instance.requestClose();
  }

  Widget _buildTitleBtn(IconData icon, String tip, VoidCallback onTap) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      width: 30,
      height: 30,
      child: IconButton(
        padding: EdgeInsets.zero,
        icon:
            Icon(icon, size: 16, color: AppTheme.textPrimary.withOpacity(0.75)),
        tooltip: tip,
        onPressed: onTap,
      ),
    );
  }

  // 左侧导航栏
  Widget _buildSidebar(BuildContext context) {
    final width = _sidebarExpanded ? 160.0 : 64.0;

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: AppTheme.bgWarm,
        border:
            const Border(right: BorderSide(color: Color(0x15000000), width: 1)),
      ),
      child: Column(
        children: [
          // 展开/收缩按钮
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment:
                _sidebarExpanded ? Alignment.centerLeft : Alignment.center,
            child: Row(
              mainAxisAlignment: _sidebarExpanded
                  ? MainAxisAlignment.spaceBetween
                  : MainAxisAlignment.center,
              children: [
                if (_sidebarExpanded)
                  Text(
                    "音乐库",
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: Icon(_sidebarExpanded ? Icons.menu_open : Icons.menu,
                      size: 20, color: AppTheme.textSecondary),
                  onPressed: () =>
                      setState(() => _sidebarExpanded = !_sidebarExpanded),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0x10000000)),

          // 菜单列表
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              children: [
                _buildNavItem(0, Icons.home, "首页"),
                _buildNavItem(1, Icons.search, "搜索"),
                _buildNavItem(2, Icons.explore, "发现音乐"),
                _buildDivider(),
                _buildNavItem(3, Icons.history, "播放历史"),
                _buildNavItem(4, Icons.folder, "本地音乐"),
                _buildNavItem(5, Icons.cloud_download, "下载管理"),
                _buildDivider(),
                _buildNavItem(6, Icons.favorite, "我喜欢的"),
                _buildNavItem(7, Icons.star, "收藏的歌单"),
                _buildDivider(),
                _buildNavItem(8, Icons.album, "碟片"),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, String title) {
    final isSelected = _selectedIndex == index;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _navigateTo(index),
        child: Container(
          padding: EdgeInsets.symmetric(
            vertical: 10,
            horizontal: _sidebarExpanded ? 12 : 0,
          ),
          alignment: _sidebarExpanded ? Alignment.centerLeft : Alignment.center,
          decoration: BoxDecoration(
            color: isSelected ? const Color(0x1AE87A43) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: _sidebarExpanded
                ? MainAxisAlignment.start
                : MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color:
                    isSelected ? AppTheme.accentOrange : AppTheme.textSecondary,
              ),
              if (_sidebarExpanded) ...[
                const SizedBox(width: 10),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        isSelected ? FontWeight.w600 : FontWeight.normal,
                    color: isSelected
                        ? AppTheme.accentOrange
                        : AppTheme.textPrimary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 6),
      child: Divider(height: 1, color: Color(0x10000000)),
    );
  }

  // 右侧栏 (播放列表 & 歌词)
  Widget _buildRightSidebar(BuildContext context, AudioPlayerManager player) {
    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: AppTheme.bgWarm,
        border:
            const Border(left: BorderSide(color: Color(0x15000000), width: 1)),
      ),
      child: Column(
        children: [
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0x10000000))),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    InkWell(
                      onTap: () => setState(() => _rightSidebarTab = 0),
                      child: Text(
                        "播放列表",
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: _rightSidebarTab == 0
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: _rightSidebarTab == 0
                              ? AppTheme.accentOrange
                              : AppTheme.textSecondary,
                        ),
                      ),
                    ),
                    if (player.showLyrics) ...[
                      const SizedBox(width: 16),
                      InkWell(
                        onTap: () => setState(() => _rightSidebarTab = 1),
                        child: Text(
                          "歌词",
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: _rightSidebarTab == 1
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: _rightSidebarTab == 1
                                ? AppTheme.accentOrange
                                : AppTheme.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                IconButton(
                  icon: Icon(Icons.close,
                      size: 16, color: AppTheme.textSecondary),
                  onPressed: () => setState(() => _showRightSidebar = false),
                ),
              ],
            ),
          ),
          Expanded(
            child: _rightSidebarTab == 0
                ? _buildPlaylistView(player)
                : _buildMiniLyricView(player),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylistView(AudioPlayerManager player) {
    if (player.playlist.isEmpty) {
      return Center(
        child: Text("播放列表为空",
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
      );
    }
    return ListView.builder(
      itemCount: player.playlist.length,
      itemBuilder: (context, idx) {
        final song = player.playlist[idx];
        final isCurrent = player.currentSong?.hash == song.hash;
        return ListTile(
          dense: true,
          title: Text(
            song.songName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: isCurrent ? AppTheme.accentOrange : AppTheme.textPrimary,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          subtitle: Text(
            song.authorName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
          ),
          onTap: () => player.playSong(song),
        );
      },
    );
  }

  Widget _buildMiniLyricView(AudioPlayerManager player) {
    if (player.currentLyrics.isEmpty) {
      return Center(
        child: Text("暂无歌词",
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      itemCount: player.currentLyrics.length,
      itemBuilder: (context, idx) {
        final line = player.currentLyrics[idx];
        final isCurrent = idx == player.currentLyricIndex;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            line.text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: isCurrent ? 15 : 13,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent
                  ? AppTheme.accentOrange
                  : AppTheme.textSecondary.withOpacity(0.7),
            ),
          ),
        );
      },
    );
  }
}
