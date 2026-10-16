//! P2P 播放源：内嵌 librqbit，把 magnet 转成本机 127.0.0.1 上带 basic auth 的 HTTP 流地址。
//!
//! 所有 librqbit 工作都在进程级专用 tokio 运行时 `RT` 上执行，FRB 执行器只 await JoinHandle。

use std::net::{Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::{Arc, LazyLock};
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use base64::Engine;
use librqbit::api::TorrentIdOrHash;
use librqbit::http_api::{HttpApi, HttpApiOptions};
use librqbit::{
    AddTorrent, AddTorrentOptions, AddTorrentResponse, Api, DhtSessionConfig, ListenerOptions,
    Magnet, ManagedTorrent, Session, SessionOptions,
};
use librqbit_dualstack_sockets::{BindOpts, TcpListener};
use tokio::runtime::Runtime;
use tokio::sync::OnceCell;

/// 等待 magnet 元数据（含 torrent 初始化）的超时秒数。
const METADATA_TIMEOUT_SECS: u64 = 60;

/// 读取停滞判定秒数（断流上报「无可用 peer」）。
// 停滞检测延后实现：边下边播稳定后再补检测逻辑，本任务只定义常量。
#[allow(dead_code)]
const READ_STALL_SECS: u64 = 30;

/// 本地 HTTP server 绑定失败时的最大重试次数（每次都取新的随机端口）。
const HTTP_BIND_ATTEMPTS: usize = 3;

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
}

/// `p2p_start` 的返回值：播放器直接打开 `stream_url`，请求时带上 `auth_header` 作为 Authorization 头。
pub struct P2pHandle {
    pub stream_url: String,
    pub auth_header: String,
    pub torrent_id: i64,
}

/// 下载进度。`total_bytes` 在元数据未就位时为 None。
pub struct P2pProgress {
    pub total_bytes: Option<u64>,
    pub downloaded_bytes: u64,
    pub finished: bool,
}

/// 添加 magnet（同 infohash 已存在则复用），等待元数据，返回本地流地址。
///
/// `file_index` 为 None 时自动选择 torrent 内最大的文件，且只下载该文件。
#[flutter_rust_bridge::frb]
pub async fn p2p_start(magnet: String, file_index: Option<u32>) -> Result<P2pHandle> {
    run_on_rt(async move {
        let st = state().await?;
        let (id, file_idx) = tokio::time::timeout(
            Duration::from_secs(METADATA_TIMEOUT_SECS),
            add_and_prepare(st, &magnet, file_index),
        )
        .await
        .map_err(|_| anyhow!("等待 torrent 元数据超时（{METADATA_TIMEOUT_SECS}s）"))??;

        Ok(P2pHandle {
            stream_url: format!(
                "http://127.0.0.1:{}/torrents/{}/stream/{}",
                st.port, id, file_idx
            ),
            auth_header: st.auth_header.clone(),
            torrent_id: i64::try_from(id).context("torrent id 超出 i64 范围")?,
        })
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
        let has_metadata = handle.with_metadata(|_| ()).is_ok();
        Ok(P2pProgress {
            total_bytes: has_metadata.then_some(stats.total_bytes),
            downloaded_bytes: stats.progress_bytes,
            finished: stats.finished,
        })
    })
    .await
}

/// 停止并移除 torrent，保留已下载文件作为缓存。对不存在的 id 视为成功（幂等）。
#[flutter_rust_bridge::frb]
pub async fn p2p_release(torrent_id: i64) -> Result<()> {
    run_on_rt(async move {
        let Some(st) = STATE.get() else {
            return Ok(());
        };
        let Ok(id) = usize::try_from(torrent_id) else {
            return Ok(());
        };
        if st.session.get(TorrentIdOrHash::Id(id)).is_none() {
            return Ok(());
        }
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

/// §7 安全配置的唯一落点：下载目录、Session、127.0.0.1 随机端口 HTTP server、随机 basic auth。
async fn init_state() -> Result<P2pState> {
    let output_dir: PathBuf = std::env::temp_dir().join("siplayer-p2p");
    tokio::fs::create_dir_all(&output_dir)
        .await
        .context("创建 p2p 下载目录失败")?;

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

    let listener = bind_loopback_listener()?;
    let port = listener.bind_addr().port();

    let user = random_hex(CREDENTIAL_BYTES)?;
    let pass = random_hex(CREDENTIAL_BYTES)?;
    let auth_header = format!(
        "Basic {}",
        base64::engine::general_purpose::STANDARD.encode(format!("{user}:{pass}"))
    );

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
    })
}

/// 绑定 127.0.0.1 的随机空闲端口；失败时换端口重试。
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

/// 添加（或复用）torrent，确定要播放的文件下标，并等待 torrent 初始化完成（可开流）。
async fn add_and_prepare(
    st: &P2pState,
    magnet: &str,
    file_index: Option<u32>,
) -> Result<(usize, usize)> {
    let info_hash = Magnet::parse(magnet)
        .context("magnet 格式非法")?
        .as_id20()
        .context("magnet 缺少 BTv1 infohash")?;
    let hash_str = info_hash.as_string();
    let hash_prefix = hash_str.get(..INFOHASH_LOG_PREFIX).unwrap_or(&hash_str);
    tracing::info!(infohash = hash_prefix, "p2p_start");

    let requested = file_index.map(|i| i as usize);

    let (handle, file_idx) = if let Some(h) = st.session.get(TorrentIdOrHash::Hash(info_hash)) {
        let idx = match requested {
            Some(i) => i,
            None => largest_file_of(&h)?,
        };
        (h, idx)
    } else {
        add_new(st, magnet, requested).await?
    };

    handle
        .wait_until_initialized()
        .await
        .context("torrent 初始化失败")?;
    Ok((handle.id(), file_idx))
}

async fn add_new(
    st: &P2pState,
    magnet: &str,
    requested: Option<usize>,
) -> Result<(Arc<ManagedTorrent>, usize)> {
    let (add, file_idx, initial_peers) = match requested {
        Some(i) => (AddTorrent::from_url(magnet.to_owned()), i, None),
        None => {
            // 先 list_only 解析元数据选最大文件，再用解析出的 .torrent 字节 + 已见 peer 正式添加，
            // 避免第二次走 magnet 元数据解析。
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
                AddTorrentResponse::AlreadyManaged(_, h) | AddTorrentResponse::Added(_, h) => {
                    let idx = largest_file_of(&h)?;
                    return Ok((h, idx));
                }
            }
        }
    };

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
        .await
        .context("添加 torrent 失败")?;
    let handle = resp.into_handle().context("添加 torrent 未返回句柄")?;
    Ok((handle, file_idx))
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
