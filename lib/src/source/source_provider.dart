import 'media_ref.dart';
import 'playable.dart';

/// 把 MediaRef 变成可播 URL；不碰播放状态，不碰 UI。
abstract class SourceProvider {
  String get id;

  /// 当前平台是否支持此源（Web 上 P2PProvider 返回 false）。
  bool get isAvailableOnThisPlatform;

  Future<Playable> resolve(MediaRef ref);

  /// 停止 torrent / 关闭句柄。
  Future<void> release(MediaRef ref);
}

class SourceNotAvailableException implements Exception {
  final String sourceId;
  final String reason;
  const SourceNotAvailableException(this.sourceId, this.reason);

  @override
  String toString() => 'SourceNotAvailable($sourceId): $reason';
}

class SourceRegistry {
  final Map<String, SourceProvider> _providers = {};

  void register(SourceProvider p) => _providers[p.id] = p;

  SourceProvider? providerFor(String sourceId) => _providers[sourceId];

  Future<Playable> resolve(MediaRef ref) {
    final p = _providers[ref.sourceId];
    if (p == null) {
      throw SourceNotAvailableException(ref.sourceId, '未注册的源');
    }
    if (!p.isAvailableOnThisPlatform) {
      throw SourceNotAvailableException(ref.sourceId, '当前平台不支持该源');
    }
    return p.resolve(ref);
  }

  Future<void> release(MediaRef ref) async {
    await _providers[ref.sourceId]?.release(ref);
  }
}
