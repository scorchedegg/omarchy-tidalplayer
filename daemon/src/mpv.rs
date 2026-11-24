use crate::queue::TrackItem;
use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum PlaybackState {
    #[default]
    Stopped,
    Playing,
    Paused,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FormatInfo {
    pub bit_depth: u32,
    pub sample_rate: u32,
    pub quality: String,
    pub badge: String,
}

impl Default for FormatInfo {
    fn default() -> Self {
        Self {
            bit_depth: 16,
            sample_rate: 44100,
            quality: "LOSSLESS".to_string(),
            badge: "16-bit / 44.1 kHz FLAC".to_string(),
        }
    }
}

/// How long a user-facing transport operation may take before the mpv process
/// is treated as unresponsive and replaced. A healthy IPC command answers in
/// milliseconds; the timeout only fires when mpv itself is stuck.
pub const TRANSPORT_OP_TIMEOUT: Duration = Duration::from_secs(5);
/// How long loading a stream may take on the ordinary play/refresh path.
pub const STREAM_LOAD_TIMEOUT: Duration = Duration::from_secs(8);
/// Returned when an operation timed out and the mpv process was restarted.
pub const PIPELINE_WEDGED_ERROR: &str = "mpv did not respond; restarted the playback process";
/// How often the IPC poller refreshes the cached position, duration and state.
const POSITION_POLL_INTERVAL: Duration = Duration::from_millis(200);
/// A stream paused for longer than this is refreshed before resuming. TIDAL
/// CDN tokens expire and PipeWire may suspend the idle stream node.
const STALE_AFTER_PAUSE: Duration = Duration::from_secs(120);
/// How long to wait for mpv to report the loaded stream. A local DASH manifest
/// reports its duration immediately; a direct URL may take a moment.
const LOAD_SETTLE: Duration = Duration::from_millis(1500);
/// Bounded IPC read/write timeout. Kept below the transport timeout so a
/// wedged read cannot hold the player lock past the caller's deadline.
const IPC_TIMEOUT: Duration = Duration::from_secs(1);
/// mpv creates its socket after start; give it enough time for a cold start.
const STARTUP_TIMEOUT: Duration = Duration::from_secs(5);
/// After a load or a seek, mpv can briefly keep reporting the previous entry's
/// `eof-reached`. Ignore the flag for this long so a stale EOF cannot advance
/// the queue.
const EOF_GUARD: Duration = Duration::from_millis(750);

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PersistedPlayerState {
    #[serde(default)]
    pub track: Option<TrackItem>,
    #[serde(default)]
    pub position: f64,
    #[serde(default = "default_volume")]
    pub volume: f64,
    #[serde(default)]
    pub shuffle: bool,
    #[serde(default = "default_repeat_mode")]
    pub repeat_mode: String,
}

fn default_volume() -> f64 {
    1.0
}

fn default_repeat_mode() -> String {
    "off".to_string()
}

impl Default for PersistedPlayerState {
    fn default() -> Self {
        Self {
            track: None,
            position: 0.0,
            volume: default_volume(),
            shuffle: false,
            repeat_mode: default_repeat_mode(),
        }
    }
}

/// The next queue track, already appended to mpv's playlist. `prefetch-playlist`
/// buffers it while the current track plays, so promoting it at the end of the
/// current track needs no TIDAL or CDN round trip. `entry_id` is mpv's
/// `playlist_entry_id` for the appended entry: a promotion proves the entry
/// after the current one is exactly this one before switching, and a re-armed
/// preload removes this entry instead of leaving it in the way.
struct PreloadedStream {
    track: TrackItem,
    uri: String,
    format: FormatInfo,
    entry_id: i64,
}

/// The playhead a cast session parks for the next local load, tagged with the
/// track it belongs to. `play` carries the session's own transport state: a
/// session that was paused (or stopped) hands the track back parked, so
/// stopping the cast never starts the song on this machine.
struct ResumeHandoff {
    track_id: String,
    position: f64,
    play: bool,
}

pub(crate) fn same_queue_entry(a: &TrackItem, b: &TrackItem) -> bool {
    match (a.tlid, b.tlid) {
        (Some(a), Some(b)) => a == b,
        _ => a.id == b.id,
    }
}

/// Monotonic clock in milliseconds, offset above zero so `0` remains the
/// "uninitialized" sentinel and subtracting multi-minute intervals in tests
/// cannot underflow.
fn now_ms() -> u64 {
    static START: OnceLock<Instant> = OnceLock::new();
    const BASE_MS: u64 = 1_000_000_000;
    let origin = START.get_or_init(Instant::now);
    BASE_MS.saturating_add(origin.elapsed().as_millis() as u64)
}

fn is_ipc_transport_error(error: &str) -> bool {
    error.starts_with("mpv IPC ")
}

/// `eof-reached` is only meaningful when it belongs to the current playback
/// position, not the previous entry or the moment just after a seek. A real
/// EOF sits at (or within a second of) the known duration.
fn eof_is_current(position: f64, duration: f64, now_ms: u64, ignore_until_ms: u64) -> bool {
    now_ms >= ignore_until_ms && (duration <= 0.0 || position + 1.0 >= duration)
}

/// True when `target` falls inside one of mpv's `demuxer-cache-state`
/// `seekable-ranges`. Only an in-cache target is a safe direct seek once the
/// demuxer has reached EOF.
fn seek_is_cached(cache: &serde_json::Value, target: f64) -> bool {
    cache
        .get("seekable-ranges")
        .and_then(|ranges| ranges.as_array())
        .is_some_and(|ranges| {
            ranges.iter().any(|range| {
                let start = range.get("start").and_then(|value| value.as_f64());
                let end = range.get("end").and_then(|value| value.as_f64());
                matches!((start, end), (Some(start), Some(end)) if target >= start && target <= end)
            })
        })
}

/// State that belongs to the daemon rather than to one mpv process, so it
/// survives a child restart.
struct Shared {
    state: parking_lot::RwLock<PlaybackState>,
    current_uri: parking_lot::RwLock<Option<String>>,
    format_info: parking_lot::RwLock<FormatInfo>,
    // The track whose stream `format_info` describes. The queue can move to a
    // new track before its TIDAL playback-info lands; without this tag the
    // status snapshot would pair the new track with the old stream's badge.
    format_track: parking_lot::RwLock<Option<String>>,
    volume: parking_lot::RwLock<f64>,
    // The track whose stream is loaded. A playhead only belongs to that track;
    // it is also the persisted source of truth for the selection.
    position_track: parking_lot::RwLock<Option<TrackItem>>,
    // The next track already appended to mpv's playlist, if preloading ran.
    preloaded: parking_lot::RwLock<Option<PreloadedStream>>,
    // A seek issued while a load/refresh is still being applied. The load
    // consumes it after its initial position, so the newest target wins.
    pending_seek: parking_lot::RwLock<Option<f64>>,
    // The playhead a cast hand-off parked for the next local load, tagged with
    // the track it belongs to. `stop_internal` deliberately leaves it alone:
    // the playback loop stops the outgoing stream before loading the resumed
    // track, and that stop must not throw the hand-off position away.
    resume_pending: parking_lot::RwLock<Option<ResumeHandoff>>,
    // Epoch-ms deadline before which mpv's `eof-reached` is treated as stale
    // after a load or seek.
    eos_ignore_until_ms: AtomicU64,
    volume_apply_pending: AtomicBool,
    volume_generation: AtomicU64,
    persist_dirty: AtomicBool,
    saved_sleep_position: parking_lot::RwLock<Option<f64>>,
    last_position: parking_lot::RwLock<f64>,
    duration: parking_lot::RwLock<f64>,
    // Set while a load/refresh is being applied; the poller must not publish
    // mpv's transient idle state during it.
    load_pending: AtomicBool,
    // True when the user asked for playback while a wake/refresh load was in
    // flight; the load starts playback instead of parking.
    play_after_refresh: AtomicBool,
    // True when the loaded URI can no longer be trusted (after wake, error, or
    // an mpv process restart).
    stream_stale: AtomicBool,
    refresh_in_flight: AtomicBool,
    refresh_tx: mpsc::UnboundedSender<()>,
    on_eos_tx: mpsc::UnboundedSender<()>,
    /// Fired after every successful stream load and preloaded promotion with
    /// the track that just started. The playback loop arms the next-track
    /// preload from it, so every play path — plain reloads included — re-arms
    /// it and no caller can forget to.
    stream_started_tx: mpsc::UnboundedSender<TrackItem>,
    /// Fired once per stall episode: mpv says it is playing, is not buffering,
    /// and its audio clock has not moved. The playback loop turns that into a
    /// playback error instead of a UI that claims to be playing.
    stall_tx: mpsc::UnboundedSender<()>,
    last_progress_ms: AtomicU64,
    stall_reported: AtomicBool,
    sleep_generation: AtomicU64,
    // Bumped by every pre-sleep teardown. An in-flight stream refresh compares
    // it to abort instead of loading a URL into a player that is about to be
    // stopped again (an aborted suspend emits a resume just like a real wake).
    sleep_epoch: AtomicU64,
    pause_generation: AtomicU64,
    paused_at: parking_lot::RwLock<Option<Instant>>,
    eos_signaled: AtomicBool,
    ipc_healthy: AtomicBool,
    generation: AtomicU64,
    child_pid: AtomicU32,
}

impl Shared {
    fn mark_persist_dirty(&self) {
        self.persist_dirty.store(true, Ordering::SeqCst);
    }

    fn clear_paused(&self) {
        *self.paused_at.write() = None;
    }

    fn mark_playing(&self) {
        self.clear_paused();
    }

    /// Restarts the dead-output watchdog's window. Called whenever playback
    /// starts or resumes: the audio clock is expected to move from now, not
    /// from the last time it moved before a pause, a cast session or a load.
    /// Without this the stamp can be minutes old by the time a new stream is
    /// loaded, so the first poll (clock still at its start position, cache
    /// already full) reports a dead output within milliseconds.
    fn restart_progress_window(&self) {
        self.last_progress_ms.store(now_ms(), Ordering::SeqCst);
        self.stall_reported.store(false, Ordering::SeqCst);
    }

    fn mark_paused(&self) {
        let mut paused_at = self.paused_at.write();
        if paused_at.is_none() {
            *paused_at = Some(Instant::now());
        }
    }

    fn set_paused_now(&self) {
        *self.paused_at.write() = Some(Instant::now());
    }

    fn paused_long_enough(&self, threshold: Duration) -> bool {
        matches!(*self.paused_at.read(), Some(at) if at.elapsed() >= threshold)
    }

    /// Keeps the current playhead as a parked position when playback stops for
    /// a reason other than the user's Stop.
    fn park_position(&self) {
        let mut saved = self.saved_sleep_position.write();
        if saved.is_none() {
            let position = *self.last_position.read();
            if position > 0.0 {
                *saved = Some(position);
            }
        }
    }
}

struct MpvIpc {
    child: Child,
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    request_id: u64,
    socket_path: PathBuf,
}

impl Drop for MpvIpc {
    fn drop(&mut self) {
        // mpv does not need a graceful quit; killing it also releases a wedged
        // PipeWire stream immediately.
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

impl MpvIpc {
    fn command(&mut self, command: serde_json::Value) -> Result<Option<serde_json::Value>, String> {
        self.request_id += 1;
        let id = self.request_id;
        let payload = serde_json::json!({ "command": command, "request_id": id });
        writeln!(self.writer, "{payload}").map_err(|e| format!("mpv IPC write failed: {e}"))?;
        self.writer
            .flush()
            .map_err(|e| format!("mpv IPC write failed: {e}"))?;

        let deadline = Instant::now() + IPC_TIMEOUT;
        loop {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return Err("mpv IPC timed out".to_string());
            };
            if remaining.is_zero() {
                return Err("mpv IPC timed out".to_string());
            }
            let _ = self.reader.get_ref().set_read_timeout(Some(remaining));
            let mut line = String::new();
            match self.reader.read_line(&mut line) {
                Ok(0) => return Err("mpv IPC closed".to_string()),
                Ok(_) => {}
                Err(e) => return Err(format!("mpv IPC read failed: {e}")),
            }
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let Ok(value) = serde_json::from_str::<serde_json::Value>(line) else {
                continue;
            };
            if value.get("request_id").and_then(|id| id.as_u64()) != Some(id) {
                // An event or a reply to another request; the lock serialises
                // commands, so there should be no other live request.
                continue;
            }
            if let Some(error) = value.get("error").and_then(|e| e.as_str()) {
                if error != "success" {
                    return Err(format!("mpv: {error}"));
                }
            }
            return Ok(value.get("data").cloned());
        }
    }

    fn get_property(&mut self, name: &str) -> Result<Option<serde_json::Value>, String> {
        match self.command(serde_json::json!(["get_property", name])) {
            Ok(value) => Ok(value),
            Err(e) if e.contains("property unavailable") || e.contains("property not found") => {
                Ok(None)
            }
            Err(e) => Err(e),
        }
    }

    fn set_property(&mut self, name: &str, value: serde_json::Value) -> Result<(), String> {
        self.command(serde_json::json!(["set_property", name, value]))
            .map(|_| ())
    }

    fn set_pause(&mut self, pause: bool) -> Result<(), String> {
        self.set_property("pause", serde_json::Value::Bool(pause))
    }

    /// Loads `uri`, optionally resuming at `start`. The position is a per-file
    /// load option so mpv seeks while it opens the stream; a seek issued after
    /// `loadfile` is rejected with "error running command" whenever a cold DASH
    /// manifest takes longer than `LOAD_SETTLE` to report its duration.
    fn loadfile(&mut self, uri: &str, start: Option<f64>) -> Result<(), String> {
        let command = match start {
            Some(seconds) => serde_json::json!([
                "loadfile",
                uri,
                "replace",
                -1,
                { "start": format!("{seconds:.3}") }
            ]),
            None => serde_json::json!(["loadfile", uri, "replace"]),
        };
        self.command(command).map(|_| ())
    }

    /// Appends `uri` to the playlist and returns mpv's `playlist_entry_id` for
    /// the new entry.
    fn appendfile(&mut self, uri: &str) -> Result<i64, String> {
        let data = self
            .command(serde_json::json!(["loadfile", uri, "append"]))?
            .ok_or_else(|| "mpv did not report the appended playlist entry".to_string())?;
        data.get("playlist_entry_id")
            .and_then(|value| value.as_i64())
            .ok_or_else(|| "mpv did not report the appended playlist entry".to_string())
    }

    /// The playlist's entry ids in playback order.
    fn playlist_entries(&mut self) -> Result<Vec<i64>, String> {
        let Some(entries) = self.get_property("playlist")? else {
            return Ok(Vec::new());
        };
        Ok(entries
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| item.get("id").and_then(|id| id.as_i64()))
                    .collect()
            })
            .unwrap_or_default())
    }

    fn playlist_pos(&mut self) -> Result<i64, String> {
        Ok(self
            .get_property("playlist-pos")?
            .and_then(|value| value.as_i64())
            .unwrap_or(-1))
    }

    /// Removes the playlist entry with `entry_id` if mpv still holds it.
    fn playlist_remove_id(&mut self, entry_id: i64) -> Result<(), String> {
        let entries = self.playlist_entries()?;
        if let Some(index) = entries.iter().position(|id| *id == entry_id) {
            self.command(serde_json::json!(["playlist-remove", index]))
                .map(|_| ())?;
        }
        Ok(())
    }

    fn playlist_next(&mut self) -> Result<(), String> {
        self.command(serde_json::json!(["playlist-next"]))
            .map(|_| ())
    }

    fn seek(&mut self, seconds: f64) -> Result<(), String> {
        self.command(serde_json::json!(["seek", seconds, "absolute+exact"]))
            .map(|_| ())
    }

    /// True when a seek target cannot be served from mpv's demuxer cache after
    /// the demuxer has already read the stream to EOF. FFmpeg's DASH demuxer
    /// closes its representation at EOF, so a later low-level seek only
    /// rewinds the segment counter and then reports EOF again. The stream has
    /// to be reloaded at the target instead.
    fn seek_needs_reload(&mut self, seconds: f64) -> bool {
        let Ok(Some(cache)) = self.get_property("demuxer-cache-state") else {
            return false;
        };
        let eof = cache.get("eof").and_then(|value| value.as_bool()) == Some(true);
        eof && !seek_is_cached(&cache, seconds)
    }

    fn stop(&mut self) -> Result<(), String> {
        self.command(serde_json::json!(["stop"])).map(|_| ())
    }
}

