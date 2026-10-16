# siplayer 播放内核与源层 实现计划（M1 + M2）

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 macOS 上做出一个能播公开 HLS 流、并能对合法 magnet 边下边播的播放内核，源层可插拔。

**Architecture:** Flutter 承载 UI 与播放状态机（media_kit/libmpv）。源层是 `SourceProvider` 协议，把任意来源 `resolve` 成一个播放器唯一入口 `Playable`。P2P 源经 flutter_rust_bridge 调 Rust 侧 librqbit，收敛为一个本地 `127.0.0.1` HTTP 流 URL，播放器不感知源类型。

**Tech Stack:** Flutter 3.x / Dart、media_kit + media_kit_video（libmpv）、librqbit 9.x（Rust）、flutter_rust_bridge。

## Global Constraints

- 平台：本计划仅覆盖 **macOS**。扩端（Windows/Android/Web）属后续里程碑，不在本计划内。
- 源层内容边界：仓库只内置本地文件 / 自建后端直链 / 公开合法流 / 用户自备 magnet。不内置任何第三方影视站爬取、签名绕过、加密流解析、盗版索引。
- 本地 HTTP server 必须绑 `127.0.0.1` + 随机端口 + librqbit basic auth；凭据不写日志、不写缓存元数据。
- P2P 被收敛为一个 HTTP URL，播放器不感知源类型；播放/进度/字幕/音轨逻辑只写一份。
- 测试策略：按项目规则**默认不写单测**。每个任务以可直接执行的验证收尾——`flutter analyze`（无新增告警）、`flutter build macos` / `flutter run -d macos`（构建/运行通过）、以及明确的手动验证点。
- 超时阈值集中为可配置常量：metadata 默认 60s、读取停滞默认 30s。
- commit message 用普通语义化格式（本项目不套用公司 FE 规范/卡片号）。

---

## 文件结构

M1（纯 Dart）：

- `pubspec.yaml` — 依赖：media_kit、media_kit_video、media_kit_libs_macos_video
- `macos/Runner/*.entitlements` — 加 `com.apple.security.network.client`
- `lib/src/source/media_ref.dart` — `MediaRef` 值对象
- `lib/src/source/playable.dart` — `Playable` / `SubtitleTrack` 值对象
- `lib/src/source/source_provider.dart` — `SourceProvider` 抽象 + `SourceRegistry`
- `lib/src/source/http_stream_provider.dart` — `HttpStreamProvider`
- `lib/src/playback/playback_controller.dart` — 包装 media_kit Player
- `lib/src/ui/player_page.dart` — 播放页
- `lib/main.dart` — 入口 + media_kit 初始化

M2（新增 Rust + 桥接）：

- `rust/Cargo.toml`、`rust/src/api/p2p.rs` — librqbit Session 封装
- `lib/src/source/p2p_provider.dart` — `P2PProvider`
- `lib/src/bridge/` — flutter_rust_bridge 生成产物
- `lib/src/source/cache_registry.dart` — `CacheEntry` 模型（P2P 进度来源）

---

## Task 1: Flutter 工程骨架 + media_kit 依赖 + macOS 网络权限

**Files:**
- Create: `pubspec.yaml`（由 flutter create 生成后修改）
- Create: 整个 Flutter 工程骨架
- Modify: `macos/Runner/DebugProfile.entitlements`、`macos/Runner/Release.entitlements`

**Interfaces:**
- Consumes: 无
- Produces: 一个可 `flutter run -d macos` 启动的空壳应用，media_kit 依赖已就位

- [ ] **Step 1: 初始化工程**

在仓库根执行（工程直接生成到当前目录）：

```bash
cd /Users/hyn/Documents/myProject/siplayer
flutter create --project-name siplayer --org com.siplayer --platforms=macos .
```

- [ ] **Step 2: 加依赖**

编辑 `pubspec.yaml`，在 `dependencies:` 下加：

```yaml
  media_kit: ^1.1.11
  media_kit_video: ^1.2.5
  media_kit_libs_macos_video: ^1.1.4
```

执行 `flutter pub get`，预期成功无报错。

- [ ] **Step 3: 开 macOS 网络权限**

在 `macos/Runner/DebugProfile.entitlements` 与 `macos/Runner/Release.entitlements` 的 `<dict>` 内各加一行（Release 下不加会被沙箱拦掉网络请求）：

```xml
	<key>com.apple.security.network.client</key>
	<true/>
```

- [ ] **Step 4: 验证构建与运行**

