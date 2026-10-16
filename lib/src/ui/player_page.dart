import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../playback/playback_controller.dart';
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
  final _controller = PlaybackController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final playable = await widget.registry.resolve(widget.ref);
      await _controller.open(playable);
    } on SourceNotAvailableException catch (e) {
      setState(() => _error = e.reason);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    widget.registry.release(widget.ref);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(body: Center(child: Text('播放失败：$_error')));
    }
    return Scaffold(
      body: Video(controller: _controller.videoController),
    );
  }
}