/// A playback controller backed by a supervised `mpv` child process.
///
/// mpv is spawned with its JSON IPC socket and a stable audio-client name, so
/// the daemon's HTTP/MPRIS/queue code never shares a process or an audio client
/// with the player. A wedged or crashed player is a killed child, not a daemon
/// restart.
pub struct MpvPlayer {
    shared: Arc<Shared>,
    ipc: Arc<parking_lot::Mutex<Option<MpvIpc>>>,
    shutdown: Arc<AtomicBool>,
    mpv_binary: String,
}

impl MpvPlayer {
    pub fn new(
        on_eos_tx: mpsc::UnboundedSender<()>,
        refresh_tx: mpsc::UnboundedSender<()>,
        stall_tx: mpsc::UnboundedSender<()>,
        stream_started_tx: mpsc::UnboundedSender<TrackItem>,
    ) -> Result<Self, String> {
        let shared = Arc::new(Shared {
            state: parking_lot::RwLock::new(PlaybackState::Stopped),
            current_uri: parking_lot::RwLock::new(None),
            format_info: parking_lot::RwLock::new(FormatInfo::default()),
            format_track: parking_lot::RwLock::new(None),
            volume: parking_lot::RwLock::new(1.0),
            position_track: parking_lot::RwLock::new(None),
            preloaded: parking_lot::RwLock::new(None),
            pending_seek: parking_lot::RwLock::new(None),
            resume_pending: parking_lot::RwLock::new(None),
            eos_ignore_until_ms: AtomicU64::new(0),
            volume_apply_pending: AtomicBool::new(false),
            volume_generation: AtomicU64::new(0),
            persist_dirty: AtomicBool::new(false),
            saved_sleep_position: parking_lot::RwLock::new(None),
            last_position: parking_lot::RwLock::new(0.0),
            duration: parking_lot::RwLock::new(0.0),
            load_pending: AtomicBool::new(false),
            play_after_refresh: AtomicBool::new(false),
            stream_stale: AtomicBool::new(false),
            refresh_in_flight: AtomicBool::new(false),
            refresh_tx,
            on_eos_tx,
            stream_started_tx,
            stall_tx,
            last_progress_ms: AtomicU64::new(0),
            stall_reported: AtomicBool::new(false),
            sleep_generation: AtomicU64::new(0),
            sleep_epoch: AtomicU64::new(0),
            pause_generation: AtomicU64::new(0),
            paused_at: parking_lot::RwLock::new(None),
            eos_signaled: AtomicBool::new(false),
            ipc_healthy: AtomicBool::new(true),
            generation: AtomicU64::new(0),
            child_pid: AtomicU32::new(0),
        });

        let ipc = Arc::new(parking_lot::Mutex::new(None));
        let shutdown = Arc::new(AtomicBool::new(false));
        spawn_poller(Arc::clone(&shared), Arc::clone(&ipc), Arc::clone(&shutdown));

        let mpv_binary = std::env::var("TIDALPLAYER_MPV")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| "mpv".to_string());