Run: `flutter analyze`
Expected: No issues found.

Run: `flutter run -d macos`
Expected: 空白 Flutter 计数器应用正常启动，无崩溃。手动确认窗口能打开后关闭。

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: 初始化 Flutter macOS 工程并接入 media_kit"
```

## Task 2: 源层值对象（MediaRef / Playable）

**Files:**
- Create: `lib/src/source/media_ref.dart`
- Create: `lib/src/source/playable.dart`

**Interfaces:**
- Consumes: 无
- Produces:
  - `class MediaRef { final String sourceId; final String locator; final int? fileIndex; const MediaRef(...) }`
  - `class Playable { final Uri url; final Map<String,String> headers; final List<SubtitleTrack> subtitles; final String? cacheKey; const Playable(...) }`
  - `class SubtitleTrack { final String id; final String label; final Uri uri; const SubtitleTrack(...) }`

- [ ] **Step 1: 写 MediaRef**

`lib/src/source/media_ref.dart`:

```dart
/// 一次播放请求的来源描述，不含播放状态。
class MediaRef {
  /// 'http' | 'local' | 'p2p'
  final String sourceId;

  /// URL / 本地路径 / magnet 链接
  final String locator;

  /// 多文件 torrent 内的文件下标；非 torrent 源为 null
  final int? fileIndex;

  const MediaRef({
    required this.sourceId,
    required this.locator,
    this.fileIndex,
  });
}
```

- [ ] **Step 2: 写 Playable 与 SubtitleTrack**

`lib/src/source/playable.dart`:

```dart
/// 播放器唯一入口：任何源 resolve 后都变成它。
class Playable {
  final Uri url;
  final Map<String, String> headers;
  final List<SubtitleTrack> subtitles;

  /// 为空表示不参与缓存登记
  final String? cacheKey;

  const Playable({
    required this.url,
    this.headers = const {},
    this.subtitles = const [],
    this.cacheKey,
  });
}

class SubtitleTrack {
  final String id;
  final String label;
  final Uri uri;

  const SubtitleTrack({
    required this.id,
    required this.label,
    required this.uri,
  });
}
```

- [ ] **Step 3: 验证**

Run: `flutter analyze lib/src/source/media_ref.dart lib/src/source/playable.dart`
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add lib/src/source/media_ref.dart lib/src/source/playable.dart
git commit -m "feat: 源层值对象 MediaRef 与 Playable"
```

## Task 3: SourceProvider 协议 + SourceRegistry

**Files:**
- Create: `lib/src/source/source_provider.dart`

**Interfaces:**
- Consumes: `MediaRef`、`Playable`（Task 2）
- Produces:
  - `abstract class SourceProvider { String get id; bool get isAvailableOnThisPlatform; Future<Playable> resolve(MediaRef ref); Future<void> release(MediaRef ref); }`
  - `class SourceNotAvailableException implements Exception { final String sourceId; final String reason; }`
  - `class SourceRegistry { void register(SourceProvider p); Future<Playable> resolve(MediaRef ref); Future<void> release(MediaRef ref); SourceProvider? providerFor(String sourceId); }`

- [ ] **Step 1: 写协议与注册表**

`lib/src/source/source_provider.dart`:

```dart
import 'media_ref.dart';
import 'playable.dart';

/// 把 MediaRef 变成可播 URL；不碰播放状态，不碰 UI。
abstract class SourceProvider {
  String get id;

  /// 当前平台是否支持此源（Web 上 P2PProvider 返回 false）。
  bool get isAvailableOnThisPlatform;

  Future<Playable> resolve(MediaRef ref);

  /// 停止 torrent / 关闭句柄。
  Future<void> release(MediaRef ref);
}

class SourceNotAvailableException implements Exception {
  final String sourceId;
  final String reason;
  const SourceNotAvailableException(this.sourceId, this.reason);

  @override
  String toString() => 'SourceNotAvailable($sourceId): $reason';
}

class SourceRegistry {
  final Map<String, SourceProvider> _providers = {};

  void register(SourceProvider p) => _providers[p.id] = p;

  SourceProvider? providerFor(String sourceId) => _providers[sourceId];

  Future<Playable> resolve(MediaRef ref) {
    final p = _providers[ref.sourceId];
    if (p == null) {
      throw SourceNotAvailableException(ref.sourceId, '未注册的源');
    }
    if (!p.isAvailableOnThisPlatform) {
      throw SourceNotAvailableException(ref.sourceId, '当前平台不支持该源');
    }
    return p.resolve(ref);
  }

  Future<void> release(MediaRef ref) async {
    await _providers[ref.sourceId]?.release(ref);
  }
}
```

