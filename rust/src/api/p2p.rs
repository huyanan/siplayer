//! P2P 播放源：内嵌 librqbit，把 magnet 转成本机 127.0.0.1 上带 basic auth 的 HTTP 流地址。
//!
//! 所有 librqbit 工作都在进程级专用 tokio 运行时 `RT` 上执行，FRB 执行器只 await JoinHandle。

use std::collections::{HashMap, HashSet};
use std::net::{Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock};
use std::time::Duration;

use anyhow::{anyhow, ensure, Context, Result};
use base64::Engine;
use librqbit::api::TorrentIdOrHash;
use librqbit::dht::Id20;
use librqbit::http_api::{HttpApi, HttpApiOptions};
use librqbit::{
    AddTorrent, AddTorrentOptions, AddTorrentResponse, Api, DhtSessionConfig, ListenerOptions,
    Magnet, ManagedTorrent, ManagedTorrentState, Session, SessionOptions,
};
use librqbit_dualstack_sockets::{BindOpts, TcpListener};
use tokio::runtime::Runtime;
use tokio::sync::{Mutex, OnceCell};

/// `p2p_start` 的整体超时秒数：覆盖 magnet 元数据获取 + torrent 初始化（本地文件校验）。
const METADATA_TIMEOUT_SECS: u64 = 60;

/// 读取停滞判定秒数（断流上报「无可用 peer」）。
// FIXME(M3): 读取停滞检测未实现，见 spec §6
#[allow(dead_code)]
const READ_STALL_SECS: u64 = 30;

/// 本地 HTTP server 绑定 127.0.0.1:0 失败时的最大重试次数（每次重新向系统申请随机端口）。
const HTTP_BIND_ATTEMPTS: usize = 3;

/// `p2p_start` 在拿到 torrent 后发现它已被并发的 release 删除时，最多重新添加的次数。
const START_ATTEMPTS: usize = 2;

/// 随机凭据字节数（user / pass 各自独立生成）。
const CREDENTIAL_BYTES: usize = 16;

/// 日志里 infohash 只打印的前缀长度。
const INFOHASH_LOG_PREFIX: usize = 8;

/// 进程级专用 tokio 运行时；构建失败时保存错误信息，避免在公开接口路径上 panic。
static RT: LazyLock<std::result::Result<Runtime, String>> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("siplayer-p2p")
        .build()
        .map_err(|e| e.to_string())
});

/// Session 与本地 HTTP 服务的进程级状态，首次 `p2p_start` 时懒初始化。
static STATE: OnceCell<P2pState> = OnceCell::const_new();

struct P2pState {
    session: Arc<Session>,
    port: u16,
    auth_header: String,
    /// torrent id → 持有者计数。同 infohash 的多个 `p2p_start` 共享同一 torrent，
    /// 计数归零才真正删除。release 会在持锁期间完成「递减 + delete」，保证与 start 的递增互斥。
    refs: Mutex<HashMap<usize, usize>>,
}

/// `p2p_start` 的返回值：播放器直接打开 `stream_url`，请求时带上 `auth_header` 作为 Authorization 头。
pub struct P2pHandle {
    pub stream_url: String,
    pub auth_header: String,
    pub torrent_id: i64,
}

/// 下载进度。
///
/// `total_bytes`：被 session 管理的 torrent 一定已有元数据（magnet 在加入 session 前就已解析完），
/// 因此对有效 id 总是 Some；保留 Option 仅为接口兼容。
pub struct P2pProgress {
    pub total_bytes: Option<u64>,
    pub downloaded_bytes: u64,
    pub finished: bool,
}

