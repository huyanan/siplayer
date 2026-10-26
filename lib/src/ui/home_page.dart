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
          const Divider(height: 1),
          _MagnetInputTile(registry: registry),
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
          ? () {
              // 每次打开都新建 MediaRef：P2PProvider 按请求实例记账，不能复用共享的 const 实例
              final ref = MediaRef(
                sourceId: demo.ref.sourceId,
                locator: demo.ref.locator,
                fileIndex: demo.ref.fileIndex,
              );
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PlayerPage(registry: registry, ref: ref),
                ),
              );
            }
          : null,
    );
  }
}

class _DemoItem {
  final String title;
  final MediaRef ref;
  const _DemoItem({required this.title, required this.ref});
}

/// 用户自备磁力链输入：手动粘贴 magnet 即可播放，不做任何搜索/索引/资源发现。
class _MagnetInputTile extends StatefulWidget {
  final SourceRegistry registry;
  const _MagnetInputTile({required this.registry});

  @override
  State<_MagnetInputTile> createState() => _MagnetInputTileState();
}

class _MagnetInputTileState extends State<_MagnetInputTile> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _play() {
    final text = _controller.text.trim();
    if (!text.startsWith('magnet:')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入以 magnet: 开头的磁力链接')),
      );
      return;
    }
    // 每次打开都新建 MediaRef：P2PProvider 按请求实例记账，不能复用
    final ref = MediaRef(sourceId: 'p2p', locator: text);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(registry: widget.registry, ref: ref),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final available =
        widget.registry.providerFor('p2p')?.isAvailableOnThisPlatform ?? false;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('播放自备磁力链'),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  enabled: available,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'magnet:?xt=urn:btih:...',
                    isDense: true,
                  ),
                  onSubmitted: available ? (_) => _play() : null,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: available ? _play : null,
                child: const Text('播放'),
              ),
            ],
          ),
          if (!available)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('当前平台不支持 P2P'),
            ),
        ],
      ),
    );
  }
}