- [ ] **Step 2: 验证**

Run: `flutter analyze lib/src/source/source_provider.dart`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add lib/src/source/source_provider.dart
git commit -m "feat: SourceProvider 协议与 SourceRegistry"
```

## Task 4: HttpStreamProvider

**Files:**
- Create: `lib/src/source/http_stream_provider.dart`

**Interfaces:**
- Consumes: `SourceProvider`、`MediaRef`、`Playable`
- Produces: `class HttpStreamProvider extends SourceProvider`（`id == 'http'`）

- [ ] **Step 1: 写实现**

`lib/src/source/http_stream_provider.dart`:

```dart
import 'media_ref.dart';
import 'playable.dart';
import 'source_provider.dart';

/// 直链 / HLS / DASH 源。locator 即可播放 URL。
class HttpStreamProvider extends SourceProvider {
  @override
  String get id => 'http';

  @override
  bool get isAvailableOnThisPlatform => true;

  @override
  Future<Playable> resolve(MediaRef ref) async {
    final uri = Uri.parse(ref.locator);
    return Playable(url: uri, cacheKey: null);
  }

  @override
  Future<void> release(MediaRef ref) async {
    // HTTP 源无需释放资源。
  }
}
```

- [ ] **Step 2: 验证**

Run: `flutter analyze lib/src/source/http_stream_provider.dart`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add lib/src/source/http_stream_provider.dart
git commit -m "feat: HttpStreamProvider 直链/HLS 源"
```

## Task 5: PlaybackController

**Files:**
- Create: `lib/src/playback/playback_controller.dart`

**Interfaces:**
- Consumes: `Playable`、media_kit 的 `Player`/`VideoController`
- Produces:
  - `class PlaybackController { VideoController get videoController; Stream<Duration> get position; Stream<Duration> get duration; Stream<bool> get buffering; Stream<bool> get playing; Stream<String> get error; Stream<Tracks> get tracks; Future<void> open(Playable p); Future<void> playOrPause(); Future<void> seek(Duration to); Future<void> dispose(); }`
  - `tracks` 暴露 media_kit 的 `Tracks`（含 `audio`/`subtitle`/`video` 轨列表），供成功标准 1 的音轨/字幕轨枚举验证

- [ ] **Step 1: 写实现**

`lib/src/playback/playback_controller.dart`:

```dart
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../source/playable.dart';

/// 包装 media_kit Player，不感知源类型。
class PlaybackController {
  final Player _player = Player();
  late final VideoController _videoController = VideoController(_player);

  VideoController get videoController => _videoController;

  Stream<Duration> get position => _player.stream.position;
  Stream<Duration> get duration => _player.stream.duration;
  Stream<bool> get buffering => _player.stream.buffering;
  Stream<bool> get playing => _player.stream.playing;

  /// 播放错误流，供 §6 错误处理（swarm 断流/停滞上报）后续接入。
  Stream<String> get error => _player.stream.error;

  /// 音轨/字幕轨/视频轨列表，供枚举与选择。
  Stream<Tracks> get tracks => _player.stream.tracks;

  Future<void> open(Playable p) async {
    // 自定义 header 透传给 libmpv 的 http-header-fields。
    // 注：Playable.subtitles 的外挂字幕注入留后续里程碑，M1/M2 两个 Provider 均不填充该字段。
    await _player.open(
      Media(p.url.toString(), httpHeaders: p.headers),
      play: true,
    );
  }

  Future<void> playOrPause() => _player.playOrPause();
  Future<void> seek(Duration to) => _player.seek(to);

  Future<void> dispose() async {
    await _player.dispose();
  }
}
```

- [ ] **Step 2: 验证**

Run: `flutter analyze lib/src/playback/playback_controller.dart`
Expected: No issues found（若 `Media` 无 `httpHeaders` 命名参数，按当前 media_kit 版本 API 改为对应写法，并记录差异）。

- [ ] **Step 3: Commit**

```bash
git add lib/src/playback/playback_controller.dart
git commit -m "feat: PlaybackController 包装 media_kit"
```

## Task 6: 播放页 UI + 入口接线，播通 HLS（M1 收口）

**Files:**
- Create: `lib/src/ui/player_page.dart`
- Modify: `lib/main.dart`

**Interfaces:**
- Consumes: `PlaybackController`、`SourceRegistry`、`HttpStreamProvider`、`MediaRef`
- Produces: 可运行的 app，打开即播一条公开 HLS 测试流，带播放/暂停与 seek