/// 添加 magnet（同 infohash 已存在则复用并增加引用计数），等待元数据与初始化，返回本地流地址。
///
/// `file_index` 为 None 时自动选择 torrent 内最大的文件，且只下载该文件。
/// 超时或失败时，本次调用新加入的 torrent（以及处于 Error 状态的 torrent）会被移除。
#[flutter_rust_bridge::frb]
pub async fn p2p_start(magnet: String, file_index: Option<u32>) -> Result<P2pHandle> {
    run_on_rt(async move {
        let st = state().await?;
        let info_hash = parse_info_hash(&magnet)?;
        let hash_str = info_hash.as_string();
        let hash_prefix = hash_str.get(..INFOHASH_LOG_PREFIX).unwrap_or(&hash_str);
        tracing::info!(infohash = hash_prefix, "p2p_start");
        let requested = file_index.map(|i| i as usize);

        for _ in 0..START_ATTEMPTS {
            let newly_added = AtomicBool::new(false);
            // 超时 future 被丢弃后再做清理，清理本身不受超时约束。
            let res = match tokio::time::timeout(
                Duration::from_secs(METADATA_TIMEOUT_SECS),
                add_and_prepare(st, &magnet, info_hash, requested, &newly_added),
            )
            .await
            {
                Ok(r) => r,
                Err(_) => Err(anyhow!(
                    "等待 torrent 元数据/初始化超时（{METADATA_TIMEOUT_SECS}s）"
                )),
            };
            let (id, file_idx) = match res {
                Ok(v) => v,
                Err(e) => {
                    cleanup_failed(st, info_hash, newly_added.load(Ordering::SeqCst)).await;
                    return Err(e);
                }
            };

            // 先做 id 转换再递增计数：转换失败不会遗留计数。
            let torrent_id = i64::try_from(id).context("torrent id 超出 i64 范围")?;
            let mut refs = st.refs.lock().await;
            // 等待期间可能被并发的 release 删掉了，此时重新添加。
            if st.session.get(TorrentIdOrHash::Id(id)).is_none() {
                continue;
            }
            *refs.entry(id).or_insert(0) += 1;
            drop(refs);

            return Ok(P2pHandle {
                stream_url: format!(
                    "http://127.0.0.1:{}/torrents/{}/stream/{}",
                    st.port, id, file_idx
                ),
                auth_header: st.auth_header.clone(),
                torrent_id,
            });
        }
        Err(anyhow!("torrent 在启动期间被并发释放，请重试"))
    })
    .await
}
/// 查询 torrent 下载进度。
#[flutter_rust_bridge::frb]
pub async fn p2p_progress(torrent_id: i64) -> Result<P2pProgress> {
    run_on_rt(async move {
        let st = STATE.get().context("p2p session 尚未启动")?;
        let id = usize::try_from(torrent_id).context("非法的 torrent id")?;
        let handle = st
            .session
            .get(TorrentIdOrHash::Id(id))
            .with_context(|| format!("torrent {id} 不存在"))?;
        let stats = handle.stats();
        Ok(P2pProgress {
            total_bytes: Some(stats.total_bytes),
            downloaded_bytes: stats.progress_bytes,
            finished: stats.finished,
        })
    })
    .await
}

/// 释放一次 `p2p_start` 的持有；计数归零时停止并移除 torrent（保留已下载文件作为缓存）。
/// 对未知 / 已释放的 id 视为成功（幂等）。
#[flutter_rust_bridge::frb]
pub async fn p2p_release(torrent_id: i64) -> Result<()> {
    run_on_rt(async move {
        let Some(st) = STATE.get() else {
            return Ok(());
        };
        let Ok(id) = usize::try_from(torrent_id) else {
            return Ok(());
        };
        let mut refs = st.refs.lock().await;
        let Some(count) = refs.get_mut(&id) else {
            return Ok(());
        };
        *count = count.saturating_sub(1);
        if *count > 0 {
            return Ok(());
        }
        refs.remove(&id);
        if st.session.get(TorrentIdOrHash::Id(id)).is_none() {
            return Ok(());
        }
        // 持锁 delete：避免与并发 p2p_start 的计数递增交错。
        st.session.delete(TorrentIdOrHash::Id(id), false).await
    })
    .await
}

