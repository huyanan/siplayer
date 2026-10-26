# M3-a 错误/停滞可见性 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 P2P 播放的失败和停滞对用户可见：libmpv 播放错误上屏、下载停滞时提示"无可用 peer"，两种情况都提供重试。

**Architecture:** 停滞检测放在 Dart 侧 `P2PProvider`（它已每秒轮询下载进度）——连续若干秒下载不增长且未完成即判定停滞，经 `CacheState.stalled` 通过 `CacheRegistry` 传给 UI。`PlayerPage` 重构成状态机，订阅 `PlaybackController.error` 流与 `CacheRegistry.watch(cacheKey)`，在错误/停滞时覆盖提示并支持重试。不改 Rust 接口。

**Tech Stack:** Flutter / Dart、media_kit（`Stream<String> error`）、现有 CacheRegistry / P2PProvider。

## Global Constraints

- 本计划基于已批准 spec `docs/mapdev/specs/2026-10-10-player-core-design.md` §6 错误处理，只覆盖"错误/停滞可见性 + 重试"，不含进度条缓存着色、下载目录管理（M3 其它批次）。
- 仅 macOS 做运行验证（本机能 `flutter build/run macos`、release 版可独立 open）；Web 端只需 `flutter analyze` + `flutter build web` 通过。
- 测试策略：默认不写单测。每个任务以 `flutter analyze`（无新增告警）收尾；能在 macOS 真机验证的用 release 版 open 或临时 integration_test（跑完删、不提交）。
- commit message 用普通语义化格式。**提交时只 `git add` 本任务涉及的文件，绝不提交 `lib/src/ui/home_page.dart`**（其中有未提交的本机做种演示 magnet，属演示脚手架）。
- 内容边界：不新增任何源发现/索引逻辑；重试只是对同一 `MediaRef` 的重新加载。
- 停滞阈值集中为可配置常量（默认 20s）。

## 文件结构

- `lib/src/source/cache_registry.dart` — `CacheState` 增加 `stalled`（Task 1）
- `lib/src/source/p2p_provider.dart` — 停滞检测：记录每个 torrentId 的下载变化时刻，判定并写 `stalled`（Task 1）
- `lib/src/ui/player_page.dart` — 重构为状态机：订阅错误流 + 缓存状态，错误/停滞覆盖提示 + 重试（Task 2）

---

<!-- TASKS -->

## Task 1: 停滞信号的产生与传递

**Files:**
- Modify: `lib/src/source/cache_registry.dart`（`CacheState` 加 `stalled`）
- Modify: `lib/src/source/playable.dart`（加可选 `cacheStream` 字段）
- Modify: `lib/src/source/p2p_provider.dart`（停滞检测 + resolve 填 `cacheStream` + release 清理）

**Interfaces:**
- Consumes: 现有 `CacheRegistry.watch`、`p2PProgress`
- Produces:
  - `enum CacheState { unsupported, active, complete, error, stalled }`
  - `Playable` 新增 `final Stream<CacheEntry>? cacheStream;`（默认 null；仅 P2P 源填充）
  - P2P 源：下载连续 `_stallThresholdTicks`（默认 30，轮询间隔 1s ≈ 30s，对齐 spec §6）无增长且未完成时，`CacheEntry.state == CacheState.stalled`

- [ ] **Step 1: CacheState 加 stalled**

`lib/src/source/cache_registry.dart` 第 3 行：

```dart
enum CacheState { unsupported, active, complete, error, stalled }
```

- [ ] **Step 2: Playable 加 cacheStream**

`lib/src/source/playable.dart`：顶部加 `import 'cache_registry.dart';`，给 `Playable` 加字段与构造参数：

```dart
  /// 缓存状态流（仅 P2P 源填充，用于进度/停滞提示）；其它源为 null
  final Stream<CacheEntry>? cacheStream;
```

构造函数加 `this.cacheStream`（可选，默认 null），放在参数列表末尾，不改其它字段。

- [ ] **Step 3: P2PProvider 加停滞检测状态**

`lib/src/source/p2p_provider.dart`：在类内常量区加停滞阈值，在记账字段区加两个 map：

```dart
  /// 下载连续无增长达到该轮询次数（间隔 1s ≈ 30s）即判定停滞，对齐 spec §6
  static const int _stallThresholdTicks = 30;
```

```dart
  /// torrentId -> 上次观测到的已下载字节数
  final Map<PlatformInt64, int> _lastDownloaded = {};

  /// torrentId -> 连续无增长的轮询次数
  final Map<PlatformInt64, int> _noProgressTicks = {};
```

<!-- TASK1_MORE -->

- [ ] **Step 4: resolve 返回 Playable 带 cacheStream**

