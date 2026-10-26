# M3-c 下载目录管理 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** P2P 下载不再堆在系统临时目录，而是落在稳定的平台缓存目录，并有容量上限：进程启动时按 LRU（最久未用优先）清理超出上限的旧 torrent 数据。

**Architecture:** 改 `rust/src/api/p2p.rs` 的 `init_state`。下载目录从 `std::env::temp_dir()` 改为 `dirs::cache_dir()/siplayer/p2p`（取不到则回退临时目录）。新增容量上限常量与 `enforce_cache_limit`：扫描下载目录顶层条目、按修改时间从旧到新删除，直到总占用 ≤ 上限。清理在 `create_dir_all` 之后、`Session::new_with_opts` 之前执行——此时 Session 尚未加入任何 torrent，不存在活跃数据被误删的风险。

**Tech Stack:** Rust、librqbit 9.0.1、`dirs` crate（取平台缓存目录）。

## Global Constraints

- 基于已批准 spec `docs/mapdev/specs/2026-10-10-player-core-design.md` §4.3「下载目录可配置」。本批次实现"稳定缓存目录 + 容量上限 + 启动清理"；**运行时可配置 setter 与会话中（有活跃 torrent 时）清理留 FIXME，不在本批次**。
- 仅 macOS 做运行/构建验证（`cargo clippy` + `flutter build macos`）；P2P 仅 macOS 启用。
- 测试策略：默认不写单测；验证用 `cargo clippy --manifest-path rust/Cargo.toml -- -D warnings`、`flutter analyze`、`flutter build macos --release`；清理逻辑用临时 example/探针验证后删除、不提交。
- commit message 用普通语义化格式。**提交只 `git add` 本任务涉及文件，绝不提交 `lib/src/ui/home_page.dart`**（含未提交的演示 magnet）。
- 不改四个公开 FRB 接口（`p2p_start`/`p2p_progress`/`p2p_release` 签名）；不动 Dart 侧。
- 容量上限默认 5 GiB，集中为常量。

## 文件结构

- `rust/Cargo.toml` — 加 `dirs` 依赖（Task 1）
- `rust/src/api/p2p.rs` — 下载目录、容量上限常量、`enforce_cache_limit`、`init_state` 调用点（Task 1）

---

<!-- TASKS -->

## Task 1: 稳定缓存目录 + 容量上限 + 启动 LRU 清理

**Files:**
- Modify: `rust/Cargo.toml`（加 `dirs`）
- Modify: `rust/src/api/p2p.rs`（常量、目录、清理函数、`init_state` 调用点）

**Interfaces:**
- Consumes: 无（纯内部）
- Produces: `init_state` 使用的下载目录变为 `dirs::cache_dir()/siplayer/p2p`（回退 `temp_dir()/siplayer-p2p`）；进程启动时目录占用被压到 ≤ `CACHE_LIMIT_BYTES`

- [ ] **Step 1: 加 dirs 依赖（锁定实际版本）**

```bash
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH && cargo add dirs --manifest-path rust/Cargo.toml
```
然后把生成的 `dirs = "x.y.z"` 改成精确锁定 `dirs = "=x.y.z"`（与本 crate 其它依赖风格一致），记录实际版本到报告。需联网（提权执行）。

- [ ] **Step 2: 加常量并改下载目录**

`rust/src/api/p2p.rs` 常量区加（放在 `INFOHASH_LOG_PREFIX` 附近）：

```rust
/// P2P 下载目录容量上限（字节）；进程启动时按 LRU 清理到该值以内。
const CACHE_LIMIT_BYTES: u64 = 5 * 1024 * 1024 * 1024; // 5 GiB
```

把 `init_state` 里的下载目录行：

```rust
    let output_dir: PathBuf = std::env::temp_dir().join("siplayer-p2p");
```

改为：

```rust
    // 稳定的平台缓存目录（macOS 为 ~/Library/Caches）；取不到时回退临时目录
    let output_dir: PathBuf = dirs::cache_dir()
        .map(|c| c.join("siplayer").join("p2p"))
        .unwrap_or_else(|| std::env::temp_dir().join("siplayer-p2p"));
```

<!-- TASK1_MORE -->

- [ ] **Step 3: 加清理函数**

把顶部 import `use std::path::PathBuf;`（`p2p.rs:7`）改为 `use std::path::{Path, PathBuf};`（函数签名用 `&Path`，仅 `PathBuf` 不会把 `Path` 带入作用域）。然后在 `p2p.rs` 文件末尾（`largest_index` 之后）加入：

