use crate::api::{dispatch, status_json, AppState};
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::PathBuf;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, mpsc};
use tracing::{info, warn};

/// The private daemon channel. There is no public API: the plugin talks to
/// this socket, and everything outside the plugin goes through the shell
/// commands or MPRIS.
pub const PROTOCOL_VERSION: u64 = 1;

/// A single line is one message. The queue is the largest payload; this is
/// generous for it while still refusing an unbounded allocation.
const MAX_LINE_BYTES: usize = 16 * 1024 * 1024;
const EVENT_BUFFER: usize = 64;
const MAX_IN_FLIGHT: usize = 32;

#[derive(Clone, Debug)]
pub enum Event {
    /// The current-track snapshot changed (track, format, transport, volume,
    /// repeat/shuffle, login, cast, playback error). Position is deliberately
    /// absent: MPRIS already streams it at 100 ms.
    Status(Value),
    /// The queue list, its order or its context changed. The client refetches
    /// it rather than receiving a potentially huge list on every skip.
    QueueChanged,
}

#[derive(Debug, Deserialize)]
struct RpcRequest {
    id: u64,
    method: String,
    #[serde(default = "empty_params")]
    params: Value,
}

fn empty_params() -> Value {
    json!({})
}

pub fn runtime_dir() -> Result<PathBuf, String> {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .ok_or_else(|| "XDG_RUNTIME_DIR is not set".to_string())
}

pub fn socket_path() -> Result<PathBuf, String> {
    Ok(runtime_dir()?.join("scorchedegg.tidalplayer/daemon.sock"))
}

/// Removes the socket file on a clean shutdown. A later start treats a socket
/// nobody answers on as stale and replaces it.
pub fn remove_socket() {
    if let Ok(path) = socket_path() {
        let _ = std::fs::remove_file(path);
    }
}

/// Accepts RPC connections until the future is dropped. The caller races this
/// with the shutdown signal.
pub async fn serve(state: AppState) -> Result<(), Box<dyn std::error::Error>> {
    use std::os::unix::fs::PermissionsExt;

    let path = socket_path()?;
    let dir = path
        .parent()
        .ok_or("the daemon socket has no parent directory")?;
    tokio::fs::create_dir_all(dir).await?;
    tokio::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)).await?;

    // A socket file left by a dead daemon is stale; one with a listener behind
    // it means another daemon is already running. Never unlink a live socket.
    if path.exists() {
        match UnixStream::connect(&path).await {
            Ok(_) => {
                return Err(format!(
                    "another omarchy-tidalplayer daemon is already listening on {}",
                    path.display()
                )
                .into());
            }
            Err(_) => {
                tokio::fs::remove_file(&path).await?;
            }
        }
    }

    let listener = UnixListener::bind(&path)?;
    tokio::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).await?;
    info!("Daemon RPC socket listening at {}", path.display());

    tokio::spawn(publish_events(state.clone()));

    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                tokio::spawn(handle_client(state.clone(), stream));
            }
            Err(error) => {
                warn!("RPC accept failed: {error}");
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            }
        }
    }
}

/// Samples the daemon's own state and publishes a status event when it
/// changes. The managers are the source of truth; a 200 ms sample keeps this
/// independent of every place that can move them, while a client-free daemon
/// pays nothing.
async fn publish_events(state: AppState) {
    let mut last_status: Option<Value> = None;
    let mut last_queue_revision: Option<u64> = None;
    loop {
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        if state.events.receiver_count() == 0 {
            continue;
        }
        let revision = state.queue.revision();
        if let Some(previous) = last_queue_revision {
            if previous != revision {
                let _ = state.events.send(Event::QueueChanged);
            }
        }
        last_queue_revision = Some(revision);

        let status = status_json(&state, false, false).await;
        if last_status.as_ref() != Some(&status) {
            let _ = state.events.send(Event::Status(status.clone()));
            last_status = Some(status);
        }
    }
}

async fn handle_client(state: AppState, stream: UnixStream) {
    let (reader, writer) = stream.into_split();
    let (out_tx, out_rx) = mpsc::channel::<String>(EVENT_BUFFER);
    let events = state.events.subscribe();
    let writer_task = tokio::spawn(writer_loop(writer, out_rx, events));

    let hello = json!({ "event": "hello", "data": { "version": PROTOCOL_VERSION } });
    let _ = out_tx.send(hello.to_string()).await;

    let permits = std::sync::Arc::new(tokio::sync::Semaphore::new(MAX_IN_FLIGHT));
    let mut reader = BufReader::new(reader);
    let mut buf = Vec::new();
    loop {
        buf.clear();
        let read = {
            let mut limited = (&mut reader).take((MAX_LINE_BYTES + 1) as u64);
            limited.read_until(b'\n', &mut buf).await
        };
        match read {
            Ok(0) => break,
            Ok(_) => {}
            Err(error) => {
                warn!("RPC read failed: {error}");
                break;
            }
        };
        if buf.len() > MAX_LINE_BYTES && !buf.ends_with(b"\n") {
            warn!("Closing an RPC client that exceeded the {MAX_LINE_BYTES}-byte line limit");
            break;
        }
        let line = match String::from_utf8(std::mem::take(&mut buf)) {
            Ok(line) => line,
            Err(_) => {
                let response = json!({
                    "id": Value::Null,
                    "error": { "message": "malformed request: invalid UTF-8" }
                });
                let _ = out_tx.send(response.to_string()).await;
                continue;
            }
        };
        if line.trim().is_empty() {
            continue;
        }

        let request: RpcRequest = match serde_json::from_str(&line) {
            Ok(request) => request,
            Err(error) => {
                let response = json!({
                    "id": Value::Null,
                    "error": { "message": format!("malformed request: {error}") }
                });
                let _ = out_tx.send(response.to_string()).await;
                continue;
            }
        };

        let permit = match permits.clone().try_acquire_owned() {
            Ok(permit) => permit,
            Err(_) => {
                let response = json!({
                    "id": request.id,
                    "error": { "message": "too many requests in flight" }
                });
                let _ = out_tx.send(response.to_string()).await;
                continue;
            }
        };

        let state = state.clone();
        let out_tx = out_tx.clone();
        tokio::spawn(async move {
            let _permit = permit;
            let response = match dispatch(&state, &request.method, request.params).await {
                Ok(result) => json!({ "id": request.id, "result": result }),
                Err(message) => json!({
                    "id": request.id,
                    "error": { "message": message }
                }),
            };
            let _ = out_tx.send(response.to_string()).await;
        });
    }

    // Dropping our sender lets in-flight handlers finish and flush their
    // replies for half-closed clients; bound the drain so a wedged handler
    // cannot keep the writer around forever.
    drop(out_tx);
    let mut writer_task = writer_task;
    if tokio::time::timeout(std::time::Duration::from_secs(2), &mut writer_task)
        .await
        .is_err()
    {
        writer_task.abort();
    }
}

