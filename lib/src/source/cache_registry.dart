import 'dart:async';

enum CacheState { unsupported, active, complete, error }

class ByteRange {
  final int start;
  final int end;
  const ByteRange(this.start, this.end);
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
    _entries[e.cacheKey] = e;
    _controllers[e.cacheKey]?.add(e);
  }

  CacheEntry? of(String cacheKey) => _entries[cacheKey];

  Stream<CacheEntry> watch(String cacheKey) {
    final c = _controllers.putIfAbsent(
      cacheKey,
      () => StreamController<CacheEntry>.broadcast(),
    );
    return c.stream;
  }
}
