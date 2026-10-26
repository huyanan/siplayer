# M3-b 进度条缓存着色 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** P2P 播放时，画面底部显示一条"已缓存"进度条，直观反映边下边播缓冲到哪里。

**Architecture:** 纯 Dart UI，复用 M3-a 已接通的 `Playable.cacheStream`。`PlayerPage` 的缓存订阅除了判定 stalled，额外算"已缓存比例" = 已完成区间末端 / 总字节，在 `Video` 之上叠一条底部 `LinearProgressIndicator`。顺序边下边播时单区间 `[0, downloaded)` 的末端即缓冲位置，比例足以表达缓存进度。

**Tech Stack:** Flutter / Dart（无 Rust 改动）。

## Global Constraints

- 基于已批准 spec §4.4。本批次只做"底部缓存比例条"；**精确 piece 位图多区间、以及把着色嵌入 media_kit 自带 seekbar，留后续**（当前 `CacheEntry.completed` 为单区间近似，顺序流够用；seek 产生的空洞多区间需 Rust piece 位图接口，不在本批次）。
- 仅 macOS 运行；GUI 无法在本机自动化验证（无屏幕录制权限），本任务验证 = `flutter analyze` + `flutter build macos --release` 通过 + 代码评审；视觉效果由用户在 release 版肉眼验收。
- 测试策略：默认不写单测。
- commit message 普通格式。**只 `git add lib/src/ui/player_page.dart`，绝不提交 `lib/src/ui/home_page.dart`**（含未提交演示 magnet）。
- 缓存条仅对 P2P 源出现（`cacheStream != null` 且能算出比例）；HTTP 源不显示。

## 文件结构

- `lib/src/ui/player_page.dart` — 加 `_cachedFraction` 字段、扩展缓存订阅、build 叠加底部缓存条（唯一改动文件）

---

## Task 1: 底部缓存比例条

**Files:**
- Modify: `lib/src/ui/player_page.dart`

**Interfaces:**
- Consumes: `Playable.cacheStream`（`Stream<CacheEntry>`）、`CacheEntry`（`completed`/`totalBytes`/`state`）
- Produces: 无对外接口

- [ ] **Step 1: 加字段**

在 `_PlayerPageState` 字段区（`bool _retrying = false;` 后）加：

```dart
  /// 已缓存比例 0..1（仅 P2P 源，算不出时为 null）
  double? _cachedFraction;
```

<!-- STEP2 -->

- [ ] **Step 2: 扩展缓存订阅，算已缓存比例**

把 `_load` 里的 `_cacheSub = playable.cacheStream?.listen(...)` 整段替换为：

```dart
      _cacheSub = playable.cacheStream?.listen((e) {
        if (!mounted) return;
        final stalled = e.state == CacheState.stalled;
        final total = e.totalBytes;
        final cachedEnd = e.completed.isNotEmpty ? e.completed.last.end : 0;
        final fraction = (total != null && total > 0)
            ? (cachedEnd / total).clamp(0.0, 1.0)
            : null;
        if (stalled != _stalled || fraction != _cachedFraction) {
          setState(() {
            _stalled = stalled;
            _cachedFraction = fraction;
          });
        }
      });
```

- [ ] **Step 3: 重试时重置比例**

在 `_retry` 的 `setState(() { _error = null; _stalled = false; _controller = null; });` 里加一行 `_cachedFraction = null;`。

- [ ] **Step 4: build 叠加底部缓存条**

在 build 的 `Stack` children 里，`Video` 之后、`if (_stalled)` 覆盖之前，插入：

```dart
                if (_cachedFraction != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(
                      value: _cachedFraction,
                      minHeight: 3,
                      backgroundColor: Colors.white24,
                    ),
                  ),
```

（放在 stalled 覆盖之前，这样停滞时的全屏遮罩会盖住细条，视觉不冲突。）

- [ ] **Step 5: 验证**

Run: `flutter analyze`
Expected: No issues found.

Run: `export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH && flutter build macos --release`
Expected: Built。（GUI 视觉效果留用户在 release 版肉眼验收：P2P 播放时底部出现随下载增长的缓存条；HTTP 源无此条。）

- [ ] **Step 6: Commit（只 add player_page.dart）**

提交前 `git status` 确认 `lib/src/ui/home_page.dart` 未被暂存。

```bash
git add lib/src/ui/player_page.dart
git commit -m "feat: 播放页底部显示 P2P 已缓存进度条"
```

