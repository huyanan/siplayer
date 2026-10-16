import 'package:flutter/material.dart';

import '../source/media_ref.dart';
import '../source/source_provider.dart';
import 'player_page.dart';

/// 极简首页：只列出内置的合法演示源，不提供任何搜索/索引/输入式的资源发现。
class HomePage extends StatelessWidget {
  final SourceRegistry registry;
  const HomePage({super.key, required this.registry});

  static const List<_DemoItem> _demos = [
    _DemoItem(
      title: 'HLS 测试流',
      ref: MediaRef(
        sourceId: 'http',
        locator: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
      ),
    ),
    _DemoItem(
      title: 'P2P：Sintel（Blender 基金会，CC BY）',
      ref: MediaRef(
        sourceId: 'p2p',
        locator: 'magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10&dn=Sintel'
            '&tr=udp%3A%2F%2Fexplodie.org%3A6969&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337'
            '&tr=wss%3A%2F%2Ftracker.webtorrent.dev&ws=https%3A%2F%2Fwebtorrent.io%2Ftorrents%2F',
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('siplayer')),
      body: ListView(
        children: [
          for (final demo in _demos) _buildTile(context, demo),
        ],
      ),
    );
  }

  Widget _buildTile(BuildContext context, _DemoItem demo) {
    final available = registry.providerFor(demo.ref.sourceId)?.isAvailableOnThisPlatform ?? false;
    return ListTile(
      title: Text(demo.title),
      subtitle: available ? null : Text(demo.ref.sourceId == 'p2p' ? '当前平台不支持 P2P' : '当前平台不支持该源'),
      enabled: available,
      onTap: available
          ? () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PlayerPage(registry: registry, ref: demo.ref),
                ),
              )
          : null,
    );
  }
}

class _DemoItem {
  final String title;
  final MediaRef ref;
  const _DemoItem({required this.title, required this.ref});
}