- [ ] **Step 1: 写播放页**

`lib/src/ui/player_page.dart`:

```dart
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
```

- [ ] **Step 2: 接线入口**

`lib/main.dart`:

```dart
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
```

- [ ] **Step 3: 验证（M1 成功标准 1）**

Run: `flutter analyze`
Expected: No issues found.

Run: `flutter run -d macos`
Expected: 应用启动后自动播放该 HLS 测试流，画面出现。手动验证：暂停/恢复生效、拖动进度可 seek、媒体信息里能看到音轨/字幕轨列表（用 `_controller` 暴露的 track 流打印或临时 UI 确认）。

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: 播放页接通 HLS 流（M1 收口）"
```

## Task 7: 先验 auth header 透传链路（M2 前置）

独立验证 `PlaybackController` 能把自定义 header 透传给 libmpv，避免后面接 librqbit 时分不清是 header 问题还是 piece 调度问题。

**Files:**
- 无新增代码；临时改 `lib/main.dart` 的 demo ref 做验证，验证后还原

**Interfaces:**
- Consumes: `PlaybackController`（Task 5）
- Produces: 结论——media_kit 对 `httpHeaders` 的透传路径确认可用

- [ ] **Step 1: 用带 basic auth 的测试源验证**

临时把 demo 改为一个需要 header 的源（例如自建一条带 `Authorization` 校验的本地 HTTP 流，或任意需要自定义 header 的测试端点），给 `Playable.headers` 传入对应键值，`flutter run -d macos` 确认能播。

若 media_kit 当前版本 `Media(...)` 不支持 `httpHeaders`，改用其 `httpHeaders` 等效 API（查 media_kit 文档），并同步修正 Task 5 的 `PlaybackController.open`。

- [ ] **Step 2: 还原 demo**

验证通过后把 `lib/main.dart` 的 demo ref 还原为 HLS 测试流。无代码残留则无需 commit；若修正了 Task 5 的 API：

```bash
git add lib/src/playback/playback_controller.dart
git commit -m "fix: 校正 media_kit 自定义 header 透传 API"
```

## Task 8: Rust crate 骨架 + flutter_rust_bridge 接入（macOS）

**Files:**
- Create: `rust/Cargo.toml`、`rust/src/lib.rs`、`rust/src/api/mod.rs`、`rust/src/api/simple.rs`
- Modify: `pubspec.yaml`（加 `flutter_rust_bridge`）、工程构建配置（flutter_rust_bridge_codegen 生成）

**Interfaces:**
- Consumes: 无
- Produces: 一个能从 Dart 调用的 Rust 函数（如 `greet() -> String`），证明 macOS 下 FRB 通路打通

- [ ] **Step 1: 安装 FRB 工具链**

```bash
cargo install flutter_rust_bridge_codegen
flutter pub add flutter_rust_bridge
```

- [ ] **Step 2: 用 FRB 模板初始化 rust 侧**

按 flutter_rust_bridge 官方 integrate 流程（以实际版本文档为准）生成 `rust/` crate 与桥接骨架。`rust/Cargo.toml` 至少包含：

```toml
[package]
name = "rust"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib", "staticlib"]

[dependencies]
flutter_rust_bridge = "2"
```

- [ ] **Step 3: 写一个探活函数**

`rust/src/api/simple.rs`:

```rust
#[flutter_rust_bridge::frb(sync)]
pub fn greet() -> String {
    "siplayer rust bridge ok".to_string()
}
```

- [ ] **Step 4: 生成桥接代码并验证**

```bash
flutter_rust_bridge_codegen generate
```

在 `lib/main.dart` 临时调用 `greet()` 打印返回值，`flutter run -d macos` 确认控制台输出 `siplayer rust bridge ok`。验证后移除临时调用。

Run: `flutter analyze` 与 `cargo clippy --manifest-path rust/Cargo.toml`
Expected: 均无新增告警。

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: 接入 flutter_rust_bridge（macOS 通路）"
```

## Task 9: Rust 侧 librqbit Session 封装

**Files:**
- Modify: `rust/Cargo.toml`（加 librqbit）
- Create: `rust/src/api/p2p.rs`