```rust
/// 递归求某路径占用字节数；无法读取的项计 0。
fn path_size(path: &Path) -> u64 {
    let Ok(meta) = std::fs::symlink_metadata(path) else {
        return 0;
    };
    if meta.is_dir() {
        let Ok(entries) = std::fs::read_dir(path) else {
            return 0;
        };
        entries
            .flatten()
            .map(|e| path_size(&e.path()))
            .sum()
    } else {
        meta.len()
    }
}

/// 启动时 LRU 清理：下载目录顶层条目按修改时间从旧到新删除，直到总占用 ≤ limit。
/// 仅在 init_state（Session 尚无任何活跃 torrent）时调用，不会误删正在使用的数据。
fn enforce_cache_limit(dir: &Path, limit: u64) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    let mut items: Vec<(PathBuf, u64, std::time::SystemTime)> = rd
        .flatten()
        .map(|e| {
            let p = e.path();
            let mtime = e
                .metadata()
                .and_then(|m| m.modified())
                .unwrap_or(std::time::UNIX_EPOCH);
            (p.clone(), path_size(&p), mtime)
        })
        .collect();
    let mut total: u64 = items.iter().map(|(_, s, _)| *s).sum();
    if total <= limit {
        return;
    }
    items.sort_by_key(|(_, _, mtime)| *mtime); // 最旧在前
    for (path, size, _) in items {
        if total <= limit {
            break;
        }
        let r = if path.is_dir() {
            std::fs::remove_dir_all(&path)
        } else {
            std::fs::remove_file(&path)
        };
        match r {
            Ok(()) => {
                total = total.saturating_sub(size);
                tracing::info!("p2p 缓存清理：移除旧条目 {size} 字节");
            }
            Err(e) => tracing::warn!("p2p 缓存清理失败: {e}"),
        }
    }
}
```

<!-- TASK1_MORE2 -->

- [ ] **Step 4: init_state 启动时调用清理**

在 `init_state` 里 `create_dir_all(&output_dir)` 成功之后、`bind_loopback_listener` 之前，加入（用 `spawn_blocking` 避免阻塞 executor）：

```rust
    // 启动时按容量上限做一次 LRU 清理（此刻 Session 尚无活跃 torrent，安全）
    {
        let dir = output_dir.clone();
        tokio::task::spawn_blocking(move || enforce_cache_limit(&dir, CACHE_LIMIT_BYTES))
            .await
            .ok();
    }
```

同时在 `init_state` 顶部为"会话中清理"留 FIXME 注释：

```rust
    // FIXME(后续): 会话运行中（有活跃 torrent 时）的增量清理需排除活跃 torrent 目录；
    // 运行时可配置目录/上限的 setter 亦留后续。见 spec §4.3。
```

- [ ] **Step 5: 临时单元测试验证清理逻辑**

本 crate 是 `crate-type = ["cdylib","staticlib"]`，没有 rlib 目标，`cargo run --example` 无法链接本包。改用临时 `#[cfg(test)]` 单测（`cargo test` 以 test profile 编译 lib，可直接访问私有 `path_size`/`enforce_cache_limit`，**无需加任何 `pub`**）。在 `p2p.rs` 末尾临时加入（验证后删除、不提交）：

```rust
#[cfg(test)]
mod cleanup_tests {
    use super::*;

    #[test]
    fn evicts_oldest_until_under_limit() {
        let base = std::env::temp_dir().join(format!("sip-cache-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        // 建 3 个各 1000 字节的条目，mtime 递增（old→new）
        for (i, name) in ["old", "mid", "new"].iter().enumerate() {
            let p = base.join(name);
            std::fs::write(&p, vec![0u8; 1000]).unwrap();
            let t = std::time::SystemTime::UNIX_EPOCH + Duration::from_secs(1000 + i as u64);
            filetime_set(&p, t);
        }
        // 上限 2500：应删掉最旧的 "old"（1000），剩 2000 ≤ 2500
        enforce_cache_limit(&base, 2500);
        assert!(!base.join("old").exists(), "最旧条目应被删除");
        assert!(base.join("mid").exists());
        assert!(base.join("new").exists());
        let _ = std::fs::remove_dir_all(&base);
    }

    fn filetime_set(path: &Path, t: std::time::SystemTime) {
        // 用 utimensat 经 libc 设 mtime；若不便引入，退化为按创建顺序验证（见下）
        let _ = (path, t);
    }
}
```

> 注：设定精确 mtime 可能需额外手段。若 `filetime_set` 不便实现，改为更简单的可验证形态：建条目后**按创建顺序**（文件系统 mtime 天然递增）验证清理删除的是先建的。实现者选能在本机真正跑通的最简形态，断言"清理后总占用 ≤ limit 且删的是较旧条目"，并把 `cargo test` 输出记进报告。

```bash
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH && cargo test --manifest-path rust/Cargo.toml cleanup_tests
```
验证通过后**删除整个 `cleanup_tests` mod**（它在将被提交的 `p2p.rs` 里）。

- [ ] **Step 6: 验证**

Run: `export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH && cargo clippy --manifest-path rust/Cargo.toml -- -D warnings`
Expected: 无告警。

Run: `flutter analyze`
Expected: No issues found.

Run: `export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH && flutter build macos --release`
Expected: Built。

- [ ] **Step 7: Commit（只 add rust/Cargo.toml、rust/Cargo.lock、rust/src/api/p2p.rs）**

提交前确认：(a) `cleanup_tests` mod 已从 `p2p.rs` 删除（`grep -n cleanup_tests rust/src/api/p2p.rs` 应无输出）；(b) `git status` 中 `lib/src/ui/home_page.dart` 未被暂存。

```bash
git add rust/Cargo.toml rust/Cargo.lock rust/src/api/p2p.rs
git commit -m "feat: P2P 下载目录改稳定缓存目录并加容量上限 LRU 清理"
```




