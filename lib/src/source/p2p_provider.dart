import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../rust/api/p2p.dart';
import 'cache_registry.dart';
import 'media_ref.dart';
import 'playable.dart';
import 'source_provider.dart';

/// magnet -> 本地鉴权 HTTP 流（Rust 侧 librqbit 边下边播）。
///
/// Rust 侧按调用次数做引用计数：每一次成功的 [p2PStart] 必须且只能配对一次 [p2PRelease]。
/// 因此这里按次数记录持有，而不是 locator -> 单个 torrentId。
class P2PProvider extends SourceProvider {
  static const Set<TargetPlatform> _supportedPlatforms = {
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.android,
    TargetPlatform.iOS,
  };

  static const Duration _pollInterval = Duration(seconds: 1);

  final CacheRegistry cacheRegistry;

  /// locator -> 每次成功 resolve 得到的 torrentId（按次数，可重复）
  final Map<String, List<PlatformInt64>> _holds = {};

  /// torrentId -> 当前持有次数（不同 locator 可能指向同一 infohash / torrentId）
  final Map<PlatformInt64, int> _idHolds = {};

  /// locator -> 进行中的 resolve 数
  final Map<String, int> _inflight = {};

  /// locator -> resolve 完成前就到达的 release 数
  final Map<String, int> _deferredReleases = {};

  /// torrentId -> 共享的进度轮询定时器
  final Map<PlatformInt64, Timer> _pollers = {};

  /// 正在等待 p2PProgress 返回的 torrentId，避免轮询重入
  final Set<PlatformInt64> _polling = {};

  P2PProvider(this.cacheRegistry);

  @override
  String get id => 'p2p';

  @override
  bool get isAvailableOnThisPlatform => !kIsWeb && _supportedPlatforms.contains(defaultTargetPlatform);

  @override
  Future<Playable> resolve(MediaRef ref) async {
    final locator = ref.locator;
    _inflight[locator] = (_inflight[locator] ?? 0) + 1;
    final P2pHandle handle;
    try {
      handle = await p2PStart(magnet: locator, fileIndex: ref.fileIndex);
    } catch (_) {
      // 这次失败的 resolve 若已被提前 release，对应的 deferred 在此消耗，无需调用 p2PRelease
      _consumeDeferred(locator);
      rethrow;
    } finally {
      _decrement(_inflight, locator);
    }

    if (_consumeDeferred(locator)) {
      // 页面在加载完成前已关闭：立即归还本次持有
      await _safeRelease(handle.torrentId);
      throw StateError('released before resolve completed');
    }

    final torrentId = handle.torrentId;
    (_holds[locator] ??= <PlatformInt64>[]).add(torrentId);
    _idHolds[torrentId] = (_idHolds[torrentId] ?? 0) + 1;
    _ensurePolling(torrentId);
    return Playable(
      url: Uri.parse(handle.streamUrl),
      headers: {'Authorization': handle.authHeader},
      cacheKey: _cacheKeyOf(torrentId),
    );
  }

  @override
  Future<void> release(MediaRef ref) async {
    final locator = ref.locator;
    final held = _holds[locator];
    if (held == null || held.isEmpty) {
      if ((_inflight[locator] ?? 0) > 0) {
        _deferredReleases[locator] = (_deferredReleases[locator] ?? 0) + 1;
      }
      return;
    }

    final torrentId = held.removeLast();
    if (held.isEmpty) {
      _holds.remove(locator);
    }
    if (_decrement(_idHolds, torrentId) == 0) {
      // 该 torrent 的最后一个持有：停止轮询并清理缓存登记
      _pollers.remove(torrentId)?.cancel();
      cacheRegistry.remove(_cacheKeyOf(torrentId));
    }
    await _safeRelease(torrentId);
  }

  void _ensurePolling(PlatformInt64 torrentId) {
    if (_pollers.containsKey(torrentId)) {
      return;
    }
    late final Timer timer;
    timer = Timer.periodic(_pollInterval, (_) => _poll(torrentId, timer));
    _pollers[torrentId] = timer;
  }

  Future<void> _poll(PlatformInt64 torrentId, Timer timer) async {
    if (!_polling.add(torrentId)) {
      return; // 上一次查询尚未返回
    }
    try {
      final p = await p2PProgress(torrentId: torrentId);
      // 等待期间可能已被 release（或换了新定时器），此时丢弃结果，避免把已移除的条目写回
      if (!identical(_pollers[torrentId], timer)) {
        return;
      }
      final downloaded = p.downloadedBytes.toInt();
      cacheRegistry.update(CacheEntry(
        cacheKey: _cacheKeyOf(torrentId),
        totalBytes: p.totalBytes?.toInt(),
        // M2 近似：用单区间 [0, downloaded) 表达已下载量；精确多区间（按 piece 位图）留 M3
        completed: downloaded > 0 ? [ByteRange(0, downloaded)] : const [],
        state: p.finished ? CacheState.complete : CacheState.active,
      ));
    } catch (_) {
      // torrent 已释放 / 竞态：静默停止该轮询，不向 Zone 顶层抛
      timer.cancel();
      if (identical(_pollers[torrentId], timer)) {
        _pollers.remove(torrentId);
      }
    } finally {
      _polling.remove(torrentId);
    }
  }

  bool _consumeDeferred(String locator) {
    if ((_deferredReleases[locator] ?? 0) == 0) {
      return false;
    }
    _decrement(_deferredReleases, locator);
    return true;
  }

  Future<void> _safeRelease(PlatformInt64 torrentId) async {
    try {
      await p2PRelease(torrentId: torrentId);
    } catch (_) {
      // release 由 PlayerPage.dispose 以 fire-and-forget 方式触发，不能让异常逃逸；不记录 id 等句柄信息
      debugPrint('P2PProvider: release failed');
    }
  }

  static String _cacheKeyOf(PlatformInt64 torrentId) => 'p2p:$torrentId';

  /// 计数减一，归零时移除键；返回减后的值
  static int _decrement<K>(Map<K, int> counts, K key) {
    final next = (counts[key] ?? 0) - 1;
    if (next <= 0) {
      counts.remove(key);
      return 0;
    }
    counts[key] = next;
    return next;
  }
}