**Interfaces:**
- Consumes: librqbit `Session`/`Api`
- Produces（经 FRB 暴露给 Dart）：
  - `async fn p2p_start(magnet: String, file_index: Option<u32>) -> P2pHandle`
  - `struct P2pHandle { stream_url: String, auth_header: String, torrent_id: i64 }`
  - `async fn p2p_progress(torrent_id: i64) -> P2pProgress`（`{ total_bytes: Option<u64>, downloaded_bytes: u64, finished: bool }`）
  - `async fn p2p_release(torrent_id: i64)`

- [ ] **Step 1: 加依赖**

`rust/Cargo.toml` 的 `[dependencies]` 加（版本以实际 crate 文档为准）：

```toml
librqbit = "9"
tokio = { version = "1", features = ["full"] }
anyhow = "1"
```

- [ ] **Step 2: 写 Session 封装骨架**

`rust/src/api/p2p.rs`（librqbit 的 streaming/HTTP API 细节以 9.x docs.rs 为准，这里是结构骨架）：

```rust
use std::sync::OnceLock;
use librqbit::Session;

static SESSION: OnceLock<std::sync::Arc<Session>> = OnceLock::new();

pub struct P2pHandle {
    pub stream_url: String,
    pub auth_header: String,
    pub torrent_id: i64,
}

pub struct P2pProgress {
    pub total_bytes: Option<u64>,
    pub downloaded_bytes: u64,
    pub finished: bool,
}

async fn session() -> std::sync::Arc<Session> {
    // 下载目录与 basic-auth 凭据在首次创建时固定；
    // HTTP server 绑 127.0.0.1 + 随机端口（librqbit 配置）。
    // 实际初始化参数以 librqbit 9.x API 为准。
    SESSION.get().expect("session not initialized").clone()
}
```

> 本任务只落地「加 torrent → 等 metadata → 返回带 auth 的本地 stream URL → 进度查询 → release」四个函数。首尾 piece 优先级提升若 librqbit 默认未覆盖，在 `p2p_start` 内显式设置。

- [ ] **Step 3: 落地 §7 安全配置（显式实现，非注释）**

在 Session 初始化处显式完成以下三项（spec §7 硬约束），并在代码中以具体参数体现，不得仅留注释：

1. HTTP server 绑定地址固定为 `127.0.0.1`，端口取随机空闲端口（绑定失败则换端口重试）。
2. 启用 librqbit basic auth：进程启动时生成随机 user:pass 凭据，仅在进程内保存，`p2p_start` 把它拼成 `Authorization` 头随 `P2pHandle.auth_header` 返回。
3. 日志中不打印 magnet 完整内容与 auth 凭据（magnet 只打印 infohash 前缀）。

- [ ] **Step 4: 实现四个 async 函数并标注 FRB**

按 §Interfaces 的签名实现 `p2p_start` / `p2p_progress` / `p2p_release`，均加 `#[flutter_rust_bridge::frb]`。`p2p_start` 内设 metadata 超时常量 `METADATA_TIMEOUT_SECS = 60`。读取停滞检测（`READ_STALL_SECS = 30`，断流上报「无可用 peer」）本任务只定义常量，检测逻辑延后到边下边播稳定后补，不阻塞 M2 happy-path 验收。

- [ ] **Step 5: 验证**

Run: `cargo clippy --manifest-path rust/Cargo.toml`
Expected: 无新增告警。

Run: `flutter_rust_bridge_codegen generate && flutter analyze`
Expected: 桥接生成成功，analyze 无告警。

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: Rust 侧 librqbit Session 封装与 P2P 接口"
```

## Task 10: CacheRegistry 模型

**Files:**
- Create: `lib/src/source/cache_registry.dart`

**Interfaces:**
- Consumes: 无（数据由 Task 11 的 P2PProvider 喂入）
- Produces:
  - `enum CacheState { unsupported, active, complete, error }`
  - `class ByteRange { final int start; final int end; }`
  - `class CacheEntry { final String cacheKey; final int? totalBytes; final List<ByteRange> completed; final CacheState state; }`
  - `class CacheRegistry { void update(CacheEntry e); CacheEntry? of(String cacheKey); Stream<CacheEntry> watch(String cacheKey); }`

- [ ] **Step 1: 写模型**

`lib/src/source/cache_registry.dart`:

```dart
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
```

- [ ] **Step 2: 验证**

Run: `flutter analyze lib/src/source/cache_registry.dart`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add lib/src/source/cache_registry.dart
git commit -m "feat: CacheRegistry 统一缓存区间模型"
```

## Task 11: P2PProvider + 边下边播接线（M2 收口）

**Files:**
- Create: `lib/src/source/p2p_provider.dart`
- Modify: `lib/main.dart`（注册 P2PProvider，加一个 magnet demo 入口）

