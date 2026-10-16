import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'src/source/http_stream_provider.dart';
import 'src/source/media_ref.dart';
import 'src/source/source_provider.dart';
import 'src/ui/player_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const SiplayerApp());
}

class SiplayerApp extends StatelessWidget {
  const SiplayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final registry = SourceRegistry()..register(HttpStreamProvider());
    const demo = MediaRef(
      sourceId: 'http',
      locator:
          'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    );
    return MaterialApp(
      title: 'siplayer',
      home: PlayerPage(registry: registry, ref: demo),
    );
  }
}
