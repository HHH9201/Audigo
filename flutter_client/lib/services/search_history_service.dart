import 'package:shared_preferences/shared_preferences.dart';

/// 搜索历史持久化服务（本地 SharedPreferences，去重、最近优先、上限 10 条）。
class SearchHistoryService {
  static const _key = 'search_history';
  static const int maxEntries = 10;

  SearchHistoryService._();

  static Future<List<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key) ?? [];
  }

  /// 新增一条历史，去重后置于最前，超出上限则丢弃最旧，返回最新列表。
  static Future<List<String>> add(String keyword) async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList(_key) ?? [];
    history.removeWhere((item) => item == keyword);
    history.insert(0, keyword);
    final trimmed = history.take(maxEntries).toList();
    await prefs.setStringList(_key, trimmed);
    return trimmed;
  }

  /// 移除单条历史。
  static Future<List<String>> remove(String keyword) async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList(_key) ?? [];
    history.remove(keyword);
    await prefs.setStringList(_key, history);
    return history;
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}