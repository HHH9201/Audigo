import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../services/audio_player_manager.dart';
import '../services/music_api_service.dart';
import '../services/search_history_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_toast.dart';
import 'album_detail_screen.dart';

class SearchScreen extends StatefulWidget {
  final String initialQuery;
  final ValueChanged<AlbumDetailDestination> onOpenDetail;

  const SearchScreen({
    super.key,
    this.initialQuery = '',
    required this.onOpenDetail,
  });

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with SingleTickerProviderStateMixin {
  static int _pageSize = 30;
  static const _tabs = ['歌曲', '歌手', '专辑', '歌单', 'MV'];

  final TextEditingController _controller = TextEditingController();
  final Set<String> _downloadingHashes = {};
  late final TabController _tabController;
  Timer? _suggestionTimer;

  List<String> _searchHistory = [];
  List<HotSearchCategory> _hotSearch = [];
  List<SearchSuggestion> _suggestions = [];
  List<Song> _songs = [];
  List<Map<String, dynamic>> _artists = [];
  List<Map<String, dynamic>> _albums = [];
  List<Map<String, dynamic>> _playlists = [];
  List<Map<String, dynamic>> _mvs = [];
  final List<int> _totals = List.filled(5, 0);
  final List<int> _pages = List.filled(5, 1);
  final List<bool> _loadingMore = List.filled(5, false);
  bool _isSearching = false;
  bool _isHotSearchLoading = true;
  int _searchGeneration = 0;
  String _activeQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _controller.addListener(_onQueryChanged);
    _loadSearchHistory();
    _loadHotSearch();
    _applyInitialQuery();
  }

  Future<void> _loadSearchHistory() async {
    final history = await SearchHistoryService.load();
    if (!mounted) return;
    setState(() => _searchHistory = history);
  }

