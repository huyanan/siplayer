import 'media_ref.dart';
import 'playable.dart';
import 'source_provider.dart';

/// 直链 / HLS / DASH 源。locator 即可播放 URL。
class HttpStreamProvider extends SourceProvider {
  @override
  String get id => 'http';

  @override
  bool get isAvailableOnThisPlatform => true;

  @override
  Future<Playable> resolve(MediaRef ref) async {
    final uri = Uri.parse(ref.locator);
    return Playable(url: uri, cacheKey: null);
  }

  @override
  Future<void> release(MediaRef ref) async {
    // HTTP 源无需释放资源。
  }
}
