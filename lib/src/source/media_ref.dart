/// 一次播放请求的来源描述，不含播放状态。
class MediaRef {
  /// 'http' | 'local' | 'p2p'
  final String sourceId;

  /// URL / 本地路径 / magnet 链接
  final String locator;

  /// 多文件 torrent 内的文件下标；非 torrent 源为 null
  final int? fileIndex;

  const MediaRef({
    required this.sourceId,
    required this.locator,
    this.fileIndex,
  });
}
