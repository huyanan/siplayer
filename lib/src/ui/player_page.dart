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
    _controller = controller;
    try {
      final playable = await widget.registry.resolve(_currentRef);
      if (!mounted) return;
      _errorSub = controller.error.listen((msg) {
        if (mounted) setState(() => _error = msg);
      });
      _cacheSub = playable.cacheStream?.listen((e) {
        final stalled = e.state == CacheState.stalled;
        if (mounted && stalled != _stalled) setState(() => _stalled = stalled);
      });
      await controller.open(playable);
    } on SourceNotAvailableException catch (e) {
      if (mounted) setState(() => _error = e.reason);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _retry() async {
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
      _controller = null;
    });
    await _load();
    if (mounted) setState(() {});
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
              FilledButton(onPressed: _retry, child: const Text('重试')),
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
                            FilledButton(onPressed: _retry, child: const Text('重试')),
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