        Ok(Self {
            shared,
            ipc,
            shutdown,
            mpv_binary,
        })
    }

    fn socket_path() -> Result<PathBuf, String> {
        let dir = dirs::runtime_dir()
            .map(|path| path.join("scorchedegg.tidalplayer"))
            .unwrap_or_else(crate::auth::AuthManager::state_dir);
        std::fs::create_dir_all(&dir)
            .map_err(|e| format!("Could not create the mpv runtime directory: {e}"))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
        }
        Ok(dir.join("mpv.sock"))
    }

    /// The child's command line. Kept separate from `spawn_ipc` so the
    /// cache-critical flags are unit-tested without starting a process.
    fn mpv_args(socket_path: &std::path::Path) -> Vec<String> {
        [
            "--no-config",
            "--idle=yes",
            "--no-video",
            "--no-terminal",
            "--load-scripts=no",
            "--ao=pipewire",
            "--audio-client-name=TIDAL Player",
            &format!("--input-ipc-server={}", socket_path.display()),
            "--volume=100",
            "--mute=no",
            // Pause at the end of every entry instead of letting mpv advance on
            // its own; the playback loop promotes the preloaded next entry.
            "--keep-open=always",
            "--force-window=no",
            // Open the appended next entry once the current URL is fully read.
            "--prefetch-playlist=yes",
            // A DASH manifest is a local file, so mpv's default `--cache=auto`
            // leaves the demuxer cache off: it reads about one second ahead
            // and keeps nothing behind. TIDAL's segments are ~4 s, so a seek
            // then refetches a CDN segment instead of playing from memory.
            "--cache=yes",
            "--demuxer-max-bytes=256MiB",
            "--demuxer-max-back-bytes=128MiB",
            // mpv restricts nested protocols for a local manifest; without
            // this the DASH demuxer cannot open its HTTPS segments.
            "--demuxer-lavf-o=protocol_whitelist=[file,http,https,tcp,tls,crypto,data]",
        ]
        .into_iter()
        .map(str::to_string)
        .collect()
    }

    fn spawn_ipc(&self) -> Result<MpvIpc, String> {
        let socket_path = Self::socket_path()?;
        let _ = std::fs::remove_file(&socket_path);

        let mut command = Command::new(&self.mpv_binary);
        command
            .args(Self::mpv_args(&socket_path))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());

        let mut child = command.spawn().map_err(|e| {
            format!(
                "Could not start mpv ({}): {e}. Install it with `omarchy pkg add mpv`.",
                self.mpv_binary
            )
        })?;

        let deadline = Instant::now() + STARTUP_TIMEOUT;
        let stream = loop {
            match UnixStream::connect(&socket_path) {
                Ok(stream) => break stream,
                Err(_) if Instant::now() < deadline => {
                    if let Ok(Some(status)) = child.try_wait() {
                        let _ = std::fs::remove_file(&socket_path);
                        return Err(format!("mpv exited during startup ({status})"));
                    }
                    std::thread::sleep(Duration::from_millis(20));
                }
                Err(e) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    let _ = std::fs::remove_file(&socket_path);
                    return Err(format!("mpv did not create its IPC socket: {e}"));
                }
            }
        };

        let configure = || -> Result<(BufReader<UnixStream>, UnixStream), String> {
            stream
                .set_read_timeout(Some(IPC_TIMEOUT))
                .map_err(|e| format!("Could not set the mpv IPC timeout: {e}"))?;
            stream
                .set_write_timeout(Some(IPC_TIMEOUT))
                .map_err(|e| format!("Could not set the mpv IPC timeout: {e}"))?;
            let writer = stream
                .try_clone()
                .map_err(|e| format!("Could not clone the mpv IPC socket: {e}"))?;
            Ok((BufReader::new(stream), writer))
        };
        let (reader, writer) = match configure() {
            Ok(pair) => pair,
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = std::fs::remove_file(&socket_path);
                return Err(e);
            }
        };
        let pid = child.id();
        self.shared.child_pid.store(pid, Ordering::SeqCst);
        let generation = self.shared.generation.fetch_add(1, Ordering::SeqCst) + 1;
        info!(
            "Started mpv process {} (generation {generation}, socket {})",
            pid,
            socket_path.display()
        );

        let mut client = MpvIpc {
            child,
            reader,
            writer,
            request_id: 0,
            socket_path,
        };
        // The daemon polls properties synchronously; disabling unsolicited
        // events prevents event chatter from delaying command replies.
        let _ = client.command(serde_json::json!(["disable_event", "all"]));
        Ok(client)
    }

    fn replace_dead_client(
        &self,
        guard: &mut parking_lot::MutexGuard<'_, Option<MpvIpc>>,
        had_client: bool,
    ) -> Result<(), String> {
        **guard = None;
        self.shared.child_pid.store(0, Ordering::SeqCst);
        let client = match self.spawn_ipc() {
            Ok(client) => client,
            Err(e) => {
                self.shared.ipc_healthy.store(false, Ordering::SeqCst);
                return Err(e);
            }
        };
        **guard = Some(client);
        self.shared.ipc_healthy.store(true, Ordering::SeqCst);
        if had_client {
            // The previous child owned the stream and its playhead.
            self.shared.stream_stale.store(true, Ordering::SeqCst);
            self.shared.load_pending.store(false, Ordering::SeqCst);
            self.shared
                .play_after_refresh
                .store(false, Ordering::SeqCst);
            self.shared.clear_paused();
            *self.shared.state.write() = PlaybackState::Stopped;
            self.shared.mark_persist_dirty();
        }
        Ok(())
    }

    fn with_client<T>(
        &self,
        operation: impl FnOnce(&mut MpvIpc) -> Result<T, String>,
    ) -> Result<T, String> {
        let mut guard = self.ipc.lock();
        let had_client = guard.is_some();
        if !had_client || !self.shared.ipc_healthy.load(Ordering::SeqCst) {
            self.replace_dead_client(&mut guard, had_client)?;
        }
        let result = operation(guard.as_mut().expect("mpv client was just ensured"));
        if let Err(ref error) = result {
            if is_ipc_transport_error(error) {
                self.shared.ipc_healthy.store(false, Ordering::SeqCst);
            }
        }
        result
    }

    /// Spawns the mpv process if it is not running, or replaces a dead one.
    pub fn ensure_child(&self) -> Result<(), String> {
        let mut guard = self.ipc.lock();
        let had_client = guard.is_some();
        if had_client && self.shared.ipc_healthy.load(Ordering::SeqCst) {
            return Ok(());
        }
        self.replace_dead_client(&mut guard, had_client)
    }

    fn load_uri(
        &self,
        track: &TrackItem,
        uri: &str,
        format: FormatInfo,
        position: Option<f64>,
        play: bool,
    ) -> Result<(), String> {
        // A play request made while a refresh was in flight wins.
        let play = play || self.shared.play_after_refresh.swap(false, Ordering::SeqCst);
        // A seek issued before this load was constructed (for example while
        // the refresh was fetching the URL) is newer than the caller's
        // snapshot and must win.
        let pending = self.shared.pending_seek.write().take();
        // A cast hand-off parks a playhead for its track; the playback loop
        // stops the outgoing stream before calling us, which clears the
        // ordinary seek state but not this. A hand-off from a paused or
        // stopped session also parks the load itself (`play == false`), so
        // stopping the cast never starts the song on this machine.
        let resume = self.take_resume_handoff(track);
        let target = pending
            .or_else(|| resume.as_ref().map(|handoff| handoff.position))
            .or(position)
            .unwrap_or(0.0)
            .max(0.0);
        let play = play && resume.map(|handoff| handoff.play).unwrap_or(true);
        self.shared
            .eos_ignore_until_ms
            .store(now_ms() + EOF_GUARD.as_millis() as u64, Ordering::SeqCst);

        // `loadfile ... replace` replaces the whole playlist, including any
        // preloaded next entry.
        *self.shared.preloaded.write() = None;
        self.shared.load_pending.store(true, Ordering::SeqCst);
        self.shared.eos_signaled.store(false, Ordering::SeqCst);
        self.shared.stream_stale.store(false, Ordering::SeqCst);
        *self.shared.current_uri.write() = Some(uri.to_string());
        *self.shared.format_info.write() = format;
        *self.shared.format_track.write() = Some(track.id.clone());
        *self.shared.position_track.write() = Some(track.clone());
        *self.shared.last_position.write() = target;
        *self.shared.duration.write() = 0.0;
        *self.shared.saved_sleep_position.write() = if target > 0.0 { Some(target) } else { None };
        self.shared
            .volume_apply_pending
            .store(true, Ordering::SeqCst);
        self.shared.mark_persist_dirty();
        *self.shared.state.write() = if play {
            PlaybackState::Playing
        } else {
            PlaybackState::Paused
        };
        if play {
            self.shared.mark_playing();
        } else {
            self.shared.set_paused_now();
        }

        info!(
            "{} stream URI: {}",
            if play { "Playing" } else { "Preparing" },
            uri
        );

        let result = self.with_client(|client| {
            // Pause before loading so a parked stream never emits a burst
            // between loadfile and the seek.
            if !play {
                client.set_pause(true)?;
            }
            client.loadfile(uri, (target > 0.0).then_some(target))?;

            let deadline = Instant::now() + LOAD_SETTLE;
            loop {
                let idle = client
                    .get_property("idle-active")?
                    .and_then(|value| value.as_bool());
                let duration = client
                    .get_property("duration")?
                    .and_then(|value| value.as_f64());
                if duration.unwrap_or(0.0) > 0.0 {
                    break;
                }
                if Instant::now() >= deadline {
                    if idle == Some(true) {
                        return Err("mpv could not load the stream".to_string());
                    }
                    // The stream can still be fetching; do not turn a slow
                    // start into a failure. The poller will publish it.
                    break;
                }
                std::thread::sleep(Duration::from_millis(50));
            }

            client.set_pause(!play)?;

            // A seek may have arrived while loadfile was settling. Apply the
            // newest target after the initial seek so the load cannot
            // overwrite it.
            let late_seek = self.shared.pending_seek.write().take();
            if let Some(pending) = late_seek {
                match client.seek(pending) {
                    Ok(()) => *self.shared.last_position.write() = pending,
                    Err(e) => warn!("Could not apply a seek made during the stream load: {e}"),
                }
            }
            Ok(())
        });

        self.shared.load_pending.store(false, Ordering::SeqCst);
        match result {
            Ok(()) => {
                // Catch a seek that landed after the closure's last check.
                if let Some(pending) = self.shared.pending_seek.write().take() {
                    match self.with_client(|client| client.seek(pending)) {
                        Ok(()) => *self.shared.last_position.write() = pending,
                        Err(e) => {
                            warn!("Could not apply a seek made during the stream load: {e}")
                        }
                    }
                }
                *self.shared.saved_sleep_position.write() = None;
                self.shared
                    .eos_ignore_until_ms
                    .store(now_ms() + EOF_GUARD.as_millis() as u64, Ordering::SeqCst);
                if play {
                    self.shared.restart_progress_window();
                }
                // Arm the next-track preload for whatever just started. This
                // fires from every path that loads a stream — plain Play
                // reloads included — so no caller can forget to re-arm it.
                let _ = self.shared.stream_started_tx.send(track.clone());
                Ok(())
            }
            Err(e) => {
                *self.shared.pending_seek.write() = None;
                *self.shared.state.write() = PlaybackState::Stopped;
                self.shared.stream_stale.store(true, Ordering::SeqCst);
                self.shared.clear_paused();
                self.shared.mark_persist_dirty();
                Err(e)
            }
        }
    }

    pub fn play_uri(&self, track: &TrackItem, uri: &str, format: FormatInfo) -> Result<(), String> {
        self.load_uri(track, uri, format, None, true)
    }

    /// Loads a freshly fetched stream URL parked at `position` (paused, or
    /// playing when the user already asked for playback). Used after wake,
    /// where the pre-sleep CDN token is no longer valid.
    pub fn prepare_uri(
        &self,
        track: &TrackItem,
        uri: &str,
        format: FormatInfo,
        position: f64,
    ) -> Result<(), String> {
        let position = if position.is_finite() {
            position.max(0.0)
        } else {
            0.0
        };
        self.load_uri(track, uri, format, Some(position), false)
    }

    /// Appends the next queue track to mpv's playlist. `--prefetch-playlist`
    /// opens and buffers it while `expected_current` plays. The append is
    /// refused once the player has moved on, so a slow TIDAL fetch cannot
    /// attach a stale track. Only one entry is ever held: a re-armed preload
    /// removes the previous appended entry first, so `playlist-next` can only
    /// ever land on the entry the preload record names.
    pub fn append_next(
        &self,
        expected_current: &TrackItem,
        next: &TrackItem,
        uri: &str,
        format: FormatInfo,
    ) -> Result<(), String> {
        if *self.shared.state.read() == PlaybackState::Stopped
            || self.shared.stream_stale.load(Ordering::SeqCst)
            || !self.shared.ipc_healthy.load(Ordering::SeqCst)
            // An in-flight `loadfile … replace` is about to clear the playlist;
            // an entry appended now would vanish with it.
            || self.shared.load_pending.load(Ordering::SeqCst)
        {
            return Ok(());
        }
        self.with_client(|client| {
            let current = self.shared.position_track.read();
            if !current
                .as_ref()
                .is_some_and(|current| same_queue_entry(current, expected_current))
            {
                return Ok(());
            }
            drop(current);
            if let Some(previous) = self.shared.preloaded.read().as_ref().map(|p| p.entry_id) {
                client.playlist_remove_id(previous)?;
            }
            let entry_id = client.appendfile(uri)?;
            if !self.shared.stream_stale.load(Ordering::SeqCst)
                && self
                    .shared
                    .position_track
                    .read()
                    .as_ref()
                    .is_some_and(|current| same_queue_entry(current, expected_current))
            {
                *self.shared.preloaded.write() = Some(PreloadedStream {
                    track: next.clone(),
                    uri: uri.to_string(),
                    format,
                    entry_id,
                });
            }
            Ok(())
        })
    }

    pub fn preloaded_matches(&self, track: &TrackItem) -> bool {
        self.shared
            .preloaded
            .read()
            .as_ref()
            .is_some_and(|preloaded| same_queue_entry(&preloaded.track, track))
    }

    /// Switches mpv to the preloaded playlist entry. The entry is already
    /// buffered, so this needs no TIDAL or CDN round trip. The switch only
    /// happens when the entry after the current one is exactly the appended
    /// preload; a stale entry in the way is refused and the caller falls back
    /// to the ordinary fetch-and-replace path.
    pub fn play_preloaded(&self) -> Result<Option<TrackItem>, String> {
        let Some(preloaded) = self.shared.preloaded.write().take() else {
            return Ok(None);
        };
        self.shared.load_pending.store(true, Ordering::SeqCst);
        let result = self.with_client(|client| {
            let pos = client.playlist_pos()?;
            if pos < 0 {
                warn!("No active playlist entry to promote from; loading the track instead");
                return Ok(false);
            }
            let pos_idx = pos as usize;
            let entries = client.playlist_entries()?;
            if entries.get(pos_idx + 1).copied() != Some(preloaded.entry_id) {
                warn!("The preloaded playlist entry is not next; loading the track instead");
                return Ok(false);
            }
            client.playlist_next()?;
            // `--keep-open=always` paused at the end of the previous entry.
            client.set_pause(false)?;
            // Everything up to and including the finished entry is history.
            // Drop it so the playlist cannot grow without bound across a long
            // session. Best effort: the switch has already happened.
            for &old_id in &entries[..=pos_idx] {
                if old_id == preloaded.entry_id {
                    continue;
                }
                if client.playlist_remove_id(old_id).is_err() {
                    break;
                }
            }
            Ok(true)
        });
        let promoted = match result {
            Ok(true) => true,
            Ok(false) => {
                self.shared.load_pending.store(false, Ordering::SeqCst);
                return Ok(None);
            }
            Err(e) => {
                self.shared.load_pending.store(false, Ordering::SeqCst);
                return Err(e);
            }
        };
        debug_assert!(promoted);
        self.shared.restart_progress_window();

        // A seek issued while the playlist was switching belongs to the new
        // entry; apply it after the promotion.
        let pending = self.shared.pending_seek.write().take();
        if let Some(pending) = pending {
            match self.with_client(|client| client.seek(pending)) {
                Ok(()) => {}
                Err(e) => warn!("Could not apply a seek made during the track switch: {e}"),
            }
        }

        *self.shared.current_uri.write() = Some(preloaded.uri);
        *self.shared.format_info.write() = preloaded.format;
        *self.shared.format_track.write() = Some(preloaded.track.id.clone());
        *self.shared.position_track.write() = Some(preloaded.track.clone());
        *self.shared.last_position.write() = pending.unwrap_or(0.0);
        *self.shared.duration.write() = 0.0;
        *self.shared.saved_sleep_position.write() = None;
        self.shared
            .eos_ignore_until_ms
            .store(now_ms() + EOF_GUARD.as_millis() as u64, Ordering::SeqCst);
        self.shared.eos_signaled.store(false, Ordering::SeqCst);
        self.shared.stream_stale.store(false, Ordering::SeqCst);
        *self.shared.state.write() = PlaybackState::Playing;
        self.shared.mark_playing();
        self.shared.mark_persist_dirty();
        self.shared.load_pending.store(false, Ordering::SeqCst);
        // Re-arm the preload for the track after this one.
        let _ = self.shared.stream_started_tx.send(preloaded.track.clone());
        Ok(Some(preloaded.track))
    }

    pub fn play(&self) -> Result<(), String> {
        // An explicit Play overrides a parked cast hand-off: the user is asking
        // for playback now, not for the paused state the session ended in.
        if let Some(handoff) = self.shared.resume_pending.write().as_mut() {
            handoff.play = true;
        }
        let state_before = self.get_state();
        let paused_too_long = state_before == PlaybackState::Paused
            && self.shared.paused_long_enough(STALE_AFTER_PAUSE);

        if self.stream_is_stale() || paused_too_long {
            self.shared.load_pending.store(true, Ordering::SeqCst);
            self.shared.play_after_refresh.store(true, Ordering::SeqCst);
            *self.shared.state.write() = PlaybackState::Playing;
            self.shared.mark_playing();
            self.shared.mark_persist_dirty();
            self.request_stream_refresh();
            return Ok(());
        }

        let child_ready = {
            let guard = self.ipc.lock();
            guard.is_some() && self.shared.ipc_healthy.load(Ordering::SeqCst)
        };
        let need_load = state_before == PlaybackState::Stopped
            || !child_ready
            || self.shared.position_track.read().is_none();

        if need_load {
            let uri = self.shared.current_uri.read().clone();
            let track = self.shared.position_track.read().clone();
            let format = self.shared.format_info.read().clone();
            if let (Some(uri), Some(track)) = (uri, track) {
                let target = self
                    .shared
                    .saved_sleep_position
                    .write()
                    .take()
                    .unwrap_or_else(|| *self.shared.last_position.read());
                return self.load_uri(&track, &uri, format, Some(target), true);
            }
            if self.shared.position_track.read().is_some()
                || self.shared.saved_sleep_position.read().is_some()
            {
                self.shared.play_after_refresh.store(true, Ordering::SeqCst);
                self.shared.load_pending.store(true, Ordering::SeqCst);
                *self.shared.state.write() = PlaybackState::Playing;
                self.shared.mark_playing();
                self.shared.mark_persist_dirty();
                self.request_stream_refresh();
                return Ok(());
            }
            return Err("No track is loaded".to_string());
        }

        let result = self.with_client(|client| client.set_pause(false));
        if result.is_ok() {
            self.shared.restart_progress_window();
            *self.shared.state.write() = PlaybackState::Playing;
            self.shared.mark_playing();
            self.shared.mark_persist_dirty();
        }
        result
    }

    pub fn pause(&self) -> Result<(), String> {
        self.shared.pause_generation.fetch_add(1, Ordering::SeqCst);
        self.shared
            .play_after_refresh
            .store(false, Ordering::SeqCst);
        self.shared.load_pending.store(false, Ordering::SeqCst);

        let has_client = self.ipc.lock().is_some();
        let loaded =
            self.shared.position_track.read().is_some() && self.shared.current_uri.read().is_some();
        let result = if has_client && loaded {
            self.with_client(|client| client.set_pause(true))
        } else {
            Ok(())
        };
        if result.is_ok() {
            *self.shared.state.write() = if self.shared.position_track.read().is_some() {
                PlaybackState::Paused
            } else {
                PlaybackState::Stopped
            };
            self.shared.mark_paused();
            self.shared.mark_persist_dirty();
        }
        result
    }

    pub fn stop(&self) -> Result<(), String> {
        self.shared.pause_generation.fetch_add(1, Ordering::SeqCst);
        // An explicit Stop ends the hand-off: a later play of the same track
        // is a fresh start, not a resume from the cast playhead.
        *self.shared.resume_pending.write() = None;
        self.stop_internal()
    }

    /// Stops playback and drops the loaded track, URI, and format metadata so
    /// signing out leaves no trace of the previous session in the player or
    /// MPRIS/bar state.
    pub fn reset_for_logout(&self) {
        let _ = self.stop();
        *self.shared.current_uri.write() = None;
        *self.shared.format_info.write() = FormatInfo::default();
        *self.shared.format_track.write() = None;
        *self.shared.position_track.write() = None;
        self.shared.stream_stale.store(false, Ordering::SeqCst);
        self.shared.stall_reported.store(false, Ordering::SeqCst);
        self.shared.mark_persist_dirty();
    }

    /// Stops playback without registering a user pause. The loaded URI and
    /// track are kept so the next Play can reload them.
    pub fn stop_internal(&self) -> Result<(), String> {
        let mut guard = self.ipc.lock();
        if let Some(client) = guard.as_mut() {
            if client.stop().is_err() {
                *guard = None;
                self.shared.ipc_healthy.store(false, Ordering::SeqCst);
            }
        }
        drop(guard);

        *self.shared.preloaded.write() = None;
        *self.shared.pending_seek.write() = None;
        self.shared
            .play_after_refresh
            .store(false, Ordering::SeqCst);
        self.shared.load_pending.store(false, Ordering::SeqCst);
        *self.shared.saved_sleep_position.write() = None;
        *self.shared.last_position.write() = 0.0;
        *self.shared.duration.write() = 0.0;
        *self.shared.state.write() = PlaybackState::Stopped;
        self.shared.eos_signaled.store(false, Ordering::SeqCst);
        self.shared.clear_paused();
        self.shared.mark_persist_dirty();
        Ok(())
    }

    pub fn toggle(&self) -> Result<PlaybackState, String> {
        match self.get_state() {
            PlaybackState::Playing => {
                self.pause()?;
                Ok(PlaybackState::Paused)
            }
            PlaybackState::Paused | PlaybackState::Stopped => {
                self.play()?;
                Ok(PlaybackState::Playing)
            }
        }
    }

    /// Seeks inside the loaded stream. mpv seeks without the flushing
    /// reset/click cycle, so no fade or pause is needed.
    pub fn seek(&self, seconds: f64) -> Result<(), String> {
        if !seconds.is_finite() {
            return Err("invalid seek position".to_string());
        }
        let mut target = seconds.max(0.0);
        let load_pending = self.shared.load_pending.load(Ordering::SeqCst);
        if !load_pending {
            let duration = self.get_duration();
            if duration > 0.0 {
                // Never seek exactly to EOF: with a preloaded next entry that
                // is indistinguishable from the end of the track and can
                // promote the next playlist entry.
                target = target.min((duration - 0.5).max(0.0));
            }
        }
        *self.shared.last_position.write() = target;
        self.shared
            .eos_ignore_until_ms
            .store(now_ms() + EOF_GUARD.as_millis() as u64, Ordering::SeqCst);
        self.shared.mark_persist_dirty();

        if load_pending {
            // The load is still applying its initial seek. Park the newest
            // target; `load_uri` consumes it after loadfile has settled.
            *self.shared.pending_seek.write() = Some(target);
            *self.shared.saved_sleep_position.write() = Some(target);
            debug!("Deferred seek to {target:.2}s until the stream load completes");
            return Ok(());
        }

        let loaded =
            self.shared.position_track.read().is_some() && self.shared.current_uri.read().is_some();
        let has_client = self.ipc.lock().is_some();
        if !loaded || !has_client || self.get_state() == PlaybackState::Stopped {
            *self.shared.saved_sleep_position.write() = Some(target);
            return Ok(());
        }

        debug!(
            "Seek to {target:.2}s (state {:?}, duration {:.2}s)",
            self.get_state(),
            self.get_duration()
        );
        let needs_reload = self
            .with_client(|client| Ok(client.seek_needs_reload(target)))
            .unwrap_or(false);
        if needs_reload {
            // The demuxer cache already read the stream to EOF, so FFmpeg's
            // DASH demuxer closed the representation this URI was playing
            // from. A plain seek would only move the playhead and then return
            // EOF again, leaving mpv silent. Re-open the same URI at the
            // target instead.
            let uri = self.shared.current_uri.read().clone();
            let track = self.shared.position_track.read().clone();
            if let (Some(uri), Some(track)) = (uri, track) {
                let format = self.shared.format_info.read().clone();
                let play = self.get_state() == PlaybackState::Playing;
                info!(
                    "Seek target {target:.2}s is outside mpv's cache; reloading the stream at that position"
                );
                return self.load_uri(&track, &uri, format, Some(target), play);
            }
        }
        let result = self.with_client(|client| client.seek(target));
        if result.is_ok() {
            *self.shared.saved_sleep_position.write() = None;
        }
        result
    }

    pub fn request_stream_refresh(&self) {
        self.shared.stream_stale.store(true, Ordering::SeqCst);
        let _ = self.shared.refresh_tx.send(());
    }

    pub fn begin_stream_refresh(&self) -> bool {
        !self.shared.refresh_in_flight.swap(true, Ordering::SeqCst)
    }

    pub fn end_stream_refresh(&self) {
        self.shared.refresh_in_flight.store(false, Ordering::SeqCst);
    }

    pub fn refresh_failed(&self) {
        *self.shared.preloaded.write() = None;
        *self.shared.pending_seek.write() = None;
        // A failed load must not leave a hand-off position behind to surprise
        // the next play of the same track.
        *self.shared.resume_pending.write() = None;
        self.shared
            .play_after_refresh
            .store(false, Ordering::SeqCst);
        self.shared.load_pending.store(false, Ordering::SeqCst);
        self.shared.stream_stale.store(true, Ordering::SeqCst);
        if *self.shared.state.read() == PlaybackState::Playing {
            self.shared.park_position();
            *self.shared.state.write() = PlaybackState::Stopped;
        }
        self.shared.mark_persist_dirty();
    }

    pub fn sleep_token(&self) -> u64 {
        self.shared.sleep_generation.load(Ordering::SeqCst)
    }

    /// Changes whenever a pre-sleep teardown runs. A refresh that started
    /// before it must not resurrect the stream.
    pub fn sleep_epoch(&self) -> u64 {
        self.shared.sleep_epoch.load(Ordering::SeqCst)
    }

    /// Synchronously records the pre-sleep position and bumps `sleep_epoch`
    /// before the blocking mpv stop runs on a worker thread, so a rapid
    /// suspend/resume cannot miss `saved_sleep_position`.
    pub fn begin_prepare_for_sleep(&self, token: u64) -> Option<bool> {
        if self.shared.sleep_generation.load(Ordering::SeqCst) != token {
            info!("Machine already woke up; skipping the pre-sleep player teardown");
            return None;
        }
        let position = self.get_position().max(0.0);
        let had_playback = self.get_state() != PlaybackState::Stopped;
        // Supersede any stream refresh still waiting on TIDAL: its URL would
        // land in a player that this teardown is about to stop.
        self.shared.sleep_epoch.fetch_add(1, Ordering::SeqCst);
        if had_playback {
            *self.shared.saved_sleep_position.write() = Some(position);
            info!("Saved playback position before sleep: {:.2}s", position);
        }
        Some(had_playback)
    }

    pub fn finish_prepare_for_sleep(&self, token: u64, had_playback: bool) {
        if self.shared.sleep_generation.load(Ordering::SeqCst) != token {
            return;
        }
        let mut guard = self.ipc.lock();
        if self.shared.sleep_generation.load(Ordering::SeqCst) != token {
            return;
        }
        if let Some(client) = guard.as_mut() {
            if client.stop().is_err() {
                *guard = None;
                self.shared.child_pid.store(0, Ordering::SeqCst);
            }
        }
        drop(guard);
        if self.shared.sleep_generation.load(Ordering::SeqCst) != token {
            return;
        }
        *self.shared.preloaded.write() = None;
        *self.shared.pending_seek.write() = None;
        self.shared
            .play_after_refresh
            .store(false, Ordering::SeqCst);
        self.shared.load_pending.store(false, Ordering::SeqCst);
        *self.shared.state.write() = if had_playback {
            PlaybackState::Paused
        } else {
            PlaybackState::Stopped
        };
        self.shared.mark_paused();
        self.shared.mark_persist_dirty();
    }

    pub fn resume_from_sleep(&self) {
        self.shared.sleep_generation.fetch_add(1, Ordering::SeqCst);
        self.shared.load_pending.store(false, Ordering::SeqCst);
        self.shared
            .play_after_refresh
            .store(false, Ordering::SeqCst);
        if self.shared.saved_sleep_position.read().is_some() {
            info!("System resumed from sleep: waiting for a fresh stream");
            self.shared.stream_stale.store(true, Ordering::SeqCst);
            *self.shared.state.write() = PlaybackState::Paused;
            self.shared.set_paused_now();
        } else {
            *self.shared.state.write() = PlaybackState::Stopped;
            self.shared.clear_paused();
        }
        self.shared.mark_persist_dirty();
    }

    /// Replaces the mpv process with a fresh one. Used on wake and after an
    /// unresponsive command; the caller refreshes the stream URL separately.
    pub fn rebuild_pipeline(&self) -> Result<(), String> {
        self.rebuild_pipeline_inner(false)
    }

    /// Same as `rebuild_pipeline`, but preserves an in-flight `play_after_refresh`
    /// intent recorded while a wake/refresh fetch was waiting.
    pub fn rebuild_pipeline_for_refresh(&self) -> Result<(), String> {
        self.rebuild_pipeline_inner(true)
    }

    fn rebuild_pipeline_inner(&self, preserve_play_intent: bool) -> Result<(), String> {
        let mut guard = self
            .ipc
            .try_lock_for(Duration::from_secs(2))
            .ok_or_else(|| "mpv process is busy".to_string())?;
        *guard = None;
        self.shared.child_pid.store(0, Ordering::SeqCst);
        self.shared.ipc_healthy.store(false, Ordering::SeqCst);
        self.shared.stream_stale.store(true, Ordering::SeqCst);
        self.shared.load_pending.store(false, Ordering::SeqCst);
        self.shared.eos_signaled.store(false, Ordering::SeqCst);
        if !preserve_play_intent {
            self.shared
                .play_after_refresh
                .store(false, Ordering::SeqCst);
            *self.shared.pending_seek.write() = None;
        }
        *self.shared.preloaded.write() = None;
        *self.shared.current_uri.write() = None;
        *self.shared.duration.write() = 0.0;
        *self.shared.state.write() = PlaybackState::Stopped;
        self.shared.clear_paused();
        self.shared.mark_persist_dirty();

        let client = self.spawn_ipc()?;
        *guard = Some(client);
        self.shared.ipc_healthy.store(true, Ordering::SeqCst);
        info!("Restarted the mpv playback process");
        Ok(())
    }

    pub fn has_saved_sleep_position(&self) -> bool {
        self.shared.saved_sleep_position.read().is_some()
    }

    pub fn stream_is_stale(&self) -> bool {
        self.shared.stream_stale.load(Ordering::SeqCst)
    }

    pub fn pause_generation(&self) -> u64 {
        self.shared.pause_generation.load(Ordering::SeqCst)
    }

    pub fn note_user_pause(&self) {
        self.shared.pause_generation.fetch_add(1, Ordering::SeqCst);
    }

    pub fn mark_stream_stale(&self) {
        self.shared.stream_stale.store(true, Ordering::SeqCst);
    }

    pub fn get_position(&self) -> f64 {
        if let Some(saved) = *self.shared.saved_sleep_position.read() {
            return saved;
        }
        *self.shared.last_position.read()
    }

    pub fn get_duration(&self) -> f64 {
        *self.shared.duration.read()
    }

    pub fn set_volume(&self, vol: f64) {
        if !vol.is_finite() {
            return;
        }
        let clamped = vol.clamp(0.0, 1.5);
        *self.shared.volume.write() = clamped;
        self.shared
            .volume_generation
            .fetch_add(1, Ordering::SeqCst);
        self.shared
            .volume_apply_pending
            .store(true, Ordering::SeqCst);
        self.shared.mark_persist_dirty();
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            let shared = Arc::clone(&self.shared);
            let generation = shared.volume_generation.load(Ordering::SeqCst);
            handle.spawn(async move {
                if async_set_pipewire_stream_volume(clamped).await
                    && shared.volume_generation.load(Ordering::SeqCst) == generation
                {
                    shared.volume_apply_pending.store(false, Ordering::SeqCst);
                }
            });
        }
    }

    pub fn get_volume(&self) -> f64 {
        *self.shared.volume.read()
    }

    pub fn persisted_state(&self) -> PersistedPlayerState {
        let volume = self.get_volume();
        let parked = self.shared.saved_sleep_position.read().is_some();
        if *self.shared.state.read() == PlaybackState::Stopped && !parked {
            return PersistedPlayerState {
                volume,
                ..Default::default()
            };
        }
        PersistedPlayerState {
            track: self.shared.position_track.read().clone(),
            position: self.get_position().max(0.0),
            volume,
            ..Default::default()
        }
    }

    pub fn take_persist_dirty(&self) -> bool {
        self.shared.persist_dirty.swap(false, Ordering::SeqCst)
    }

    pub fn restore_parked_state(&self, track: &TrackItem, position: f64) -> Result<(), String> {
        self.seek(position)?;
        *self.shared.position_track.write() = Some(track.clone());
        // The stream died with the previous process; the persisted format
        // belongs to it, not to the parked track. The next load sets both.
        *self.shared.format_track.write() = None;
        self.shared.mark_persist_dirty();
        Ok(())
    }

    /// Parks the next local load of `track` at `position`, playing. A cast
    /// session uses this when it hands playback back: the playback loop fetches
    /// a fresh stream URL and `load_uri` starts at this position instead of
    /// zero.
    ///
    /// The position is tagged with its track and kept out of `pending_seek`,
    /// because the playback loop calls `stop_internal` right before loading the
    /// resumed track and that stop clears the ordinary seek state.
    pub fn resume_local_at(&self, track: &TrackItem, position: f64) {
        self.park_handoff(track, position, true);
    }

    /// The same hand-off, but the local track comes back parked: a cast session
    /// that was paused or stopped hands its playhead back without resuming, so
    /// stopping the cast leaves the song paused on this machine.
    pub fn park_local_at(&self, track: &TrackItem, position: f64) {
        self.park_handoff(track, position, false);
    }

    fn park_handoff(&self, track: &TrackItem, position: f64, play: bool) {
        let position = if position.is_finite() {
            position.max(0.0)
        } else {
            0.0
        };
        *self.shared.resume_pending.write() = Some(ResumeHandoff {
            track_id: track.id.clone(),
            position,
            play,
        });
        self.shared.stream_stale.store(true, Ordering::SeqCst);
        self.shared.mark_persist_dirty();
    }

    /// The hand-off parked for `track`, if any.
    fn take_resume_handoff(&self, track: &TrackItem) -> Option<ResumeHandoff> {
        let mut pending = self.shared.resume_pending.write();
        match pending.as_ref() {
            Some(handoff) if handoff.track_id == track.id => pending.take(),
            // A hand-off for another track is stale (the user picked something
            // else while it was parked); drop it rather than seek a fresh
            // track partway through.
            Some(_) => {
                *pending = None;
                None
            }
            None => None,
        }
    }

    pub fn get_state(&self) -> PlaybackState {
        *self.shared.state.read()
    }

    /// The stream's format, but only while it belongs to `track_id`. The
    /// status snapshot uses this to avoid pairing a just-selected track with
    /// the previous stream's badge during the TIDAL fetch.
    pub fn format_for(&self, track_id: &str) -> Option<FormatInfo> {
        let owner = self.shared.format_track.read();
        if owner.as_deref() == Some(track_id) {
            Some(self.shared.format_info.read().clone())
        } else {
            None
        }
    }

    pub fn start_volume_sync(self: &Arc<Self>) {
        let player = Arc::clone(self);
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(Duration::from_millis(1500));
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                if player.shutdown.load(Ordering::SeqCst) {
                    return;
                }
                ticker.tick().await;
                let state = player.get_state();
                if state == PlaybackState::Stopped {
                    continue;
                }
                if player.shared.volume_apply_pending.load(Ordering::SeqCst) {
                    let generation = player.shared.volume_generation.load(Ordering::SeqCst);
                    let volume = *player.shared.volume.read();
                    if async_set_pipewire_stream_volume(volume).await
                        && player.shared.volume_generation.load(Ordering::SeqCst) == generation
                    {
                        player
                            .shared
                            .volume_apply_pending
                            .store(false, Ordering::SeqCst);
                    }
                } else if state == PlaybackState::Playing {
                    let generation = player.shared.volume_generation.load(Ordering::SeqCst);
                    if let Some(status) = async_wpctl_status().await {
                        if let Some(pw_vol) = async_get_pipewire_stream_volume(&status).await {
                            if player.shared.volume_generation.load(Ordering::SeqCst) == generation
                                && !player.shared.volume_apply_pending.load(Ordering::SeqCst)
                            {
                                let cur = *player.shared.volume.read();
                                if (cur - pw_vol).abs() > 0.01 {
                                    *player.shared.volume.write() = pw_vol;
                                    player.shared.mark_persist_dirty();
                                }
                            }
                        }
                    }
                }
            }
        });
    }

    pub fn pipeline_available(&self, timeout: Duration) -> bool {
        match self.ipc.try_lock_for(timeout) {
            Some(guard) => guard.is_none() || self.shared.ipc_healthy.load(Ordering::SeqCst),
            None => false,
        }
    }

    /// Stops the mpv child and the IPC poller. The daemon calls this on
    /// shutdown so a manually started daemon does not leave the player behind.
    pub fn shutdown(&self) {
        self.shutdown.store(true, Ordering::SeqCst);
        if let Some(mut guard) = self.ipc.try_lock_for(Duration::from_secs(1)) {
            *guard = None;
            self.shared.child_pid.store(0, Ordering::SeqCst);
        } else {
            let pid = self.shared.child_pid.swap(0, Ordering::SeqCst);
            if pid > 0 {
                let _ = Command::new("kill")
                    .args(["-9", &pid.to_string()])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status();
            }
        }
    }
}

