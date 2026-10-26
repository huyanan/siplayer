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
/// 因此这里按请求实例（[MediaRef] 对象身份）记账：每个实例至多一个持有，release 只影响该实例。
class P2PProvider extends SourceProvider {
  // 目前只接通了 macOS 的原生库与桥接；windows / android / iOS 随 M4 接入
  static const Set<TargetPlatform> _supportedPlatforms = {
    TargetPlatform.macOS,
  };

  static const Duration _pollInterval = Duration(seconds: 1);

  /// 下载连续无增长达到该轮询次数（间隔 1s ≈ 30s）即判定停滞，对齐 spec §6
  static const int _stallThresholdTicks = 30;

  final CacheRegistry cacheRegistry;

  /// Rust 库是否初始化成功；失败时本源对外报告不可用
  final bool rustReady;

  /// 请求实例 -> 该实例成功 resolve 得到的 torrentId（按对象身份，每实例至多一个）
  final Map<MediaRef, PlatformInt64> _holds = Map.identity();

  /// torrentId -> 当前持有次数（不同实例 / locator 可能指向同一 infohash / torrentId）
  final Map<PlatformInt64, int> _idHolds = {};

  /// resolve 进行中的请求实例
  final Set<MediaRef> _inflight = Set.identity();

  /// resolve 完成前就被 release 的请求实例
  final Set<MediaRef> _releasedWhileResolving = Set.identity();

  /// torrentId -> 共享的进度轮询定时器
  final Map<PlatformInt64, Timer> _pollers = {};

  /// 正在等待 p2PProgress 返回的 torrentId，避免轮询重入
  final Set<PlatformInt64> _polling = {};

  /// torrentId -> 上次观测到的已下载字节数
  final Map<PlatformInt64, int> _lastDownloaded = {};

  /// torrentId -> 连续无增长的轮询次数
  final Map<PlatformInt64, int> _noProgressTicks = {};

  P2PProvider(this.cacheRegistry, {this.rustReady = true});

  @override
  String get id => 'p2p';

  @override
  bool get isAvailableOnThisPlatform =>
      rustReady && !kIsWeb && _supportedPlatforms.contains(defaultTargetPlatform);

  @override
  Future<Playable> resolve(MediaRef ref) async {
    if (_inflight.contains(ref) || _holds.containsKey(ref)) {
      throw StateError('MediaRef instance already resolving or resolved');
    }
    _inflight.add(ref);
    final P2pHandle handle;
    try {
      handle = await p2PStart(magnet: ref.locator, fileIndex: ref.fileIndex);
    } catch (_) {
      // 失败的 resolve 没有持有，无需 p2PRelease；若已被提前 release，只清理该实例的状态
      _releasedWhileResolving.remove(ref);
      rethrow;
    } finally {
      _inflight.remove(ref);
    }

    if (_releasedWhileResolving.remove(ref)) {
      // 该实例的页面在加载完成前已关闭：立即归还本次持有
      await _safeRelease(handle.torrentId);
      throw StateError('released before resolve completed');
    }

    final torrentId = handle.torrentId;
    _holds[ref] = torrentId;
    _idHolds[torrentId] = (_idHolds[torrentId] ?? 0) + 1;
    _ensurePolling(torrentId);
    final key = _cacheKeyOf(torrentId);
    return Playable(
      url: Uri.parse(handle.streamUrl),
      headers: {'Authorization': handle.authHeader},
      cacheKey: key,
      cacheStream: cacheRegistry.watch(key),
    );
  }

  @override
  Future<void> release(MediaRef ref) async {
    final torrentId = _holds.remove(ref);
    if (torrentId == null) {
      if (_inflight.contains(ref)) {
        _releasedWhileResolving.add(ref);
      }
      return;
    }

    if (_decrement(_idHolds, torrentId) == 0) {
      // 该 torrent 的最后一个持有：停止轮询并清理缓存登记
      _pollers.remove(torrentId)?.cancel();
      cacheRegistry.remove(_cacheKeyOf(torrentId));
      _lastDownloaded.remove(torrentId);
      _noProgressTicks.remove(torrentId);
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
      final CacheState state;
      if (p.finished) {
        state = CacheState.complete;
        _noProgressTicks.remove(torrentId);
      } else {
        final last = _lastDownloaded[torrentId];
        if (last == null || downloaded > last) {
          _noProgressTicks[torrentId] = 0;
          state = CacheState.active;
        } else {
          final ticks = (_noProgressTicks[torrentId] ?? 0) + 1;
          _noProgressTicks[torrentId] = ticks;
          state = ticks >= _stallThresholdTicks
              ? CacheState.stalled
              : CacheState.active;
        }
      }
      _lastDownloaded[torrentId] = downloaded;
      cacheRegistry.update(CacheEntry(
        cacheKey: _cacheKeyOf(torrentId),
        totalBytes: p.totalBytes?.toInt(),
        // M2 近似：用单区间 [0, downloaded) 表达已下载量；精确多区间（按 piece 位图）留 M3
        completed: downloaded > 0 ? [ByteRange(0, downloaded)] : const [],
        state: state,
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
