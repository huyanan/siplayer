import 'dart:async';

enum CacheState { unsupported, active, complete, error, stalled }

/// 字节区间，半开区间 [start, end)
class ByteRange {
  final int start;
  final int end;
  const ByteRange(this.start, this.end) : assert(start <= end);
}

class CacheEntry {
  final String cacheKey;

  /// metadata 未就位时为 null
  final int? totalBytes;
  final List<ByteRange> completed;
  final CacheState state;

  const CacheEntry({
    required this.cacheKey,
    required this.totalBytes,
    required this.completed,
    required this.state,
  });
}

class CacheRegistry {
  final Map<String, CacheEntry> _entries = {};
  final Map<String, StreamController<CacheEntry>> _controllers = {};

  void update(CacheEntry e) {
    // 冻结 completed，避免调用方后续修改影响已存储/已发出的状态
    final frozen = CacheEntry(
      cacheKey: e.cacheKey,
      totalBytes: e.totalBytes,
      completed: List.unmodifiable(e.completed),
      state: e.state,
    );
    _entries[frozen.cacheKey] = frozen;
    _controllers[frozen.cacheKey]?.add(frozen);
  }

  CacheEntry? of(String cacheKey) => _entries[cacheKey];

  Stream<CacheEntry> watch(String cacheKey) {
    final c = _controllers.putIfAbsent(
      cacheKey,
      () => StreamController<CacheEntry>.broadcast(),
    );
    return c.stream;
  }

  /// 移除条目并关闭对应 controller，订阅方会收到 done
  void remove(String cacheKey) {
    _entries.remove(cacheKey);
    final c = _controllers.remove(cacheKey);
    if (c != null) {
      unawaited(c.close());
    }
  }

  Future<void> dispose() async {
    _entries.clear();
    final controllers = _controllers.values.toList();
    _controllers.clear();
    await Future.wait(controllers.map((c) => c.close()));
  }
}