  @override
  void didUpdateWidget(covariant SearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialQuery != oldWidget.initialQuery) _applyInitialQuery();
  }

  void _applyInitialQuery() {
    final query = widget.initialQuery.trim();
    if (query.isEmpty) return;
    _controller.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    _doSearch(query);
  }

  Future<void> _loadHotSearch() async {
    final categories = await MusicApiService.getHotSearch();
    if (!mounted) return;
    setState(() {
      _hotSearch = categories;
      _isHotSearchLoading = false;
    });
  }

  void _onQueryChanged() {
    _suggestionTimer?.cancel();
    final query = _controller.text.trim();
    if (query.isEmpty) {
      setState(() {
        _suggestions = [];
        _activeQuery = '';
      });
      return;
    }
    setState(() {});
    _suggestionTimer = Timer(const Duration(milliseconds: 300), () async {
      final suggestions = await MusicApiService.getSearchSuggestions(query);
      if (!mounted || _controller.text.trim() != query) return;
      setState(() => _suggestions = suggestions.take(10).toList());
    });
  }

  Future<void> _doSearch(String keyword) async {
    final query = keyword.trim();
    if (query.isEmpty) return;
    _suggestionTimer?.cancel();
    FocusScope.of(context).unfocus();
    // 记录搜索历史
    final history = await SearchHistoryService.add(query);
    if (mounted) setState(() => _searchHistory = history);
    final generation = ++_searchGeneration;
    setState(() {
      _activeQuery = query;
      _suggestions = [];
      _isSearching = true;
      for (var i = 0; i < 5; i++) {
        _pages[i] = 1;
        _totals[i] = 0;
        _loadingMore[i] = false;
      }
    });

    final results = await Future.wait<dynamic>([
      MusicApiService.searchSongPage(query, pageSize: _pageSize),
      MusicApiService.searchArtists(query, pageSize: _pageSize),
      MusicApiService.searchAlbums(query, pageSize: _pageSize),
      MusicApiService.searchPlaylists(query, pageSize: _pageSize),
      MusicApiService.searchMVs(query, pageSize: _pageSize),
    ]);
    if (!mounted || query != _activeQuery || generation != _searchGeneration) {
      return;
    }
    setState(() {
      final songs = results[0] as SearchPage<Song>;
      final artists = results[1] as SearchPage<Map<String, dynamic>>;
      final albums = results[2] as SearchPage<Map<String, dynamic>>;
      final playlists = results[3] as SearchPage<Map<String, dynamic>>;
      final mvs = results[4] as SearchPage<Map<String, dynamic>>;
      _songs = songs.items;
      _artists = artists.items;
      _albums = albums.items;
      _playlists = playlists.items;
      _mvs = mvs.items;
      _totals
        ..[0] = songs.total
        ..[1] = artists.total
        ..[2] = albums.total
        ..[3] = playlists.total
        ..[4] = mvs.total;
      _isSearching = false;
    });
  }

  Future<void> _loadMore(int index) async {
    if (_loadingMore[index] || _itemCount(index) >= _totals[index]) return;
    final query = _activeQuery;
    final generation = _searchGeneration;
    final nextPage = _pages[index] + 1;
    setState(() => _loadingMore[index] = true);
    switch (index) {
      case 0:
        final result = await MusicApiService.searchSongPage(query,
            page: nextPage, pageSize: _pageSize);
        if (mounted &&
            query == _activeQuery &&
            generation == _searchGeneration) {
          _songs.addAll(result.items);
        }
      case 1:
        final result = await MusicApiService.searchArtists(query,
            page: nextPage, pageSize: _pageSize);
        if (mounted &&
            query == _activeQuery &&
            generation == _searchGeneration) {
          _artists.addAll(result.items);
        }
      case 2:
        final result = await MusicApiService.searchAlbums(query,
            page: nextPage, pageSize: _pageSize);
        if (mounted &&
            query == _activeQuery &&
            generation == _searchGeneration) {
          _albums.addAll(result.items);
        }
      case 3:
        final result = await MusicApiService.searchPlaylists(query,
            page: nextPage, pageSize: _pageSize);
        if (mounted &&
            query == _activeQuery &&
            generation == _searchGeneration) {
          _playlists.addAll(result.items);
        }
      case 4:
        final result = await MusicApiService.searchMVs(query,
            page: nextPage, pageSize: _pageSize);
        if (mounted &&
            query == _activeQuery &&
            generation == _searchGeneration) {
          _mvs.addAll(result.items);
        }
    }
    if (!mounted || query != _activeQuery || generation != _searchGeneration) {
      return;
    }
    setState(() {
      _pages[index] = nextPage;
      _loadingMore[index] = false;
    });
  }

  int _itemCount(int index) => switch (index) {
        0 => _songs.length,
        1 => _artists.length,
        2 => _albums.length,
        3 => _playlists.length,
        _ => _mvs.length,
      };

  Future<void> _downloadSong(Song song) async {
    if (_downloadingHashes.contains(song.hash)) return;
    setState(() => _downloadingHashes.add(song.hash));
    final path = await MusicApiService.downloadSong(song);
    if (!mounted) return;
    setState(() => _downloadingHashes.remove(song.hash));
    AppToast.show(
      context,
      path == null ? '下载失败或已取消' : '已下载到 $path',
      isError: path == null,
    );
  }

  @override
  void dispose() {
    _suggestionTimer?.cancel();
    _controller.removeListener(_onQueryChanged);
    _controller.dispose();
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgWarm,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: _buildSearchField(),
            ),
            if (_suggestions.isNotEmpty) _buildSuggestions(),
            if (_activeQuery.isNotEmpty) _buildTabs(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchField() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderWarm),
      ),
      child: TextField(
        controller: _controller,
        textInputAction: TextInputAction.search,
        onSubmitted: _doSearch,
        decoration: InputDecoration(
          hintText: '搜索歌曲、歌手、专辑、歌单和 MV',
          hintStyle: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
          prefixIcon: Icon(Icons.search_rounded, color: AppTheme.accentOrange),
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '清空',
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: _controller.clear,
                ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  Widget _buildSuggestions() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 300),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        border: Border.all(color: AppTheme.borderWarm),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: _suggestions.length,
        itemBuilder: (context, index) {
          final suggestion = _suggestions[index];
          final label = switch (suggestion.type) {
            'album' => '专辑',
            'mv' => 'MV',
            _ => '歌曲',
          };
          return ListTile(
            dense: true,
            leading:
                Icon(Icons.search, size: 18, color: AppTheme.textSecondary),
            title: Text.rich(
              _highlightMatch(suggestion.keyword, _controller.text.trim()),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Text(label,
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            onTap: () {
              _controller.value = TextEditingValue(
                text: suggestion.keyword,
                selection:
                    TextSelection.collapsed(offset: suggestion.keyword.length),
              );
              _doSearch(suggestion.keyword);
            },
          );
        },
      ),
    );
  }

  // 对关键词里按输入顺序逐字命中的字符高亮（“单字索引”式模糊搜索展示）
  TextSpan _highlightMatch(String keyword, String query) {
    if (query.isEmpty) {
      return TextSpan(
          text: keyword, style: TextStyle(color: AppTheme.textPrimary));
    }
    final spans = <TextSpan>[];
    final queryChars = query.split('');
    var qi = 0;
    var ci = 0;
    for (; ci < keyword.length && qi < queryChars.length; ci++) {
      final ch = keyword[ci];
      if (ch == queryChars[qi]) {
        spans.add(TextSpan(
          text: ch,
          style: TextStyle(
              color: AppTheme.accentOrange, fontWeight: FontWeight.bold),
        ));
        qi++;
      } else {
        spans.add(TextSpan(text: ch, style: TextStyle(color: AppTheme.textPrimary)));
      }
    }
    // 追加关键词剩余未匹配的字符（正常色）；不追加输入多余字符，避免内容串味
    while (ci < keyword.length) {
      spans.add(TextSpan(
          text: keyword[ci], style: TextStyle(color: AppTheme.textPrimary)));
      ci++;
    }
    return TextSpan(
        text: '', style: TextStyle(color: AppTheme.textPrimary), children: spans);
  }

  Widget _buildTabs() {
    return TabBar(
      controller: _tabController,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      labelColor: AppTheme.accentOrange,
      unselectedLabelColor: AppTheme.textSecondary,
      indicatorColor: AppTheme.accentOrange,
      tabs: List.generate(
        _tabs.length,
        (index) => Tab(text: '${_tabs[index]} ${_totals[index]}'),
      ),
    );
  }

  Widget _buildBody() {
    if (_activeQuery.isEmpty) return _buildStartView();
    if (_isSearching) {
      return Center(
        child: CircularProgressIndicator(color: AppTheme.accentOrange),
      );
    }
    return TabBarView(
      controller: _tabController,
      children: [
        _buildSongList(),
        _buildContentGrid(_artists, 1, Icons.person_outline_rounded),
        _buildContentGrid(_albums, 2, Icons.album_outlined),
        _buildContentGrid(_playlists, 3, Icons.queue_music_rounded),
        _buildContentGrid(_mvs, 4, Icons.ondemand_video_outlined),
      ],
    );
  }

  // 空查询状态：搜索历史（如有）+ 热搜列表
  Widget _buildStartView() {
    if (_isHotSearchLoading) {
      return Center(
        child: CircularProgressIndicator(color: AppTheme.accentOrange),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        if (_searchHistory.isNotEmpty) ..._buildHistorySection(),
        if (_hotSearch.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text('暂无热搜',
                  style: TextStyle(color: AppTheme.textSecondary)),
            ),
          )
        else ...[
          Text('热搜',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary)),
          const SizedBox(height: 16),
          for (final category in _hotSearch) ...[
            Text(category.name,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: category.keywords.asMap().entries.map((entry) {
                final popular = entry.key < 3;
                return ActionChip(
                  avatar: popular
                      ? Icon(Icons.local_fire_department_rounded,
                          size: 16, color: AppTheme.accentOrange)
                      : null,
                  label: Text(entry.value),
                  backgroundColor: AppTheme.surfaceWhite,
                  side: BorderSide(
                      color: popular
                          ? AppTheme.accentOrange.withOpacity(0.45)
                          : AppTheme.borderWarm),
                  onPressed: () {
                    _controller.value = TextEditingValue(
                      text: entry.value,
                      selection:
                          TextSelection.collapsed(offset: entry.value.length),
                    );
                    _doSearch(entry.value);
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
          ],
        ],
      ],
    );
  }

  List<Widget> _buildHistorySection() {
    return [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('搜索历史',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary)),
          TextButton.icon(
            onPressed: () async {
              await SearchHistoryService.clear();
              if (!mounted) return;
              setState(() => _searchHistory = []);
            },
            icon: const Icon(Icons.delete_sweep_outlined, size: 16),
            label: const Text('清空'),
            style: TextButton.styleFrom(
                foregroundColor: AppTheme.textSecondary,
                visualDensity: VisualDensity.compact),
          ),
        ],
      ),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _searchHistory.map((keyword) {
          return ActionChip(
            avatar: Icon(Icons.history, size: 15, color: AppTheme.textSecondary),
            label: Text(keyword),
            backgroundColor: AppTheme.surfaceWhite,
            side: BorderSide(color: AppTheme.borderWarm),
            onPressed: () {
              _controller.value = TextEditingValue(
                text: keyword,
                selection: TextSelection.collapsed(offset: keyword.length),
              );
              _doSearch(keyword);
            },
          );
        }).toList(),
      ),
      const SizedBox(height: 24),
    ];
  }

  Widget _buildSongList() {
    if (_songs.isEmpty) return _buildEmpty();
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _songs.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == _songs.length) return _buildLoadMore(0);
        final song = _songs[index];
        return Material(
          color: Colors.transparent,
          child: ListTile(
            tileColor: AppTheme.surfaceWhite,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: AppTheme.borderWarm),
            ),
            leading: _cover(song.coverUrl ?? '', Icons.music_note_rounded,
                width: 44, height: 44),
            title: Text(song.songName,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${song.authorName} · ${song.albumName ?? '未知专辑'}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '下载',
                  onPressed: () => _downloadSong(song),
                  icon: _downloadingHashes.contains(song.hash)
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.download_rounded),
                ),
                Icon(Icons.play_circle_outline_rounded,
                    color: AppTheme.accentOrange),
              ],
            ),
            onTap: () => context
                .read<AudioPlayerManager>()
                .playSong(song, newPlaylist: _songs),
          ),
        );
      },
    );
  }

  Widget _buildContentGrid(
      List<Map<String, dynamic>> items, int index, IconData placeholder) {
    if (items.isEmpty) return _buildEmpty();
    return LayoutBuilder(builder: (context, constraints) {
      final columns = constraints.maxWidth >= 1000
          ? 5
          : constraints.maxWidth >= 720
              ? 4
              : constraints.maxWidth >= 480
                  ? 3
                  : 2;
      return GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.78,
        ),
        itemCount: items.length + 1,
        itemBuilder: (context, itemIndex) {
          if (itemIndex == items.length) return _buildLoadMore(index);
          final item = items[itemIndex];
          return _buildContentCard(item, index, placeholder);
        },
      );
    });
  }

  Widget _buildContentCard(
      Map<String, dynamic> item, int index, IconData placeholder) {
    final title = item['title']?.toString() ?? '';
    final subtitle = item['subtitle']?.toString() ?? '';
    final count = item['count'] as int? ?? 0;
    final duration = item['duration'] as int? ?? 0;
    return Material(
      color: AppTheme.surfaceWhite,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: AppTheme.borderWarm),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openContent(item, index),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _cover(item['cover']?.toString() ?? '', placeholder),
                  if (duration > 0)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 3),
                        color: Colors.black54,
                        child: Text(_formatDuration(duration),
                            style: const TextStyle(
                                color: Colors.white, fontSize: 11)),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(count > 0 ? '$subtitle · $count 首' : subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openContent(Map<String, dynamic> item, int index) {
    // 歌手：通过 onOpenDetail 在内容区打开歌手歌曲页（与专辑详情一致，不新开全屏路由）
    if (index == 1) {
      final name = item['title']?.toString() ?? '';
      if (name.isEmpty) return;
      widget.onOpenDetail(
        AlbumDetailDestination(
          id: name,
          title: name,
          coverUrl: item['cover']?.toString(),
          type: 'artist',
        ),
      );
      return;
    }
    if (index != 2 && index != 3) return;
    final id = item['id']?.toString() ?? '';
    if (id.isEmpty) return;
    widget.onOpenDetail(
      AlbumDetailDestination(
        id: id,
        title: item['title']?.toString() ?? '',
        coverUrl: item['cover']?.toString(),
        artist: item['subtitle']?.toString(),
        type: index == 2 ? 'album' : 'playlist',
      ),
    );
  }

  Widget _cover(String url, IconData placeholder,
      {double? width, double? height}) {
    final fallback = Container(
      width: width,
      height: height,
      color: AppTheme.surfaceWarm,
      alignment: Alignment.center,
      child: Icon(placeholder, color: AppTheme.textSecondary),
    );
    if (url.isEmpty) return fallback;
    return CachedNetworkImage(
      imageUrl: url,
      width: width,
      height: height,
      fit: BoxFit.cover,
      memCacheWidth: width != null ? (width * 2).round() : null,
      errorWidget: (_, __, ___) => fallback,
    );
  }

  Widget _buildLoadMore(int index) {
    if (_itemCount(index) >= _totals[index]) return const SizedBox.shrink();
    if (_loadingMore[index]) {
      return Center(
        child: CircularProgressIndicator(color: AppTheme.accentOrange),
      );
    }
    return Center(
      child: TextButton.icon(
        onPressed: () => _loadMore(index),
        icon: const Icon(Icons.add_rounded),
        label: Text('查看更多 (${_itemCount(index)}/${_totals[index]})'),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_rounded,
              size: 48, color: AppTheme.textSecondary),
          const SizedBox(height: 10),
          Text('未找到相关结果', style: TextStyle(color: AppTheme.textSecondary)),
        ],
      ),
    );
  }

  String _formatDuration(int seconds) =>
      '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}
