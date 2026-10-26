import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../playback/playback_controller.dart';
import '../source/cache_registry.dart';
import '../source/media_ref.dart';
import '../source/source_provider.dart';

class PlayerPage extends StatefulWidget {
  final SourceRegistry registry;
  final MediaRef ref;
  const PlayerPage({super.key, required this.registry, required this.ref});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late MediaRef _currentRef;
  PlaybackController? _controller;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<CacheEntry>? _cacheSub;
  String? _error;
  bool _stalled = false;
  bool _retrying = false;

  /// 已缓存比例 0..1（仅 P2P 源，算不出时为 null）
  double? _cachedFraction;

  @override
  void initState() {
    super.initState();
    _currentRef = widget.ref;
    _load();
  }

  Future<void> _load() async {
    await _errorSub?.cancel();
    await _cacheSub?.cancel();
    _errorSub = null;
    _cacheSub = null;
    final controller = PlaybackController();
    try {
      final playable = await widget.registry.resolve(_currentRef);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _errorSub = controller.error.listen((msg) {
        if (mounted) setState(() => _error = msg);
      });
      _cacheSub = playable.cacheStream?.listen((e) {
        if (!mounted) return;
        final stalled = e.state == CacheState.stalled;
        final total = e.totalBytes;
        final cachedEnd = e.completed.isNotEmpty ? e.completed.last.end : 0;
        final fraction = (total != null && total > 0)
            ? (cachedEnd / total).clamp(0.0, 1.0)
            : null;
        if (stalled != _stalled || fraction != _cachedFraction) {
          setState(() {
            _stalled = stalled;
            _cachedFraction = fraction;
          });
        }
      });
      // 挂载 Video 并触发 rebuild —— 否则 HLS 等无 cacheStream 的源会永远停在
      // 初始的 CircularProgressIndicator 上（底层已在播但 UI 不刷新）。
      setState(() => _controller = controller);
      await controller.open(playable);
    } on SourceNotAvailableException catch (e) {
      if (mounted) setState(() => _error = e.reason);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _retry() async {
    if (_retrying) return;
    _retrying = true;
    try {
      await _errorSub?.cancel();
      await _cacheSub?.cancel();
      await _controller?.dispose();
      await widget.registry.release(_currentRef);
      // P2PProvider 按 MediaRef 实例记账，重试必须换新实例
      _currentRef = MediaRef(
        sourceId: widget.ref.sourceId,
        locator: widget.ref.locator,
        fileIndex: widget.ref.fileIndex,
      );
      if (!mounted) return;
      setState(() {
        _error = null;
        _stalled = false;
        _cachedFraction = null;
        _controller = null;
      });
      await _load();
      if (mounted) setState(() {});
    } finally {
      _retrying = false;
    }
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    _cacheSub?.cancel();
    _controller?.dispose();
    widget.registry.release(_currentRef);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('播放失败：$_error'),
              const SizedBox(height: 12),
              FilledButton(onPressed: _retrying ? null : _retry, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(),
      body: controller == null
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                Positioned.fill(child: Video(controller: controller.videoController)),
                if (_cachedFraction != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(
                      value: _cachedFraction,
                      minHeight: 3,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                if (_stalled)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black54,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('无可用 peer，连接中…',
                                style: TextStyle(color: Colors.white)),
                            const SizedBox(height: 12),
                            FilledButton(onPressed: _retrying ? null : _retry, child: const Text('重试')),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