impl Drop for MpvPlayer {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn poll_client(shared: &Shared, client: &mut MpvIpc) -> Result<(), String> {
    let time = client
        .get_property("time-pos")?
        .and_then(|value| value.as_f64());
    let duration = client
        .get_property("duration")?
        .and_then(|value| value.as_f64());
    let pause = client
        .get_property("pause")?
        .and_then(|value| value.as_bool());
    let idle = client
        .get_property("idle-active")?
        .and_then(|value| value.as_bool());
    let eof = client
        .get_property("eof-reached")?
        .and_then(|value| value.as_bool());
    // Optional: an older mpv without this property must not poison the poll.
    let buffering = client
        .get_property("cache-buffering-state")
        .ok()
        .flatten()
        .and_then(|value| value.as_f64());

    let now = now_ms();
    let previous_position = *shared.last_position.read();
    let moved = time.is_some_and(|time| {
        time.is_finite() && time >= 0.0 && (time - previous_position).abs() >= PROGRESS_EPSILON
    });
    if moved || shared.last_progress_ms.load(Ordering::SeqCst) == 0 {
        shared.last_progress_ms.store(now, Ordering::SeqCst);
    }
    if moved {
        shared.stall_reported.store(false, Ordering::SeqCst);
    }

    if let Some(time) = time {
        if time.is_finite() && time >= 0.0 {
            *shared.last_position.write() = time;
        }
    }
    if let Some(duration) = duration {
        if duration.is_finite() && duration >= 0.0 {
            *shared.duration.write() = duration;
        }
    }

