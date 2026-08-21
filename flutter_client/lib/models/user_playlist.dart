class UserPlaylist {
  const UserPlaylist({
    required this.globalCollectionId,
    required this.listId,
    required this.name,
    required this.intro,
    required this.coverUrl,
    required this.count,
    required this.type,
    required this.creatorName,
  });

  final String globalCollectionId;
  final int listId;
  final String name;
  final String intro;
  final String coverUrl;
  final int count;
  final int type;
  final String creatorName;

  factory UserPlaylist.fromJson(Map<String, dynamic> json) {
    final cover = json['pic'] ?? json['union_cover'] ?? '';
    return UserPlaylist(
      globalCollectionId: json['global_collection_id']?.toString() ?? '',
      listId: (json['listid'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '未命名歌单',
      intro: json['intro']?.toString() ?? '',
      coverUrl: cover.toString().replaceAll('{size}', '400'),
      count: (json['count'] as num?)?.toInt() ?? 0,
      type: (json['type'] as num?)?.toInt() ?? 0,
      creatorName:
          (json['list_create_username'] ?? json['create_username'] ?? '')
              .toString(),
    );
  }
}
