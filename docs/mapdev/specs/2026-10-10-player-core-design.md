# siplayer 播放内核与源层设计（子项目 1）

- 日期：2026-10-10
- 状态：待评审
- 技术栈：Flutter + media_kit(libmpv) + librqbit(Rust)

## 1. 背景与范围

siplayer 的最终形态是一个「带 AI 观看顺序整理」的影视播放器。整体拆为两个子项目，本文档只覆盖子项目 1：

- **子项目 1（本文档）**：能播、能缓存的播放内核 + 可插拔源层，同时支持 P2P 与普通流媒体。
- **子项目 2（后续独立 spec）**：观看顺序引擎（多方案推荐、来源理由、diff、手动调整）。

本子项目**不包含**观看顺序引擎、转码、字幕在线搜索、账号云同步、媒体库刮削。

### 内容来源边界（硬约束）

源层是**插件协议**。仓库内置实现仅限：本地文件、自建后端直链/HLS、公开合法流（Internet Archive、公共领域影片、HLS 测试流）、用户自行提供的 magnet/torrent。

仓库**不内置**任何第三方影视站的爬取、签名绕过、加密流解析或盗版资源索引/搜索能力。P2P 层只负责传输，不负责发现内容。

## 2. 目标与成功标准

子项目 1 完成的判定标准：

1. 在 macOS 上能播放一条公开 HLS 测试流，可暂停、seek，并能正确枚举音轨与字幕轨列表。
2. 在 macOS 上给一个合法 magnet（如 Internet Archive 公共领域影片），能在下载未完成时开始播放，并能 seek 到未下载区间后继续播放。
3. P2P 源的播放页进度条能显示真实「已缓存区间」着色；HTTP 源复用同一播放页与同一进度条组件，但不显示缓存着色（见 §4.4）。
4. Web 端构建通过，且 P2P 入口被置灰并给出原因文案、不崩溃。「Web 端能播 HLS」为**非阻塞目标**：Safari 原生支持 HLS 可直接验证，其他浏览器需额外方案，不在本子项目范围内。
5. `flutter analyze` 无新增告警；`cargo clippy` 自 M2（引入 Rust 代码）起生效，同样要求无新增告警。


## 3. 架构

核心设计决策：**P2P 源被收敛成一个本地 HTTP URL**，播放器不感知源类型。

```
UI (Flutter)
  |
PlaybackController          播放状态机，只认一个 playable URL
  |
SourceProvider 协议         resolve(MediaRef) -> Playable
  |-- HttpStreamProvider    直链 / HLS / DASH
  |-- LocalFileProvider     本地文件（后期 WebDAV/SMB）
  |-- P2PProvider           magnet/torrent -> 本地 HTTP 流 URL
         |
      librqbit Session (Rust, 经 flutter_rust_bridge)
         |
      127.0.0.1:<随机端口>/torrent/<id>/stream/<fileIdx>
  |
CacheRegistry               统一的「已完成区间」模型，两类源共用
```

这一层收敛带来三个直接收益：seek 走 HTTP Range 头穿透到 librqbit 的 piece 调度器；播放、进度、字幕、音轨逻辑只写一份；新增源类型（WebDAV、自建后端）不触碰播放层。

## 4. 组件

### 4.1 SourceProvider 协议（Dart）

```dart
class MediaRef {
  final String sourceId;   // 'http' | 'local' | 'p2p'
  final String locator;    // URL / 文件路径 / magnet
  final int? fileIndex;    // 多文件 torrent 内的文件下标
}

class Playable {
  final Uri url;                       // 播放器唯一入口
  final Map<String, String> headers;   // Referer / Authorization 等
  final List<SubtitleTrack> subtitles;
  final String? cacheKey;              // 为空表示不参与缓存登记
}

abstract class SourceProvider {
  String get id;
  bool get isAvailableOnThisPlatform;  // Web 上 P2PProvider 返回 false
  Future<Playable> resolve(MediaRef ref);
  Future<void> release(MediaRef ref);  // 停止 torrent / 关闭句柄
}
```

职责边界：Provider 只负责「把 MediaRef 变成一个能播的 URL」，不碰播放状态，不碰 UI。

### 4.2 PlaybackController

包装 `media_kit` 的 `Player` + `VideoController`。输入 `Playable`，对外暴露播放状态流（position / duration / buffering / error / 音轨 / 字幕轨）。不知道源类型，不知道 librqbit 存在。

### 4.3 P2PProvider 与 Rust 侧

- Rust 侧用 `librqbit::Session` 常驻一个实例，下载目录可配置。
- `resolve()` 流程：加入 torrent → 等待 metadata → 选定文件下标 → 返回 librqbit 的 stream URL。
- `librqbit` 自带顺序 piece 优先与「阻塞到数据就位」，不自行实现 piece 调度。
- 首尾 piece 需提前抓取（mp4 的 moov、mkv 的 cues 可能在尾部，缺失则无法 seek）。若 librqbit 默认策略未覆盖，在 `resolve()` 后显式提升首尾 piece 优先级。
- `release()` 必须停止 torrent 并取消文件句柄，否则退出播放页后仍在跑 swarm。
- librqbit 启用 basic auth（见 §7），`P2PProvider` 把凭据写入 `Playable.headers`，由 `PlaybackController` 透传给 libmpv 的 `http-header-fields` 属性。这条链路是已知易踩点，实现时需先验证 media_kit 对自定义 header 的透传路径。