/// 在专用运行时上执行 future，并把 JoinError 转成 anyhow 错误。
async fn run_on_rt<F, T>(fut: F) -> Result<T>
where
    F: std::future::Future<Output = Result<T>> + Send + 'static,
    T: Send + 'static,
{
    let rt = RT
        .as_ref()
        .map_err(|e| anyhow!("p2p 运行时创建失败: {e}"))?;
    rt.spawn(fut)
        .await
        .map_err(|e| anyhow!("p2p 任务异常退出: {e}"))?
}

async fn state() -> Result<&'static P2pState> {
    STATE.get_or_try_init(init_state).await
}

/// §7 安全配置的唯一落点：下载目录、127.0.0.1 随机端口 HTTP server、随机 basic auth、Session。
async fn init_state() -> Result<P2pState> {
    let output_dir: PathBuf = std::env::temp_dir().join("siplayer-p2p");
    tokio::fs::create_dir_all(&output_dir)
        .await
        .context("创建 p2p 下载目录失败")?;

    // 先绑本地端口再建 Session：绑定失败时不会遗留带 DHT/BT 监听的 Session。
    let listener = bind_loopback_listener()?;
    let port = listener.bind_addr().port();

    let user = random_hex(CREDENTIAL_BYTES)?;
    let pass = random_hex(CREDENTIAL_BYTES)?;
    let auth_header = format!(
        "Basic {}",
        base64::engine::general_purpose::STANDARD.encode(format!("{user}:{pass}"))
    );

    let session = Session::new_with_opts(
        output_dir,
        SessionOptions {
            // DHT 开启但不落盘持久化；Session 也不开 persistence。
            dht: Some(DhtSessionConfig {
                persistence: None,
                ..Default::default()
            }),
            persistence: None,
            fastresume: false,
            // BT 入站监听（随机端口），提高可连 peer 数。
            listen: Some(ListenerOptions::default()),
            ..Default::default()
        },
    )
    .await
    .context("创建 librqbit session 失败")?;

    let http = HttpApi::new(
        // librqbit 9.0.1 的 http-api 需同时开 tracing-subscriber-utils 才能编译，
        // 因此 Api::new 多一个 line_broadcast 参数；不提供日志广播（/stream_logs 将返回错误）。
        Api::new(session.clone(), None, None),
        Some(HttpApiOptions {
            read_only: true,
            basic_auth: Some((user, pass)),
            ..Default::default()
        }),
    );
    let server = http.make_http_api_and_run(listener, None);
    tokio::spawn(async move {
        if let Err(e) = server.await {
            tracing::error!("p2p http server 退出: {e:#}");
        }
    });
    tracing::info!(port, "p2p http server 已监听 127.0.0.1");

    Ok(P2pState {
        session,
        port,
        auth_header,
        refs: Mutex::new(HashMap::new()),
    })
}

/// 绑定 127.0.0.1:0（由系统分配随机空闲端口）；失败时重试，每次重新申请端口。
fn bind_loopback_listener() -> Result<TcpListener> {
    let addr = SocketAddr::from((Ipv4Addr::LOCALHOST, 0));
    let opts = BindOpts {
        request_dualstack: false,
        ..Default::default()
    };
    let mut last_err = None;
    for _ in 0..HTTP_BIND_ATTEMPTS {
        match TcpListener::bind_tcp(addr, opts) {
            Ok(listener) => return Ok(listener),
            Err(e) => last_err = Some(e),
        }
    }
    Err(match last_err {
        Some(e) => anyhow!("绑定 127.0.0.1 随机端口失败: {e}"),
        None => anyhow!("绑定 127.0.0.1 随机端口失败"),
    })
}