    if shared.load_pending.load(Ordering::SeqCst) {
        return Ok(());
    }

    if eof == Some(true) {
        let position = *shared.last_position.read();
        let duration = *shared.duration.read();
        let ignore_until = shared.eos_ignore_until_ms.load(Ordering::SeqCst);
        if !eof_is_current(position, duration, now_ms(), ignore_until) {
            // mpv can report the previous entry's EOF for a moment after a
            // seek or load. Treating that as EOS would advance the queue and
            // promote the preloaded next track.
            debug!("Ignoring transient mpv EOF at {position:.2}s of {duration:.2}s");
            return Ok(());
        }
        if !shared.eos_signaled.swap(true, Ordering::SeqCst) {
            info!("mpv reached EOF at {position:.2}s of {duration:.2}s");
            shared.clear_paused();
            *shared.state.write() = PlaybackState::Stopped;
            shared.mark_persist_dirty();
            let _ = shared.on_eos_tx.send(());
        }
        return Ok(());
    }

    let next = if idle == Some(true) {
        PlaybackState::Stopped
    } else if pause == Some(true) {
        PlaybackState::Paused
    } else if pause == Some(false) {
        PlaybackState::Playing
    } else {
        return Ok(());
    };

    if *shared.state.read() != next {
        *shared.state.write() = next;
        shared.mark_persist_dirty();
    }
    match next {
        PlaybackState::Playing => shared.mark_playing(),
        PlaybackState::Paused => shared.mark_paused(),
        PlaybackState::Stopped => shared.clear_paused(),
    }

