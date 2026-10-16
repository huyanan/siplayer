import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'src/rust/frb_generated.dart';
import 'src/source/cache_registry.dart';
import 'src/source/http_stream_provider.dart';
import 'src/source/p2p_provider.dart';
import 'src/source/source_provider.dart';
import 'src/ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Web 端无 P2P（spec §8），不加载 Rust 库
  var rustReady = false;
  if (!kIsWeb) {
    try {
      await RustLib.init();
      rustReady = true;
    } catch (_) {
      // Rust 库加载失败只降级 P2P，HTTP 播放不受影响；不打印异常详情（可能含本机路径）
      debugPrint('RustLib init failed, P2P disabled');
    }
  }
  MediaKit.ensureInitialized();
  // 与 App 同生命周期，无需 dispose
  final cacheRegistry = CacheRegistry();
  // registry 只建一次，避免根部 rebuild 产生新实例导致 resolve/release 不对应
  final registry = SourceRegistry()
    ..register(HttpStreamProvider())
    ..register(P2PProvider(cacheRegistry, rustReady: rustReady));
  runApp(SiplayerApp(registry: registry));
}

class SiplayerApp extends StatelessWidget {
  final SourceRegistry registry;
  const SiplayerApp({super.key, required this.registry});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'siplayer',
      home: HomePage(registry: registry),
    );
  }
}
