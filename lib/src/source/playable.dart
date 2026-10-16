/// 播放器唯一入口：任何源 resolve 后都变成它。
class Playable {
  final Uri url;
  final Map<String, String> headers;
  final List<SubtitleTrack> subtitles;

  /// 为空表示不参与缓存登记
  final String? cacheKey;

  const Playable({
    required this.url,
    this.headers = const {},
    this.subtitles = const [],
    this.cacheKey,
  });
}

class SubtitleTrack {
  final String id;
  final String label;
  final Uri uri;

  const SubtitleTrack({
    required this.id,
    required this.label,
    required this.uri,
  });
}