    if audio_output_stalled(
        now,
        shared.last_progress_ms.load(Ordering::SeqCst),
        moved,
        buffering,
        next == PlaybackState::Playing,
    ) && !shared.stall_reported.swap(true, Ordering::SeqCst)
    {
        let position = *shared.last_position.read();
        warn!(
            "mpv reports playback but the audio clock has not moved at {position:.2}s; \
             nothing is consuming the stream"
        );
        // Stop claiming playback: pause mpv so the derived state parks, and
        // mark the stream stale so the next Play loads a fresh one instead of
        // unpausing silence. The playback loop turns this into a visible error.
        shared.stream_stale.store(true, Ordering::SeqCst);
        let _ = client.set_pause(true);
        let _ = shared.stall_tx.send(());
    }
    Ok(())
}

/// How long the audio clock may stand still while mpv reports playback before
/// the output is treated as stalled.
const STALL_REPORT_AFTER_MS: u64 = 10_000;

/// A poll-to-poll position change this large is real progress; `time-pos`
/// jitters by microseconds between reads.
const PROGRESS_EPSILON: f64 = 0.05;

/// True when mpv says it is playing, is not buffering, and its clock has not
/// moved. That combination means nothing is consuming the stream: no sink, a
/// node WirePlumber never linked, or a wedged audio device. Buffering is
/// excluded so a slow network does not look like a dead output.
fn audio_output_stalled(
    now_ms: u64,
    last_progress_ms: u64,
    moved: bool,
    buffering: Option<f64>,
    playing: bool,
) -> bool {
    playing
        && !moved
        && buffering.is_some_and(|state| state >= 99.0)
        && now_ms.saturating_sub(last_progress_ms) >= STALL_REPORT_AFTER_MS
}

fn spawn_poller(
    shared: Arc<Shared>,
    ipc: Arc<parking_lot::Mutex<Option<MpvIpc>>>,
    shutdown: Arc<AtomicBool>,
) {
    let _ = std::thread::Builder::new()
        .name("mpv-poller".to_string())
        .spawn(move || loop {
            std::thread::sleep(POSITION_POLL_INTERVAL);
            if shutdown.load(Ordering::SeqCst) {
                return;
            }
            let mut guard = ipc.lock();
            let Some(client) = guard.as_mut() else {
                continue;
            };
            if let Err(e) = poll_client(&shared, client) {
                warn!("mpv stopped answering: {e}; it will be restarted on the next command");
                shared.ipc_healthy.store(false, Ordering::SeqCst);
                shared.stream_stale.store(true, Ordering::SeqCst);
                *shared.preloaded.write() = None;
                *shared.pending_seek.write() = None;
                shared.clear_paused();
                *shared.state.write() = PlaybackState::Stopped;
                shared.mark_persist_dirty();
                *guard = None;
            } else {
                // A command may have marked the client unhealthy for a bad
                // request; a successful property poll proves it is alive.
                shared.ipc_healthy.store(true, Ordering::SeqCst);
            }
        });
}

/// The player-process surface a bounded operation needs: the current process
/// generation (so a timeout cannot restart a process someone else replaced)
/// and a way to retire an unresponsive one. The MPRIS layer reaches it through
/// its `dyn MprisPlayback + PipelineOwner` handle.
pub trait PipelineOwner: Send + Sync + 'static {
    fn pipeline_generation(&self) -> u64;
    fn rebuild_wedged_pipeline(&self) -> Result<(), String>;
    /// User pause/stop generation at the time the operation was issued.
    fn pause_generation(&self) -> u64;
}

impl PipelineOwner for MpvPlayer {
    fn pipeline_generation(&self) -> u64 {
        self.shared.generation.load(Ordering::SeqCst)
    }

    fn rebuild_wedged_pipeline(&self) -> Result<(), String> {
        self.rebuild_pipeline()
    }

    fn pause_generation(&self) -> u64 {
        MpvPlayer::pause_generation(self)
    }
}

pub fn pipeline_operation_wedged(error: &str) -> bool {
    error.contains(PIPELINE_WEDGED_ERROR)
}

/// Runs a blocking player operation on a blocking thread and bounds it. On
/// timeout the mpv process is replaced: the orphaned thread only owns the old
/// IPC socket, so it cannot hold up the daemon.
pub async fn run_pipeline_op<P, T, F>(
    player: &Arc<P>,
    timeout: Duration,
    operation: F,
) -> Result<T, String>
where
    P: PipelineOwner + ?Sized,
    T: Send + 'static,
    F: FnOnce(Arc<P>) -> Result<T, String> + Send + 'static,
{
    let generation = player.pipeline_generation();
    let task_player = Arc::clone(player);
    let handle = tokio::task::spawn_blocking(move || operation(task_player));
    match tokio::time::timeout(timeout, handle).await {
        Ok(Ok(result)) => result,
        Ok(Err(join_error)) => Err(format!("player operation failed: {join_error}")),
        Err(_) => {
            if player.pipeline_generation() == generation {
                warn!(
                    "mpv did not respond within {}s; restarting it",
                    timeout.as_secs()
                );
                if let Err(e) = player.rebuild_wedged_pipeline() {
                    warn!("Could not restart mpv after the timeout: {e}");
                }
            }
            Err(PIPELINE_WEDGED_ERROR.to_string())
        }
    }
}

/// Runs a stream load with one retry on the replacement process. A timeout
/// restarts mpv inside `run_pipeline_op`; the retry is safe because the new
/// process is idle.
pub async fn run_stream_op<P, T, F>(
    player: &Arc<P>,
    timeout: Duration,
    operation: F,
) -> Result<T, String>
where
    P: PipelineOwner + ?Sized,
    T: Send + 'static,
    F: Fn(Arc<P>) -> Result<T, String> + Send + Sync + 'static,
{
    let operation = Arc::new(operation);
    for attempt in 1..=2u32 {
        let operation = Arc::clone(&operation);
        match run_pipeline_op(player, timeout, move |p| (*operation)(p)).await {
            Ok(value) => return Ok(value),
            Err(error) if pipeline_operation_wedged(&error) && attempt == 1 => {
                info!(
                    "mpv answered after the timeout; retrying the stream load on the new process"
                );
            }
            Err(error) => return Err(error),
        }
    }
    unreachable!("stream load loop always returns")
}

pub async fn ensure_audio_client_ready(player: &Arc<MpvPlayer>) -> Result<(), String> {
    let player = Arc::clone(player);
    tokio::task::spawn_blocking(move || player.ensure_child())
        .await
        .map_err(|e| format!("mpv health check failed: {e}"))?
}

/// Every PipeWire stream id carrying TIDAL's identity. When several match, the
/// older ones are streams whose player process was retired but whose node has
/// not disappeared yet.
pub fn parse_tidal_stream_ids(stdout: &str) -> Vec<u32> {
    let mut in_streams = false;
    let mut found = Vec::new();
    for line in stdout.lines() {
        if line.contains("Streams:") {
            in_streams = true;
            continue;
        }
        if in_streams {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            if !line.starts_with(' ') && !line.starts_with('\t') {
                in_streams = false;
                continue;
            }
            if trimmed.contains("TIDAL Player") || trimmed.contains("scorchedegg.tidalplayer") {
                if let Some(dot_pos) = trimmed.find('.') {
                    if let Ok(id) = trimmed[..dot_pos].trim().parse::<u32>() {
                        found.push(id);
                    }
                }
            }
        }
    }
    found
}

pub fn parse_tidal_stream_id(stdout: &str) -> Option<u32> {
    parse_tidal_stream_ids(stdout).into_iter().max()
}

async fn async_wpctl_status() -> Option<String> {
    let mut cmd = tokio::process::Command::new("wpctl");
    cmd.arg("status").kill_on_drop(true);
    let output = tokio::time::timeout(Duration::from_millis(500), cmd.output())
        .await
        .ok()?
        .ok()?;

    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).into_owned())
}

async fn async_get_pipewire_stream_volume(status: &str) -> Option<f64> {
    let id = parse_tidal_stream_id(status)?;
    let mut cmd = tokio::process::Command::new("wpctl");
    cmd.args(["get-volume", &id.to_string()]).kill_on_drop(true);
    let output = tokio::time::timeout(Duration::from_millis(500), cmd.output())
        .await
        .ok()?
        .ok()?;

    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    if stdout.contains("[MUTED]") {
        return Some(0.0);
    }
    for part in stdout.split_whitespace() {
        if let Ok(val) = part.parse::<f64>() {
            if val.is_finite() {
                return Some(val);
            }
        }
    }
    None
}

