import 'package:audigo/services/meting_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实网络测试：验证 Meting 原唱优先排序（依赖自建 meting 服务可用）。
void main() {
  test('原唱在结果中时排第一（孤勇者 陈奕迅）', () async {
    final results = await MetingApiService.searchRanked('孤勇者 陈奕迅');
    expect(results, isNotEmpty);
    expect(results.first.artist, '陈奕迅');
    expect(results.first.name, '孤勇者');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('原唱不在结果中时，带翻唱标记的排不到最前（晴天 周杰伦）', () async {
    final results = await MetingApiService.searchRanked('晴天 周杰伦');
    expect(results, isNotEmpty);
    // 周杰伦原唱独家在腾讯，网易云只有翻唱：
    // 排第一的应是「无版本标记的干净翻唱」，而非「(原唱 周杰伦)」这类标记翻唱。
    expect(results.first.name.contains('原唱'), isFalse);
    expect(
      RegExp(r'[（(][^)）]*(live|dj|版|女声|男声|钢琴|吉他|remix)[^)）]*[)）]')
          .hasMatch(results.first.name),
      isFalse,
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('搜索结果带封面代理地址', () async {
    final results = await MetingApiService.searchRanked('孤勇者 陈奕迅');
    expect(results.first.pic, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));
}