fn random_hex(len: usize) -> Result<String> {
    let mut buf = vec![0u8; len];
    getrandom::fill(&mut buf).map_err(|e| anyhow!("生成随机凭据失败: {e}"))?;
    Ok(buf.iter().map(|b| format!("{b:02x}")).collect())
}

fn parse_info_hash(magnet: &str) -> Result<Id20> {
    Magnet::parse(magnet)
        .context("magnet 格式非法")?
        .as_id20()
        .context("magnet 缺少 BTv1 infohash")
}

fn is_error_state(handle: &ManagedTorrent) -> bool {
    handle.with_state(|s| matches!(s, ManagedTorrentState::Error(_)))
}
/// `p2p_start` 失败/超时后的清理：本次新加入且无人持有的 torrent，或已进入 Error 状态的 torrent，
/// 从 session 移除（保留文件），避免它继续占用 swarm、或让该 magnet 之后一直复用到坏实例。
async fn cleanup_failed(st: &P2pState, info_hash: Id20, newly_added: bool) {
    let mut refs = st.refs.lock().await;
    let Some(handle) = st.session.get(TorrentIdOrHash::Hash(info_hash)) else {
        return;
    };
    let id = handle.id();
    let unheld = refs.get(&id).copied().unwrap_or(0) == 0;
    if !(is_error_state(&handle) || (newly_added && unheld)) {
        return;
    }
    refs.remove(&id);
    match st.session.delete(TorrentIdOrHash::Id(id), false).await {
        Ok(()) => tracing::info!(id, "p2p_start 失败，已从 session 移除 torrent"),
        Err(e) => tracing::warn!(id, "清理失败的 torrent 出错: {e:#}"),
    }
}

/// 添加（或复用）torrent，确定要播放的文件下标，并等待 torrent 初始化完成（可开流）。
async fn add_and_prepare(
    st: &P2pState,
    magnet: &str,
    info_hash: Id20,
    requested: Option<usize>,
    newly_added: &AtomicBool,
) -> Result<(usize, usize)> {
    let existing = match st.session.get(TorrentIdOrHash::Hash(info_hash)) {
        Some(h) if is_error_state(&h) => {
            // Error 状态的旧实例无法再用：移除后重新添加。
            let id = h.id();
            let mut refs = st.refs.lock().await;
            refs.remove(&id);
            st.session
                .delete(TorrentIdOrHash::Id(id), false)
                .await
                .context("移除 Error 状态的 torrent 失败")?;
            drop(refs);
            None
        }
        other => other,
    };

    let (handle, file_idx) = match existing {
        Some(h) => {
            h.wait_until_initialized()
                .await
                .context("torrent 初始化失败")?;
            let idx = match requested {
                Some(i) => i,
                None => largest_file_of(&h)?,
            };
            ensure_file_selected(st, &h, idx).await?;
            (h, idx)
        }
        None => {
            let (h, idx) = add_new(st, magnet, info_hash, requested, newly_added).await?;
            h.wait_until_initialized()
                .await
                .context("torrent 初始化失败")?;
            (h, idx)
        }
    };
    Ok((handle.id(), file_idx))
}

/// 复用已有 torrent 时，确保要播放的文件在 only_files 里（否则后台不会顺序下载它）。
async fn ensure_file_selected(
    st: &P2pState,
    handle: &Arc<ManagedTorrent>,
    idx: usize,
) -> Result<()> {
    let file_count = handle.with_metadata(|m| m.file_infos.len())?;
    ensure!(
        idx < file_count,
        "file_index {idx} 超出范围（共 {file_count} 个文件）"
    );
    let Some(current) = handle.only_files() else {
        // None 表示全选。
        return Ok(());
    };
    if current.contains(&idx) {
        return Ok(());
    }
    let mut selected: HashSet<usize> = current.into_iter().collect();
    selected.insert(idx);
    st.session
        .update_only_files(handle, &selected)
        .await
        .context("更新 only_files 失败")
}