`resolve` 里构造 `Playable` 时加 `cacheStream`（cacheKey 已有）：

```dart
    final key = _cacheKeyOf(torrentId);
    return Playable(
      url: Uri.parse(handle.streamUrl),
      headers: {'Authorization': handle.authHeader},
      cacheKey: key,
      cacheStream: cacheRegistry.watch(key),
    );
```

（即把原先的 `cacheKey: _cacheKeyOf(torrentId)` 改为先取 `key`，再同时传 `cacheKey` 和 `cacheStream`。）

- [ ] **Step 5: _poll 里计算停滞状态**

把 `_poll` 中构造 `CacheEntry` 的那段替换为带停滞判定的逻辑：

```dart
      final downloaded = p.downloadedBytes.toInt();
      final CacheState state;
      if (p.finished) {
        state = CacheState.complete;
        _noProgressTicks.remove(torrentId);
      } else {
        final last = _lastDownloaded[torrentId];
        if (last == null || downloaded > last) {
          _noProgressTicks[torrentId] = 0;
          state = CacheState.active;
        } else {
          final ticks = (_noProgressTicks[torrentId] ?? 0) + 1;
          _noProgressTicks[torrentId] = ticks;
          state = ticks >= _stallThresholdTicks
              ? CacheState.stalled
              : CacheState.active;
        }
      }
      _lastDownloaded[torrentId] = downloaded;
      cacheRegistry.update(CacheEntry(
        cacheKey: _cacheKeyOf(torrentId),
        totalBytes: p.totalBytes?.toInt(),
        completed: downloaded > 0 ? [ByteRange(0, downloaded)] : const [],
        state: state,
      ));
```

- [ ] **Step 6: release 最后持有时清理停滞状态**

在 `release` 里 `_idHolds` 归零的分支（取消轮询、`cacheRegistry.remove` 处）追加两行：

```dart
      _lastDownloaded.remove(torrentId);
      _noProgressTicks.remove(torrentId);
```

- [ ] **Step 7: 验证**

Run: `flutter analyze`
Expected: No issues found.

- [ ] **Step 8: Commit（只 add 这三个文件，勿碰 home_page.dart）**

```bash
git add lib/src/source/cache_registry.dart lib/src/source/playable.dart lib/src/source/p2p_provider.dart
git commit -m "feat: P2P 下载停滞检测，经 CacheState.stalled 暴露给 UI"
```

<!-- TASK2 -->

## Task 2: PlayerPage 状态机 —— 错误/停滞覆盖提示 + 重试

**Files:**
- Modify: `lib/src/ui/player_page.dart`（完整重写）

**Interfaces:**
- Consumes: `PlaybackController`（`error` 流、`videoController`、`open`、`dispose`）、`SourceRegistry`、`MediaRef`、`Playable.cacheStream`、`CacheEntry`/`CacheState`
- Produces: 无对外接口（页面内部状态机）

**行为：**
- 致命错误（resolve 抛错 / libmpv `error` 流）→ 错误页 + "重试"。
- 下载停滞（`CacheState.stalled`）→ 画面上覆盖半透明提示"无可用 peer，连接中…" + "重试"；恢复 `active`/`complete` 时自动撤除。
- 重试 = 释放旧持有、用**新的 `MediaRef` 实例**重新加载（P2PProvider 按实例记账，必须换新实例）。

> 设计前提：`cacheStream`（`CacheRegistry.watch`）是 broadcast 流，不回放当前值。这里无需回放——订阅在 `resolve` 返回后、首个轮询发射（约 1s）之前即建立，而停滞需连续 30 ticks（约 30s）才触发，订阅永远先于任何发射。不要为此改 `CacheRegistry`（会与 M3 其它批次耦合）。

- [ ] **Step 1: 重写 player_page.dart（import 与状态字段）**

```dart
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
```

<!-- TASK2_LOAD -->

- [ ] **Step 2: _load / 订阅 / _retry / dispose**

```dart
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
```

<!-- TASK2_BUILD -->

- [ ] **Step 3: build**

```dart
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
```

- [ ] **Step 4: 验证**

Run: `flutter analyze`
Expected: No issues found.

Run: `flutter build macos --release`
Expected: Built。可选真机：release 版 open，点 HLS 正常播放、左上角返回可用；P2P 停滞/错误提示需配合本机做种端断流才能触发（见 `.mapdev/sdd/project_p2p_demo` 记录），不在本任务强制验收内，如未触发如实说明。

- [ ] **Step 5: Commit（只 add player_page.dart）**

```bash
git add lib/src/ui/player_page.dart
git commit -m "feat: 播放页错误/停滞覆盖提示与重试"
```





