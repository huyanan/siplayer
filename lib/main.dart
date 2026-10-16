import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'src/rust/frb_generated.dart';
import 'src/source/http_stream_provider.dart';
import 'src/source/media_ref.dart';
import 'src/source/source_provider.dart';
import 'src/ui/player_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Web 端无 P2P（spec §8），不加载 Rust 库
  if (!kIsWeb) {
    await RustLib.init();
  }
  MediaKit.ensureInitialized();
  // registry 只建一次，避免根部 rebuild 产生新实例导致 resolve/release 不对应
  final registry = SourceRegistry()..register(HttpStreamProvider());
  runApp(SiplayerApp(registry: registry));
}

class SiplayerApp extends StatelessWidget {
  final SourceRegistry registry;
  const SiplayerApp({super.key, required this.registry});

  @override
  Widget build(BuildContext context) {
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