async fn add_new(
    st: &P2pState,
    magnet: &str,
    info_hash: Id20,
    requested: Option<usize>,
    newly_added: &AtomicBool,
) -> Result<(Arc<ManagedTorrent>, usize)> {
    let (add, file_idx, initial_peers) = match requested {
        Some(i) => (AddTorrent::from_url(magnet.to_owned()), i, None),
        None => {
            // 先 list_only 解析元数据选最大文件，再用解析出的 .torrent 字节 + 已见 peer 正式添加，
            // 避免第二次走 magnet 元数据解析。list_only 不会把 torrent 加入 session。
            let listed = st
                .session
                .add_torrent(
                    AddTorrent::from_url(magnet.to_owned()),
                    Some(AddTorrentOptions {
                        list_only: true,
                        ..Default::default()
                    }),
                )
                .await
                .context("解析 magnet 元数据失败")?;
            match listed {
                AddTorrentResponse::ListOnly(resp) => {
                    let idx = largest_index(resp.info.iter_file_lengths())
                        .context("torrent 内没有文件")?;
                    (
                        AddTorrent::from_bytes(resp.torrent_bytes),
                        idx,
                        Some(resp.seen_peers),
                    )
                }
                AddTorrentResponse::AlreadyManaged(_, h) => {
                    h.wait_until_initialized()
                        .await
                        .context("torrent 初始化失败")?;
                    let idx = largest_file_of(&h)?;
                    ensure_file_selected(st, &h, idx).await?;
                    return Ok((h, idx));
                }
                AddTorrentResponse::Added(_, h) => {
                    newly_added.store(true, Ordering::SeqCst);
                    let idx = largest_file_of(&h)?;
                    return Ok((h, idx));
                }
            }
        }
    };

    let existed_before = st.session.get(TorrentIdOrHash::Hash(info_hash)).is_some();
    let resp = st
        .session
        .add_torrent(
            add,
            Some(AddTorrentOptions {
                only_files: Some(vec![file_idx]),
                // 允许复用下载目录里上次残留的数据（release 时保留文件作缓存）。
                overwrite: true,
                initial_peers,
                ..Default::default()
            }),
        )
        .await;
    let resp = match resp {
        Ok(r) => r,
        Err(e) => {
            // librqbit 可能已把 torrent 写入 session 后才在 start 阶段报错（session.rs 中
            // "error starting torrent"），此时也算本次新加入，交给外层清理。
            if !existed_before && st.session.get(TorrentIdOrHash::Hash(info_hash)).is_some() {
                newly_added.store(true, Ordering::SeqCst);
            }
            return Err(e.context("添加 torrent 失败"));
        }
    };
    let handle = match resp {
        AddTorrentResponse::Added(_, h) => {
            newly_added.store(true, Ordering::SeqCst);
            h
        }
        AddTorrentResponse::AlreadyManaged(_, h) => {
            ensure_file_selected_after_init(st, &h, file_idx).await?;
            h
        }
        AddTorrentResponse::ListOnly(_) => return Err(anyhow!("添加 torrent 未返回句柄")),
    };
    Ok((handle, file_idx))
}

/// 并发添加撞上同 infohash 时（AlreadyManaged），等它初始化完再补选文件。
async fn ensure_file_selected_after_init(
    st: &P2pState,
    handle: &Arc<ManagedTorrent>,
    idx: usize,
) -> Result<()> {
    handle
        .wait_until_initialized()
        .await
        .context("torrent 初始化失败")?;
    ensure_file_selected(st, handle, idx).await
}

fn largest_file_of(handle: &ManagedTorrent) -> Result<usize> {
    handle
        .with_metadata(|m| largest_index(m.info.iter_file_lengths()))?
        .context("torrent 内没有文件")
}

fn largest_index(lengths: impl Iterator<Item = u64>) -> Option<usize> {
    lengths
        .enumerate()
        .max_by_key(|(_, len)| *len)
        .map(|(i, _)| i)
}