### 4.4 CacheRegistry

统一模型，让播放页进度条组件只认一种数据结构：

```dart
class CacheEntry {
  final String cacheKey;
  final int? totalBytes;            // metadata 未就位时为 null
  final List<ByteRange> completed;  // 已落盘区间
  final CacheState state;           // unsupported | active | complete | error
}
```

- **P2P 源**：区间由 librqbit 的 piece 完成状态换算得到，天然落盘，是本子项目唯一有真实缓存区间的源。
- **HTTP / 本地源**：`state == unsupported`，`completed` 为空，进度条不渲染缓存着色。**本子项目不实现 HTTP 分段下载落盘缓存**——它涉及并发分段策略、落盘格式、断点续传、与 libmpv 自身 Range 读取的协同，规模接近 P2P 侧，留作独立后续子项目。
- **Web 端**：无 P2P，故所有源均为 `unsupported`，不暴露下载入口。


## 5. 数据流（P2P 播放一次）

1. UI 传入 `MediaRef(sourceId: 'p2p', locator: magnet)`。
2. `SourceRegistry` 按 `sourceId` 选中 `P2PProvider`；若 `isAvailableOnThisPlatform == false`（Web），立即返回明确的不可用状态，UI 置灰并给出原因文案。
3. `P2PProvider.resolve()` 经 flutter_rust_bridge 调 Rust：加 torrent、等 metadata、拿 stream URL。
4. `PlaybackController.open(playable)` → libmpv 以普通 HTTP 源打开。
5. libmpv 的 Range 请求打到本地 server → librqbit 按需重排 piece 优先级并阻塞至数据就位。
6. `CacheRegistry` 订阅 Rust 侧进度事件，更新已完成区间，进度条着色。
7. 退出播放页 → `PlaybackController.dispose()` → `P2PProvider.release()` 停 torrent。

## 6. 错误处理

- **metadata 超时**（magnet 拿不到 peer）：`resolve()` 设超时，超时返回可重试错误，不卡死 UI。
- **播放中 swarm 断流**：librqbit 会阻塞读取导致 libmpv 卡在 buffering。需设读取停滞阈值，超阈值上报「无可用 peer」并提供重试。
- 上述两个阈值（默认 metadata 60s、读取停滞 30s）集中定义为可配置常量，便于调试期调整。
- **格式不支持**：Web 端 HTML5 播放失败属预期，错误文案必须说明是浏览器限制，并提示桌面端可播。
- **端口占用**：本地 server 绑随机端口，启动失败则重试其他端口，连续失败上报。
- **Range 不支持的 HTTP 源**：seek 能力降级为不可 seek，UI 明示而非静默失败。

## 7. 安全

- 本地 HTTP server **必须**绑 `127.0.0.1`、随机端口，并启用 librqbit 的 basic auth（进程启动时生成随机凭据，仅在进程内传递）。否则同机任意进程或恶意网页可枚举并拉取本地媒体流。
- 不在日志中打印 magnet 完整内容与 auth 凭据。
- `Playable.headers` 中的凭据不写入缓存元数据文件。

## 8. 平台能力矩阵（明确不对等）

- **macOS / Windows**：全功能，P2P + libmpv 任意格式。
- **Android**：全功能。librqbit 为 Rust 交叉编译产物（`aarch64-linux-android` 等 target + NDK toolchain，经 flutter_rust_bridge 接入），**不引入 C++ libtorrent**。
- **iOS**：技术可跑，但 App Store 不接收 BT 客户端，仅自签 / TestFlight 分发，需接受证书有效期限制。
- **Web**：**无 P2P**（浏览器仅支持 WebRTC，无法接入普通 BT swarm）；退化为 HTTP/HLS，格式受浏览器限制，无缓存能力。

这份不对等是设计约束而非缺陷，UI 必须按平台能力裁剪入口，不得在不支持的平台暴露 P2P 操作。

## 9. 风险

- `media_kit` Web 端走 HTML5，格式支持官方描述为「极其有限」。Web 端定位为补充形态，不作为主要验收目标。
- flutter_rust_bridge 在 iOS/Android 的构建链配置是主要工程成本来源，建议第一个里程碑只打通 macOS，验证通路后再扩端。
- librqbit 9.x 为较新版本（2026-08 发布），API 可能与文档样例有差异，需以实际 crate 文档为准。

## 10. 里程碑

实施计划按里程碑分批产出，首个 plan 只覆盖 M1 + M2（边界清晰、仅 macOS、成功标准 1 与 2 可独立验收）。

1. **M1**：`flutter create` 初始化工程骨架、接入 media_kit 依赖、配置 macOS 沙箱 entitlement（`com.apple.security.network.client`，否则 release 构建下网络请求被拦）；落地 `PlaybackController` 与 `SourceProvider` 协议（仅 `HttpStreamProvider`），播通公开 HLS 流。
2. **M2**：接入 librqbit，macOS 下 magnet 边下边播，含 seek、auth header 透传与 `release()`。
3. **M3**：`CacheRegistry` 模型 + P2P 源进度条已缓存着色。
4. **M4**：扩 Windows / Android（Rust Android target + NDK 构建链）；Web 端以降级形态构建通过。

