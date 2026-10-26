import 'cache_registry.dart';

/// 播放器唯一入口：任何源 resolve 后都变成它。
class Playable {
  final Uri url;
  final Map<String, String> headers;
  final List<SubtitleTrack> subtitles;

  /// 为空表示不参与缓存登记
  final String? cacheKey;

  /// 缓存状态流（仅 P2P 源填充，用于进度/停滞提示）；其它源为 null
  final Stream<CacheEntry>? cacheStream;

  const Playable({
    required this.url,
    this.headers = const {},
    this.subtitles = const [],
    this.cacheKey,
    this.cacheStream,
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