/// Writes `vol` to the newest TIDAL stream node. Returns true only when the
/// node was found and `wpctl` accepted the value.
async fn async_set_pipewire_stream_volume(vol: f64) -> bool {
    let Some(id) = async_wpctl_status()
        .await
        .and_then(|status| parse_tidal_stream_id(&status))
    else {
        return false;
    };
    let vol_str = format!("{:.2}", vol.clamp(0.0, 1.5));
    let mut cmd = tokio::process::Command::new("wpctl");
    cmd.args([
        "set-volume",
        "--limit",
        "1.5",
        &id.to_string(),
        &vol_str,
    ])
    .kill_on_drop(true);
    matches!(
        tokio::time::timeout(Duration::from_millis(500), cmd.output()).await,
        Ok(Ok(output)) if output.status.success()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_track(id: &str) -> TrackItem {
        TrackItem {
            id: id.to_string(),
            title: format!("Track {id}"),
            artist: "Artist".to_string(),
            album: "Album".to_string(),
            duration: 10.0,
            ..Default::default()
        }
    }

    fn player() -> MpvPlayer {
        let (tx, _rx) = mpsc::unbounded_channel();
        let (refresh_tx, _refresh_rx) = mpsc::unbounded_channel();
        let (stall_tx, _stall_rx) = mpsc::unbounded_channel();
        let (started_tx, _started_rx) = mpsc::unbounded_channel();
        MpvPlayer::new(tx, refresh_tx, stall_tx, started_tx).unwrap()
    }

    #[test]
    fn a_frozen_audio_clock_on_a_buffered_stream_is_a_stalled_output() {
        assert!(audio_output_stalled(20_000, 5_000, false, Some(100.0), true));
    }

    #[test]
    fn a_cast_length_gap_does_not_make_the_next_load_look_stalled() {
        // Reproduces the cast hand-back: local playback stopped for the whole
        // session, so the stamp is minutes old when the resumed stream starts
        // at the device's position (and `time-pos` equals the pre-set target on
        // the first poll, so no movement is observed yet).
        let player = player();
        player
            .shared
            .last_progress_ms
            .store(now_ms() - 13 * 60 * 1000, Ordering::SeqCst);
        assert!(audio_output_stalled(
            now_ms(),
            player.shared.last_progress_ms.load(Ordering::SeqCst),
            false,
            Some(100.0),
            true
        ));

        player.shared.restart_progress_window();
        let restarted = player.shared.last_progress_ms.load(Ordering::SeqCst);
        assert!(now_ms().saturating_sub(restarted) < 1_000);
        assert!(!audio_output_stalled(
            now_ms(),
            restarted,
            false,
            Some(100.0),
            true
        ));
    }

    #[test]
    fn buffering_progress_and_pause_are_not_stalls() {
        // The network is the problem, not the output: the cache is still filling.
        assert!(!audio_output_stalled(20_000, 5_000, false, Some(40.0), true));
        // The clock moved, so something is consuming the stream.
        assert!(!audio_output_stalled(20_000, 19_900, true, Some(100.0), true));
        // Paused or stopped: a still clock is expected.
        assert!(!audio_output_stalled(20_000, 5_000, false, Some(100.0), false));
        // No cache to ask (an un-cached stream): never guess.
        assert!(!audio_output_stalled(20_000, 5_000, false, None, true));
        // Still inside the grace window.
        assert!(!audio_output_stalled(14_900, 5_000, false, Some(100.0), true));
    }

    #[test]
    fn a_format_only_belongs_to_the_track_that_loaded_it() {
        let player = player();
        assert!(player.format_for("a").is_none());

        *player.shared.format_info.write() = FormatInfo {
            bit_depth: 24,
            sample_rate: 96000,
            quality: "HI_RES_LOSSLESS".to_string(),
            badge: "24-bit / 96 kHz FLAC".to_string(),
        };
        *player.shared.format_track.write() = Some("a".to_string());

        assert_eq!(player.format_for("a").unwrap().badge, "24-bit / 96 kHz FLAC");
        // The queue can move before the new stream's playback-info lands; the
        // old stream's badge must not follow it.
        assert!(player.format_for("b").is_none());

        // A parked restore has no stream behind it, so its persisted format is
        // not claimed for the track either.
        *player.shared.format_track.write() = None;
        assert!(player.format_for("a").is_none());
    }

    fn wait_for(mut condition: impl FnMut() -> bool, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if condition() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        condition()
    }

    fn audio_test_lock() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn mpv_available() -> bool {
        Command::new("mpv")
            .arg("--version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false)
    }

    fn ffmpeg_available() -> bool {
        Command::new("ffmpeg")
            .arg("-version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false)
    }

    /// Serves `dir` over HTTP with a delay per request, so mpv's demuxer cache
    /// cannot read a whole DASH stream before the test issues its seek.
    fn serve_slow_dash(
        dir: PathBuf,
        delay: Duration,
    ) -> (u16, Arc<AtomicBool>, std::thread::JoinHandle<()>) {
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let port = listener.local_addr().unwrap().port();
        let stop = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&stop);
        let shared_dir = Arc::new(dir);
        let handle = std::thread::spawn(move || {
            while !flag.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        // mpv keeps HTTP connections open, so each accepted
                        // socket needs its own thread or a keep-alive
                        // connection would starve the next segment fetch.
                        let dir = Arc::clone(&shared_dir);
                        std::thread::spawn(move || serve_dash_file(&mut stream, &dir, delay));
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(10));
                    }
                    Err(_) => break,
                }
            }
        });
        (port, stop, handle)
    }

    fn serve_dash_file(stream: &mut std::net::TcpStream, dir: &std::path::Path, delay: Duration) {
        let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
        let Ok(reader) = stream.try_clone() else {
            return;
        };
        let mut reader = BufReader::new(reader);
        let mut request = String::new();
        if reader.read_line(&mut request).unwrap_or(0) == 0 {
            return;
        }
        let mut header = String::new();
        loop {
            header.clear();
            if reader.read_line(&mut header).unwrap_or(0) == 0 || header == "\r\n" {
                break;
            }
        }
        let name = request
            .split_whitespace()
            .nth(1)
            .unwrap_or("/")
            .trim_start_matches('/');
        let body = std::fs::read(dir.join(name)).unwrap_or_default();
        // TIDAL serves a local DASH manifest whose segments come from the CDN;
        // delay only the segments so the manifest reports its duration at once.
        if name.ends_with(".m4s") {
            std::thread::sleep(delay);
        }
        let head = format!(
            "HTTP/1.0 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        );
        let _ = stream.write_all(head.as_bytes());
        let _ = stream.write_all(&body);
    }

    fn playing_wav_uri(seconds: u32) -> String {
        let path = std::env::temp_dir().join(format!(
            "omarchy-tidalplayer-mpv-test-{}-{seconds}.wav",
            std::process::id()
        ));
        let sample_rate = 48_000u32;
        let data_len = sample_rate * seconds * 2;
        let mut wav = Vec::with_capacity(44 + data_len as usize);
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + data_len).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&sample_rate.to_le_bytes());
        wav.extend_from_slice(&(sample_rate * 2).to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&data_len.to_le_bytes());
        wav.resize(44 + data_len as usize, 0);
        std::fs::write(&path, wav).unwrap();
        format!("file://{}", path.display())
    }

    #[test]
    fn spawn_arguments_pin_cache_and_prefetch() {
        let args = MpvPlayer::mpv_args(std::path::Path::new("/run/user/1000/mpv.sock"));
        for expected in [
            "--cache=yes",
            "--demuxer-max-bytes=256MiB",
            "--demuxer-max-back-bytes=128MiB",
            "--demuxer-lavf-o=protocol_whitelist=[file,http,https,tcp,tls,crypto,data]",
            "--keep-open=always",
            "--prefetch-playlist=yes",
            "--audio-client-name=TIDAL Player",
            "--input-ipc-server=/run/user/1000/mpv.sock",
        ] {
            assert!(
                args.iter().any(|arg| arg == expected),
                "missing {expected} in {args:?}"
            );
        }
    }

    #[test]
    fn eof_is_ignored_when_it_is_stale_or_not_at_the_end() {
        // After a seek back, mpv can still report EOF from the old position.
        assert!(!eof_is_current(176.0, 252.0, 1_000, 0));
        // The guard covers the settling window even at the end.
        assert!(!eof_is_current(30.0, 311.0, 1_000, 1_200));
        assert!(eof_is_current(251.5, 252.0, 1_000, 0));
        assert!(eof_is_current(310.8, 311.0, 1_000, 999));
        // Unknown duration keeps the old behaviour.
        assert!(eof_is_current(10.0, 0.0, 1_000, 0));
    }

    #[test]
    fn only_targets_inside_mpv_cached_ranges_skip_the_reload() {
        // The ranges mpv reports after resuming a track at ~112s: the cached
        // tail of the track plus whatever was read before the initial seek.
        let cache = serde_json::json!({
            "eof": true,
            "seekable-ranges": [
                { "start": 109.909333, "end": 213.845333 },
                { "start": 0.0, "end": 3.754667 },
            ],
        });
        assert!(seek_is_cached(&cache, 120.0));
        assert!(seek_is_cached(&cache, 109.909333));
        assert!(seek_is_cached(&cache, 0.0));
        assert!(seek_is_cached(&cache, 3.7));
        assert!(!seek_is_cached(&cache, 50.0));
        assert!(!seek_is_cached(&cache, 3.9));
        assert!(!seek_is_cached(&cache, 109.0));

        let no_ranges = serde_json::json!({ "eof": true });
        assert!(!seek_is_cached(&no_ranges, 50.0));
    }

    #[test]
    fn seek_during_a_load_is_deferred_until_the_load_settles() {
        let player = player();
        player.shared.load_pending.store(true, Ordering::SeqCst);
        player.seek(42.0).unwrap();
        assert_eq!(*player.shared.pending_seek.read(), Some(42.0));
        assert_eq!(*player.shared.last_position.read(), 42.0);
        assert!(player.shared.saved_sleep_position.read().is_some());
        assert!(player.shared.eos_ignore_until_ms.load(Ordering::SeqCst) > 0);
        *player.shared.pending_seek.write() = None;
        player.shared.load_pending.store(false, Ordering::SeqCst);
    }

    #[test]
    fn a_cast_handoff_position_survives_the_stop_before_the_resumed_load() {
        let player = player();
        let track = test_track("7");

        // Disconnect parks the device's playhead for the local track.
        player.resume_local_at(&track, 94.5);

        // The playback loop stops the outgoing stream right before fetching and
        // loading the resumed track. That stop must not discard the hand-off.
        player
            .stop_internal()
            .expect("stopping a player with no child is a no-op");
        let handoff = player
            .take_resume_handoff(&track)
            .expect("the hand-off survived the stop");
        assert_eq!(handoff.position, 94.5);
        assert!(handoff.play, "a playing session hands back playing");
    }

    #[test]
    fn a_paused_session_hands_the_track_back_parked() {
        let player = player();
        let track = test_track("7");

        // Stopping the cast while the device was paused must not start the
        // song on this machine: the hand-off keeps the session's play intent.
        player.park_local_at(&track, 42.0);
        let handoff = player
            .take_resume_handoff(&track)
            .expect("the parked hand-off is still there");
        assert_eq!(handoff.position, 42.0);
        assert!(!handoff.play);
    }

    #[test]
    fn an_explicit_play_resumes_a_parked_handoff() {
        let player = player();
        let track = test_track("7");
        *player.shared.position_track.write() = Some(track.clone());
        player.park_local_at(&track, 42.0);

        // Play with no loaded stream cannot start anything, but the user's
        // intent is recorded before the load path runs.
        let _ = player.play();
        let handoff = player
            .take_resume_handoff(&track)
            .expect("the hand-off is still parked");
        assert_eq!(handoff.position, 42.0);
        assert!(handoff.play, "an explicit Play overrides the parked state");
    }

    #[test]
    fn a_handoff_position_is_consumed_once_and_only_for_its_own_track() {
        let player = player();
        let track = test_track("7");
        player.resume_local_at(&track, 42.0);

        // Consumed by the load it was parked for.
        assert_eq!(
            player.take_resume_handoff(&track).map(|handoff| handoff.position),
            Some(42.0)
        );
        assert!(player.take_resume_handoff(&track).is_none());

        // A hand-off for another track is stale: the user picked something
        // else while it was parked, so it must not seek that fresh track.
        player.resume_local_at(&track, 42.0);
        let other = test_track("8");
        assert!(player.take_resume_handoff(&other).is_none());
        assert!(player.take_resume_handoff(&track).is_none());
    }

    #[test]
    fn an_explicit_stop_ends_the_handoff() {
        let player = player();
        let track = test_track("7");
        player.resume_local_at(&track, 94.5);

        // A user Stop is a fresh start on the next Play, not a resume.
        player.stop().unwrap();
        assert!(player.take_resume_handoff(&track).is_none());
    }

    #[test]
    fn parsed_volume_survives_a_stop_and_is_reapplied_by_the_caller() {
        let player = player();
        // The cast session's local level is put back explicitly on disconnect;
        // this pins that storing it needs no live child process.
        player.set_volume(0.8);
        player.stop_internal().unwrap();
        assert!((player.get_volume() - 0.8).abs() < f64::EPSILON);
    }

    #[test]
    fn parses_tidal_stream_id_from_wpctl_output() {
        let sample = r#"
PipeWire 'pipewire-0' [1.6.8]
Audio
 ├─ Devices:
 ├─ Sinks:
 ├─ Sources:
 ├─ Filters:
 └─ Streams:
        57. TIDAL Player
             47. output_FR       > AudioOut:playback_FR	[active]
             80. output_FL       > AudioOut:playback_FL	[active]
"#;
        assert_eq!(parse_tidal_stream_id(sample), Some(57));

        let none_sample = r#"
Streams:
        12. Chromium
"#;
        assert_eq!(parse_tidal_stream_id(none_sample), None);
    }

    #[test]
    fn picks_the_newest_tidal_stream_after_a_restart() {
        let sample = r#"
Streams:
        57. TIDAL Player
            100. output_FR       > AudioOut:playback_FR	[active]
       132. TIDAL Player
            140. output_FL       > AudioOut:playback_FL	[active]
"#;
        assert_eq!(parse_tidal_stream_ids(sample), vec![57, 132]);
        assert_eq!(parse_tidal_stream_id(sample), Some(132));
    }

    #[test]
    fn seek_without_a_stream_parks_the_position() {
        let player = player();
        player.restore_parked_state(&test_track("a"), 42.0).unwrap();
        assert_eq!(player.get_position(), 42.0);
        assert!(player.has_saved_sleep_position());
        assert_eq!(player.get_state(), PlaybackState::Stopped);
        assert_eq!(
            player.persisted_state().position,
            42.0,
            "a parked playhead must survive persistence while stopped"
        );
        player.stop().unwrap();
        assert!(!player.has_saved_sleep_position());
        assert_eq!(player.persisted_state().position, 0.0);
    }

    #[test]
    fn user_pause_and_stop_bump_the_generation_but_internal_stop_does_not() {
        let player = player();
        let start = player.pause_generation();
        player.note_user_pause();
        assert_eq!(player.pause_generation(), start + 1);
        player.stop().unwrap();
        assert_eq!(player.pause_generation(), start + 2);
        let after_stop = player.pause_generation();
        player.stop_internal().unwrap();
        assert_eq!(player.pause_generation(), after_stop);
    }

    #[test]
    fn refresh_failure_drops_optimistic_playing_and_parks_the_playhead() {
        let player = player();
        *player.shared.position_track.write() = Some(test_track("a"));
        *player.shared.current_uri.write() = Some("file:///test.wav".into());
        *player.shared.last_position.write() = 33.0;
        *player.shared.state.write() = PlaybackState::Playing;
        player.refresh_failed();
        assert_eq!(player.get_state(), PlaybackState::Stopped);
        assert_eq!(player.get_position(), 33.0);
        assert!(player.stream_is_stale());
    }

    #[test]
    fn persisted_player_state_round_trips_through_json() {
        let state = PersistedPlayerState {
            track: Some(test_track("a")),
            position: 12.5,
            volume: 0.6,
            shuffle: true,
            repeat_mode: "all".into(),
        };
        let json = serde_json::to_vec(&state).unwrap();
        let restored: PersistedPlayerState = serde_json::from_slice(&json).unwrap();
        assert_eq!(restored, state);
    }

    #[test]
    fn volume_is_persisted_without_a_stream() {
        let player = player();
        player.set_volume(0.42);
        assert!((player.get_volume() - 0.42).abs() < f64::EPSILON);
        let state = player.persisted_state();
        assert!((state.volume - 0.42).abs() < f64::EPSILON);
        assert_eq!(state.track, None);
    }

    #[test]
    fn a_playing_stream_loads_survives_a_seek_and_resumes_after_pause() {
        let _audio = audio_test_lock();
        if !mpv_available() {
            return;
        }
        let player = player();
        let uri = playing_wav_uri(10);
        player
            .play_uri(&test_track("seek_track"), &uri, FormatInfo::default())
            .unwrap();
        assert!(
            wait_for(
                || player.get_state() == PlaybackState::Playing,
                Duration::from_secs(4)
            ),
            "mpv did not start playing: {:?}",
            player.get_state()
        );

        player.seek(5.0).unwrap();
        assert!(
            wait_for(
                || (player.get_position() - 5.0).abs() < 1.0,
                Duration::from_secs(3)
            ),
            "seek did not land at 5s (position {:.2})",
            player.get_position()
        );

        player.pause().unwrap();
        assert!(
            wait_for(
                || player.get_state() == PlaybackState::Paused,
                Duration::from_secs(3)
            ),
            "mpv did not pause: {:?}",
            player.get_state()
        );

        player.seek(7.0).unwrap();
        player.play().unwrap();
        assert!(
            wait_for(
                || player.get_state() == PlaybackState::Playing,
                Duration::from_secs(3)
            ),
            "mpv did not resume: {:?}",
            player.get_state()
        );
        assert!(
            wait_for(|| player.get_position() >= 6.5, Duration::from_secs(3)),
            "resume did not continue near the paused seek (position {:.2})",
            player.get_position()
        );
        player.stop().unwrap();
    }

    #[test]
    fn a_parked_handoff_loads_paused_at_the_cast_playhead() {
        let _audio = audio_test_lock();
        if !mpv_available() {
            return;
        }
        let player = player();
        let track = test_track("parked_handoff");
        // A cast session that was paused when the user stopped casting parks
        // its playhead for the local load instead of resuming.
        player.park_local_at(&track, 3.0);
        player
            .play_uri(&track, &playing_wav_uri(10), FormatInfo::default())
            .unwrap();
        assert_eq!(
            player.get_state(),
            PlaybackState::Paused,
            "a parked hand-off must load paused, not playing"
        );
        std::thread::sleep(Duration::from_millis(1200));
        assert_eq!(
            player.get_state(),
            PlaybackState::Paused,
            "the parked load started playing on its own"
        );
        assert!(
            (player.get_position() - 3.0).abs() < 1.0,
            "the parked load did not keep the cast playhead (position {:.2})",
            player.get_position()
        );

        // The user pressing Play afterwards resumes from that point.
        player.play().unwrap();
        assert!(
            wait_for(
                || player.get_state() == PlaybackState::Playing,
                Duration::from_secs(3)
            ),
            "an explicit Play did not resume the parked track: {:?}",
            player.get_state()
        );
        player.stop().unwrap();
    }

    #[test]
    fn seeking_outside_the_demuxer_cache_reloads_the_dash_stream() {
        let _audio = audio_test_lock();
        if !mpv_available() || !ffmpeg_available() {
            return;
        }
        let dir = std::env::temp_dir().join(format!(
            "omarchy-tidalplayer-dash-seek-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let generated = Command::new("ffmpeg")
            .args([
                "-hide_banner",
                "-loglevel",
                "error",
                "-f",
                "lavfi",
                "-i",
                "anullsrc=r=48000:cl=stereo",
                "-t",
                "60",
                "-c:a",
                "flac",
                "-f",
                "dash",
                "-seg_duration",
                "4",
                "-use_timeline",
                "1",
                "-use_template",
                "1",
                "-init_seg_name",
                "init-$RepresentationID$.m4s",
                "-media_seg_name",
                "chunk-$RepresentationID$-$Number%05d$.m4s",
            ])
            .arg(dir.join("out.mpd"))
            .status()
            .unwrap();
        assert!(
            generated.success(),
            "ffmpeg could not generate the DASH fixture"
        );

        let (port, stop, server) = serve_slow_dash(dir.clone(), Duration::from_millis(400));
        let player = player();
        let uri = format!("http://127.0.0.1:{port}/out.mpd");
        player
            .play_uri(&test_track("dash"), &uri, FormatInfo::default())
            .unwrap();
        assert!(
            wait_for(|| player.get_position() > 0.3, Duration::from_secs(8)),
            "the slow DASH stream did not start (state {:?})",
            player.get_state()
        );

        player.seek(50.0).unwrap();
        assert!(
            wait_for(|| player.get_position() > 49.0, Duration::from_secs(8)),
            "the forward seek did not land (position {:.2})",
            player.get_position()
        );
        // The demuxer reads the 50-60s tail to EOF and closes the DASH
        // representation. A seek to 30s is outside every cached range, so a
        // direct seek would report EOF instead of playing.
        assert!(
            wait_for(
                || {
                    let mut guard = player.ipc.lock();
                    guard
                        .as_mut()
                        .is_some_and(|client| client.seek_needs_reload(30.0))
                },
                Duration::from_secs(8)
            ),
            "mpv did not cache the tail and reach EOF before the backward seek"
        );

        player.seek(30.0).unwrap();
        assert!(
            wait_for(|| player.get_position() > 30.3, Duration::from_secs(8)),
            "playback did not continue after the backward seek (position {:.2}, state {:?})",
            player.get_position(),
            player.get_state()
        );

        player.stop().unwrap();
        stop.store(true, Ordering::SeqCst);
        server.join().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn resuming_a_slow_dash_stream_lands_on_the_target() {
        let _audio = audio_test_lock();
        if !mpv_available() || !ffmpeg_available() {
            return;
        }
        let dir = std::env::temp_dir().join(format!(
            "omarchy-tidalplayer-dash-resume-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let generated = Command::new("ffmpeg")
            .args([
                "-hide_banner",
                "-loglevel",
                "error",
                "-f",
                "lavfi",
                "-i",
                "anullsrc=r=48000:cl=stereo",
                "-t",
                "60",
                "-c:a",
                "flac",
                "-f",
                "dash",
                "-seg_duration",
                "4",
                "-use_timeline",
                "1",
                "-use_template",
                "1",
                "-init_seg_name",
                "init-$RepresentationID$.m4s",
                "-media_seg_name",
                "chunk-$RepresentationID$-$Number%05d$.m4s",
            ])
            .arg(dir.join("out.mpd"))
            .status()
            .unwrap();
        assert!(
            generated.success(),
            "ffmpeg could not generate the DASH fixture"
        );

        // Slow enough that mpv is still opening the stream when LOAD_SETTLE
        // expires, which is what makes a post-load seek fail.
        let (port, stop, server) = serve_slow_dash(dir.clone(), Duration::from_millis(2500));
        let player = player();
        let uri = format!("http://127.0.0.1:{port}/out.mpd");
        player
            .prepare_uri(&test_track("dash-resume"), &uri, FormatInfo::default(), 8.0)
            .unwrap();
        assert!(
            wait_for(
                || player.get_duration() > 50.0,
                Duration::from_secs(25)
            ),
            "the resume load never reported a duration (state {:?})",
            player.get_state()
        );
        assert!(
            (player.get_position() - 8.0).abs() < 1.0,
            "the resumed stream did not open at the target (position {:.2})",
            player.get_position()
        );

        player.stop().unwrap();
        stop.store(true, Ordering::SeqCst);
        server.join().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_preloaded_track_is_promoted_at_the_end_of_the_current_one() {
        let _audio = audio_test_lock();
        if !mpv_available() {
            return;
        }
        let player = player();
        let first = test_track("first");
        let second = test_track("second");
        player
            .play_uri(&first, &playing_wav_uri(2), FormatInfo::default())
            .unwrap();
        assert!(
            wait_for(
                || player.get_state() == PlaybackState::Playing,
                Duration::from_secs(4)
            ),
            "mpv did not start playing"
        );
        player
            .append_next(&first, &second, &playing_wav_uri(3), FormatInfo::default())
            .unwrap();
        assert!(player.preloaded_matches(&second));
        assert!(
            wait_for(
                || player.get_state() == PlaybackState::Stopped,
                Duration::from_secs(6)
            ),
            "mpv did not reach EOF"
        );

        let promoted = player.play_preloaded().unwrap();
        assert_eq!(
            promoted.as_ref().map(|track| track.id.as_str()),
            Some("second")
        );
        assert!(
            wait_for(
                || player.get_state() == PlaybackState::Playing,
                Duration::from_secs(3)
            ),
            "the preloaded track did not start"
        );
        assert!(
            wait_for(|| player.get_position() > 0.3, Duration::from_secs(3)),
            "the preloaded track did not advance"
        );
        player.stop().unwrap();
    }

    #[test]
    fn rearming_the_preload_replaces_the_appended_entry() {
        let _audio = audio_test_lock();
        if !mpv_available() {
            return;
        }
        let player = player();
        let first = test_track("first");
        let second = test_track("second");
        let third = test_track("third");
        player
            .play_uri(&first, &playing_wav_uri(2), FormatInfo::default())
            .unwrap();
        assert!(
            wait_for(
                || player.get_state() == PlaybackState::Playing,
                Duration::from_secs(4)
            ),
            "mpv did not start playing"
        );
        player
            .append_next(&first, &second, &playing_wav_uri(3), FormatInfo::default())
            .unwrap();
        player
            .append_next(&first, &third, &playing_wav_uri(4), FormatInfo::default())
            .unwrap();
        assert!(
            !player.preloaded_matches(&second),
            "the superseded preload was kept"
        );
        assert!(player.preloaded_matches(&third));
        // The superseded entry was removed, so the promotion switches straight
        // to the current preload instead of the stale one.
        let promoted = player.play_preloaded().unwrap();
        assert_eq!(
            promoted.as_ref().map(|track| track.id.as_str()),
            Some("third")
        );
        player.stop().unwrap();
    }

    #[test]
    fn a_promotion_is_refused_when_the_preloaded_entry_is_not_next() {
        let _audio = audio_test_lock();
        if !mpv_available() {
            return;
        }
        let player = player();
        let first = test_track("first");
        let second = test_track("second");
        player
            .play_uri(&first, &playing_wav_uri(2), FormatInfo::default())
            .unwrap();
        assert!(
            wait_for(
                || player.get_state() == PlaybackState::Playing,
                Duration::from_secs(4)
            ),
            "mpv did not start playing"
        );
        // A stray entry between the current track and the appended preload.
        player
            .with_client(|client| client.appendfile(&playing_wav_uri(5)))
            .unwrap();
        player
            .append_next(&first, &second, &playing_wav_uri(3), FormatInfo::default())
            .unwrap();
        assert!(player.preloaded_matches(&second));
        assert!(
            player.play_preloaded().unwrap().is_none(),
            "a promotion must refuse instead of switching to the wrong entry"
        );
        player.stop().unwrap();
    }

    #[test]
    fn loading_a_stream_records_which_track_owns_the_playhead() {
        let _audio = audio_test_lock();
        if !mpv_available() {
            return;
        }
        let player = player();
        let uri = playing_wav_uri(2);
        let track = test_track("owner");
        player
            .play_uri(&track, &uri, FormatInfo::default())
            .unwrap();
        assert_eq!(
            player
                .shared
                .position_track
                .read()
                .as_ref()
                .map(|t| t.id.clone()),
            Some("owner".to_string())
        );
        player.stop().unwrap();
    }
}