async fn writer_loop(
    mut writer: tokio::net::unix::OwnedWriteHalf,
    mut responses: mpsc::Receiver<String>,
    mut events: broadcast::Receiver<Event>,
) {
    loop {
        let frame = tokio::select! {
            response = responses.recv() => match response {
                Some(response) => response,
                None => break,
            },
            event = events.recv() => match event {
                Ok(Event::Status(data)) => json!({ "event": "status", "data": data }).to_string(),
                Ok(Event::QueueChanged) => json!({ "event": "queue_changed" }).to_string(),
                Err(broadcast::error::RecvError::Lagged(skipped)) => {
                    warn!("An RPC client lagged {skipped} events; asking it to resync");
                    json!({ "event": "resync" }).to_string()
                }
                Err(broadcast::error::RecvError::Closed) => break,
            },
        };
        if writer.write_all(frame.as_bytes()).await.is_err()
            || writer.write_all(b"\n").await.is_err()
            || writer.flush().await.is_err()
        {
            break;
        }
    }
}

/// Sends one request to the daemon and returns its result. The CLI uses this
/// for every query and command; nothing else needs a client.
pub fn call(method: &str, params: Value) -> Result<Value, String> {
    use std::io::{BufRead, Write};

    let path =
        socket_path().map_err(|error| format!("{error} (is the daemon running under systemd?)"))?;
    let mut stream = std::os::unix::net::UnixStream::connect(&path).map_err(|error| {
        format!(
            "could not connect to {}: {error}. Is omarchy-tidalplayer running?",
            path.display()
        )
    })?;
    let timeout = std::time::Duration::from_secs(30);
    let deadline = std::time::Instant::now() + timeout;
    stream
        .set_write_timeout(Some(std::time::Duration::from_secs(5)))
        .map_err(|error| error.to_string())?;
    stream
        .set_read_timeout(Some(timeout))
        .map_err(|error| error.to_string())?;

    let request = json!({ "id": 1, "method": method, "params": params });
    writeln!(stream, "{request}").map_err(|error| error.to_string())?;
    stream.flush().map_err(|error| error.to_string())?;

    let mut reader = std::io::BufReader::new(stream);
    loop {
        let Some(remaining) = deadline.checked_duration_since(std::time::Instant::now()) else {
            return Err("timed out waiting for daemon response".to_string());
        };
        if remaining.is_zero() {
            return Err("timed out waiting for daemon response".to_string());
        }
        reader
            .get_ref()
            .set_read_timeout(Some(remaining))
            .map_err(|error| error.to_string())?;

        let mut line = String::new();
        if reader
            .read_line(&mut line)
            .map_err(|error| error.to_string())?
            == 0
        {
            return Err("the daemon closed the connection without answering".to_string());
        }
        let response: Value =
            serde_json::from_str(line.trim()).map_err(|error| error.to_string())?;
        if response.get("event").is_some() {
            // hello/status/queue events can precede the response.
            continue;
        }
        if let Some(result) = response.get("result") {
            return Ok(result.clone());
        }
        if let Some(error) = response.get("error") {
            let message = error
                .get("message")
                .and_then(|value| value.as_str())
                .unwrap_or("request failed");
            return Err(message.to_string());
        }
        return Ok(response);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_request_without_params_defaults_to_an_empty_object() {
        let request: RpcRequest = serde_json::from_str(r#"{"id":3,"method":"status"}"#).unwrap();
        assert_eq!(request.id, 3);
        assert_eq!(request.method, "status");
        assert_eq!(request.params, json!({}));
    }

    #[test]
    fn the_client_skips_events_until_the_matching_response() {
        // The wire shape, not the transport: an event has no id, a response
        // carries the request's id.
        let event: Value =
            serde_json::from_str(r#"{"event":"hello","data":{"version":1}}"#).unwrap();
        let response: Value = serde_json::from_str(r#"{"id":1,"result":{"ok":true}}"#).unwrap();
        assert!(event.get("event").is_some());
        assert_eq!(response.get("id"), Some(&json!(1)));
    }
}
