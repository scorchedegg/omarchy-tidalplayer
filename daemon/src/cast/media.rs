//! The cast manifest proxy.
//!
//! A Cast receiver cannot read TIDAL's playback-info response, but the Default
//! Media Receiver runs Shaka Player and plays MPEG-DASH natively. So instead of
//! re-encoding audio into a live stream, the daemon serves only the small MPD
//! manifest over the LAN; the receiver then pulls TIDAL's own segments straight
//! from the CDN, which already answers with `Access-Control-Allow-Origin: *`.
//!
//! That removes the whole transcode pipeline. Nothing is re-encoded, so the
//! device gets exactly what TIDAL delivered (hi-res included), seeking is the
//! receiver's own, and there is no feed to pace — the dropouts a hand-paced
//! ffmpeg stream caused cannot happen.

use axum::{
    body::{Body, Bytes},
    extract::{Path, State},
    http::{header, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use std::collections::HashMap;
use std::io::Read;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::{oneshot, Mutex, RwLock};
use tokio::task::JoinHandle;
use tracing::warn;

/// Monotonic millisecond clock used by Cast silence/firewall watchdogs so an
/// NTP jump cannot falsely trip them. Offset above zero so `0` stays a
/// "never happened" sentinel.
pub fn now_ms() -> u64 {
    static START: OnceLock<Instant> = OnceLock::new();
    const BASE_MS: u64 = 1_000_000_000;
    let origin = START.get_or_init(Instant::now);
    BASE_MS.saturating_add(origin.elapsed().as_millis() as u64)
}

pub fn stream_url(ip: IpAddr, port: u16, token: &str) -> String {
    match ip {
        IpAddr::V4(address) => format!("http://{address}:{port}/s/{token}"),
        IpAddr::V6(address) => format!("http://[{address}]:{port}/s/{token}"),
    }
}

/// The interface the device can reach us on. Uses the kernel's routing table
/// instead of guessing among the machine's addresses.
pub fn local_ip_toward(host: &str) -> Option<IpAddr> {
    let target: IpAddr = host.parse().ok()?;
    let bind_addr = if target.is_ipv6() {
        "[::]:0"
    } else {
        "0.0.0.0:0"
    };
    let socket = std::net::UdpSocket::bind(bind_addr).ok()?;
    socket.connect((target, 9)).ok()?;
    let local = socket.local_addr().ok()?.ip();
    if local.is_unspecified() {
        None
    } else {
        Some(local)
    }
}

#[derive(Clone)]
struct StreamState {
    /// Token -> MPD body. Shaka fetches the manifest itself, then goes straight
    /// to TIDAL for the segments, so this is the whole payload we serve.
    registry: Arc<RwLock<HashMap<String, Bytes>>>,
    /// Monotonic-ms of the last request from a device. Used to tell "the
    /// receiver is about to fetch" apart from "a firewall is dropping its SYN".
    last_request_ms: Arc<AtomicU64>,
}

impl StreamState {
    async fn entry(&self, token: &str) -> Option<Bytes> {
        self.registry.read().await.get(token).cloned()
    }
}

/// Owns the LAN listener and the token -> manifest map. Started on demand when
/// a cast session opens and shut down when casting stops so the port stays
/// closed while idle. Only `/s/<token>` exists on it, and a token is only
/// present while a cast session is using it.
pub struct StreamServer {
    pub port: u16,
    registry: Arc<RwLock<HashMap<String, Bytes>>>,
    last_request_ms: Arc<AtomicU64>,
    counter: AtomicU64,
    shutdown_tx: parking_lot::Mutex<Option<oneshot::Sender<()>>>,
    task: Mutex<Option<JoinHandle<()>>>,
}

/// Fixed so a single firewall rule keeps working across daemon restarts; a
/// random port would need a new exception every launch. Kept below 32768 so it
/// stays outside Linux's default ephemeral outbound port range (32768–60999).
const DEFAULT_PORT: u16 = 27823;

fn bind_stream_listener(port: u16) -> std::io::Result<std::net::TcpListener> {
    // Prefer dual-stack [::] when Linux's default bindv6only=0 is active so
    // both IPv4 and IPv6 Cast devices can reach the manifest server.
    let v6_dual_stack = std::fs::read_to_string("/proc/sys/net/ipv6/bindv6only")
        .map(|v| v.trim() == "0")
        .unwrap_or(false);
    if v6_dual_stack {
        if let Ok(listener) = std::net::TcpListener::bind((Ipv6Addr::UNSPECIFIED, port)) {
            return Ok(listener);
        }
    }
    std::net::TcpListener::bind((Ipv4Addr::UNSPECIFIED, port))
}

fn random_token(counter: &AtomicU64) -> String {
    let mut bytes = [0u8; 16];
    if let Ok(mut urandom) = std::fs::File::open("/dev/urandom") {
        if urandom.read_exact(&mut bytes).is_ok() {
            let mut hex = String::with_capacity(32);
            for b in bytes {
                use std::fmt::Write;
                let _ = write!(&mut hex, "{b:02x}");
            }
            return hex;
        }
    }
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_nanos() as u64)
        .unwrap_or(1);
    format!(
        "{nanos:016x}{:016x}",
        counter.fetch_add(1, Ordering::Relaxed)
    )
}

impl StreamServer {
    pub async fn start() -> Result<Self, String> {
        let requested = std::env::var("TIDALPLAYER_CAST_PORT")
            .ok()
            .and_then(|value| value.parse::<u16>().ok())
            .filter(|port| *port > 0)
            .unwrap_or(DEFAULT_PORT);
        Self::start_on(requested).await
    }

    async fn start_on(requested: u16) -> Result<Self, String> {
        let listener = match bind_stream_listener(requested) {
            Ok(listener) => listener,
            Err(error) if requested != 0 => {
                warn!(
                    "Cast stream port {requested} is unavailable ({error}); using an ephemeral port"
                );
                bind_stream_listener(0)
                    .map_err(|error| format!("could not bind the cast stream listener: {error}"))?
            }
            Err(error) => {
                return Err(format!("could not bind the cast stream listener: {error}"));
            }
        };
        listener
            .set_nonblocking(true)
            .map_err(|error| format!("could not configure the cast stream listener: {error}"))?;
        let port = listener
            .local_addr()
            .map_err(|error| format!("cast stream listener has no address: {error}"))?
            .port();
        let registry = Arc::new(RwLock::new(HashMap::new()));
        let last_request_ms = Arc::new(AtomicU64::new(0));
        let state = StreamState {
            registry: registry.clone(),
            last_request_ms: last_request_ms.clone(),
        };
        let router = Router::new()
            .route(
                "/s/{token}",
                get(manifest_get)
                    .head(manifest_head)
                    .options(manifest_options),
            )
            .with_state(state);
        let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
        let task = tokio::spawn(async move {
            let listener = match tokio::net::TcpListener::from_std(listener) {
                Ok(listener) => listener,
                Err(error) => {
                    warn!("Cast stream listener could not start: {error}");
                    return;
                }
            };
            let serve = axum::serve(listener, router).with_graceful_shutdown(async move {
                let _ = shutdown_rx.await;
            });
            if let Err(error) = serve.await {
                warn!("Cast stream listener stopped: {error}");
            }
        });
        Ok(Self {
            port,
            registry,
            last_request_ms,
            counter: AtomicU64::new(0),
            shutdown_tx: parking_lot::Mutex::new(Some(shutdown_tx)),
            task: Mutex::new(Some(task)),
        })
    }

    /// Signals the listener to stop without waiting. Used on synchronous daemon
    /// shutdown and `Drop`.
    pub fn trigger_shutdown(&self) {
        if let Some(tx) = self.shutdown_tx.lock().take() {
            let _ = tx.send(());
        }
    }

    /// Stops the listener and waits until the socket has been closed so the
    /// port is genuinely released while idle and immediately re-bindable.
    pub async fn shutdown(&self) {
        self.trigger_shutdown();
        let Some(mut handle) = self.task.lock().await.take() else {
            return;
        };
        if tokio::time::timeout(Duration::from_millis(500), &mut handle)
            .await
            .is_err()
        {
            handle.abort();
            let _ = handle.await;
        }
    }

    /// Monotonic-ms of the most recent request from any device.
    pub fn last_request_ms(&self) -> u64 {
        self.last_request_ms.load(Ordering::SeqCst)
    }

    pub async fn register(&self, mpd: String) -> String {
        let token = random_token(&self.counter);
        self.registry
            .write()
            .await
            .insert(token.clone(), Bytes::from(mpd));
        token
    }

    pub async fn remove(&self, token: &str) {
        self.registry.write().await.remove(token);
    }
}

impl Drop for StreamServer {
    fn drop(&mut self) {
        self.trigger_shutdown();
    }
}

/// Adaptive streams are fetched by the receiver with JavaScript, so the
/// manifest must carry CORS headers or Shaka rejects it outright.
fn manifest_headers() -> [(header::HeaderName, HeaderValue); 4] {
    [
        (header::CONTENT_TYPE, HeaderValue::from_static("application/dash+xml")),
        (header::ACCESS_CONTROL_ALLOW_ORIGIN, HeaderValue::from_static("*")),
        (
            header::ACCESS_CONTROL_ALLOW_HEADERS,
            HeaderValue::from_static("If-Modified-Since, Range, Origin"),
        ),
        (
            header::ACCESS_CONTROL_EXPOSE_HEADERS,
            HeaderValue::from_static("Content-Length, Content-Range, Accept-Ranges"),
        ),
    ]
}

async fn manifest_get(State(state): State<StreamState>, Path(token): Path<String>) -> Response {
    let Some(mpd) = state.entry(&token).await else {
        return (StatusCode::NOT_FOUND, "unknown stream").into_response();
    };
    state.last_request_ms.store(now_ms(), Ordering::SeqCst);
    let mut response = Response::new(Body::from(mpd));
    let headers = response.headers_mut();
    for (name, value) in manifest_headers() {
        headers.insert(name, value);
    }
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
}

async fn manifest_head(State(state): State<StreamState>, Path(token): Path<String>) -> Response {
    let Some(mpd) = state.entry(&token).await else {
        return (StatusCode::NOT_FOUND, "unknown stream").into_response();
    };
    state.last_request_ms.store(now_ms(), Ordering::SeqCst);
    let mut response = Response::new(Body::empty());
    let headers = response.headers_mut();
    for (name, value) in manifest_headers() {
        headers.insert(name, value);
    }
    headers.insert(
        header::CONTENT_LENGTH,
        HeaderValue::from_str(&mpd.len().to_string())
            .unwrap_or_else(|_| HeaderValue::from_static("0")),
    );
    response
}

async fn manifest_options(State(state): State<StreamState>, Path(token): Path<String>) -> Response {
    if state.entry(&token).await.is_none() {
        return (StatusCode::NOT_FOUND, "unknown stream").into_response();
    }
    state.last_request_ms.store(now_ms(), Ordering::SeqCst);
    let mut response = StatusCode::NO_CONTENT.into_response();
    let headers = response.headers_mut();
    for (name, value) in manifest_headers() {
        headers.insert(name, value);
    }
    headers.insert(
        header::ACCESS_CONTROL_ALLOW_METHODS,
        HeaderValue::from_static("GET, HEAD, OPTIONS"),
    );
    response
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stream_url_formats_both_address_families() {
        assert_eq!(
            stream_url(IpAddr::from([192, 0, 2, 5]), 41234, "abc"),
            "http://192.0.2.5:41234/s/abc"
        );
        assert_eq!(
            stream_url("2001:db8::1".parse().unwrap(), 9, "abc"),
            "http://[2001:db8::1]:9/s/abc"
        );
    }

    #[test]
    fn manifest_headers_allow_cross_origin_fetch() {
        let headers = manifest_headers();
        let find = |needle: &header::HeaderName| {
            headers
                .iter()
                .find(|(name, _)| name == needle)
                .map(|(_, value)| value.to_str().unwrap().to_string())
        };
        assert_eq!(find(&header::CONTENT_TYPE).unwrap(), "application/dash+xml");
        assert_eq!(find(&header::ACCESS_CONTROL_ALLOW_ORIGIN).unwrap(), "*");
        assert!(find(&header::ACCESS_CONTROL_EXPOSE_HEADERS)
            .unwrap()
            .contains("Content-Range"));
    }

    #[tokio::test]
    async fn stream_server_opens_on_start_and_closes_the_port_on_shutdown() {
        let server = StreamServer::start_on(0).await.unwrap();
        let port = server.port;
        assert!(tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .is_ok());

        server.shutdown().await;

        assert!(tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .is_err());
    }
}