**Interfaces:**
- Consumes: Task 9 的 FRB 函数（`p2pStart`/`p2pProgress`/`p2pRelease`）、`CacheRegistry`、`SourceProvider`、`Playable`
- Produces: `class P2PProvider extends SourceProvider`（`id == 'p2p'`）

- [ ] **Step 1: 写 P2PProvider**

`lib/src/source/p2p_provider.dart`:

```dart
import 'dart:async';
import 'dart:io' show Platform;

import 'cache_registry.dart';
import 'media_ref.dart';
import 'playable.dart';
import 'source_provider.dart';
// import '../bridge/...'; // FRB 生成的 p2pStart / p2pProgress / p2pRelease

class P2PProvider extends SourceProvider {
  final CacheRegistry cacheRegistry;
  final Map<String, int> _torrentIds = {}; // locator -> torrentId
  final Map<String, Timer> _pollers = {};

  P2PProvider(this.cacheRegistry);

  @override
  String get id => 'p2p';

  @override
  bool get isAvailableOnThisPlatform {
    // Web 无 P2P；桌面/移动可用。kIsWeb 判断见注。
    return Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isAndroid ||
        Platform.isIOS;
  }

  @override
  Future<Playable> resolve(MediaRef ref) async {
    final handle = await p2pStart(
      magnet: ref.locator,
      fileIndex: ref.fileIndex,
    );
    _torrentIds[ref.locator] = handle.torrentId;
    final key = 'p2p:${handle.torrentId}';
    _startPolling(ref.locator, handle.torrentId, key);
    return Playable(
      url: Uri.parse(handle.streamUrl),
      headers: {'Authorization': handle.authHeader},
      cacheKey: key,
    );
  }

  void _startPolling(String locator, int torrentId, String key) {
    _pollers[locator]?.cancel();
    _pollers[locator] =
        Timer.periodic(const Duration(seconds: 1), (_) async {
      final p = await p2pProgress(torrentId: torrentId);
      cacheRegistry.update(CacheEntry(
        cacheKey: key,
        totalBytes: p.totalBytes,
        completed: [if (p.downloadedBytes > 0) ByteRange(0, p.downloadedBytes)],
        state: p.finished ? CacheState.complete : CacheState.active,
      ));
    });
  }

  @override
  Future<void> release(MediaRef ref) async {
    _pollers.remove(ref.locator)?.cancel();
    final id = _torrentIds.remove(ref.locator);
    if (id != null) {
      await p2pRelease(torrentId: id);
    }
  }
}
```

> 注：Web 构建用 `kIsWeb`（`package:flutter/foundation.dart`）短路为 `false`，避免 `dart:io` 的 `Platform` 在 Web 报错。实现时按平台条件导入处理。`p2pProgress` 返回的 downloaded 是「已下载字节数」近似，M2 先用单区间 `[0, downloaded]` 表达；精确多区间留 M3。

- [ ] **Step 2: 接线 magnet demo 入口**

`lib/main.dart` 注册 `P2PProvider(cacheRegistry)`，并提供一个入口用合法 magnet（如 Internet Archive 公共领域影片）构造 `MediaRef(sourceId: 'p2p', locator: <magnet>)` 进入 `PlayerPage`。

- [ ] **Step 3: 验证（M2 成功标准 2）**

Run: `flutter analyze` 与 `cargo clippy --manifest-path rust/Cargo.toml`
Expected: 均无新增告警。

Run: `flutter run -d macos`
手动验证：
- 选 magnet demo → 下载未完成时即开始播放。
- 播放中 seek 到靠后未下载位置 → 短暂 buffering 后继续播放（librqbit 重排 piece）。
- 返回上一页 → `release()` 被调用，torrent 停止（Rust 日志确认无残留 swarm 活动）。

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: P2PProvider 边下边播接通（M2 收口）"
```

---

## 验收清单（M1 + M2）

- [ ] macOS 播通公开 HLS 流，可暂停/seek、能枚举音轨字幕轨（成功标准 1）
- [ ] macOS 合法 magnet 边下边播，可 seek 到未下载区间（成功标准 2）
- [ ] `CacheRegistry` 模型落地并能接收 P2P 进度（**仅模型**；进度条着色 UI 属 M3，不在本计划）
- [ ] 本地 HTTP server 绑 127.0.0.1 + 随机端口 + basic auth，凭据不入日志（§7 安全）
- [ ] `flutter analyze` 无告警；`cargo clippy` 无告警（成功标准 5）











