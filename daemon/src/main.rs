mod api;
mod auth;
mod cast;
mod catalogue;
mod cli;
mod mpris;
mod mpv;
mod queue;
mod rpc;
mod sleep;

use api::{AppState, PlaybackError};
use auth::AuthManager;
use catalogue::{CatalogueManager, RecentItem};
use mpv::{
    pipeline_operation_wedged, run_pipeline_op, run_stream_op, same_queue_entry, MpvPlayer,
    PersistedPlayerState, PlaybackState, STREAM_LOAD_TIMEOUT, TRANSPORT_OP_TIMEOUT,
};
use queue::{QueueManager, QueueSnapshot, QueuedPlay, TrackItem};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::{mpsc, RwLock};
use tracing::{error, info, warn};

/// Stream fetches are retried with a fixed delay, mirroring the wake-time
/// refresh. TIDAL answers 429 while a burst of playback requests is being
/// cooled down; a handful of retries lets a click recover once that clears.
/// An unreachable audio server is *not* retried: waiting four seconds cannot
/// bring PipeWire back, and the user is left staring at nothing.
const STREAM_FETCH_ATTEMPTS: u32 = 6;
const STREAM_FETCH_RETRY_DELAY: Duration = Duration::from_secs(4);

pub(crate) fn stream_fetch_error_is_retryable(error: &str) -> bool {
    error.contains("HTTP error 429")
        || error.contains("HTTP error 5")
        || error.starts_with("Request failed:")
        || error.starts_with("Retry failed:")
}

/// The message recorded when the audio server itself is the problem. It is a
/// distinct string so the playback loop can recognise it and fail immediately
/// instead of retrying.
pub(crate) const AUDIO_SERVER_NOT_READY: &str =
    "audio server did not become ready; the audio output is not responding";

/// The message recorded when mpv claims to be playing but its audio clock has
/// stopped moving. Nothing is consuming the stream: no sink, a node the session
/// manager never linked, or a wedged device. Distinct from the stream errors so
/// the user is pointed at the audio output rather than at TIDAL.
pub(crate) const AUDIO_STALLED: &str =
    "the audio output stopped: nothing is receiving the stream (check the sound device)";

/// Sleeps for `delay`, returning false as soon as the request is cancelled —
/// either another track became current or the user paused.
pub(crate) async fn wait_while_current(
    player: &MpvPlayer,
    queue: &QueueManager,
    track: &TrackItem,
    pause_generation: u64,
    delay: Duration,
) -> bool {
    let deadline = tokio::time::Instant::now() + delay;
    loop {
        let now = tokio::time::Instant::now();
        if now >= deadline {
            return player.pause_generation() == pause_generation
                && queue.get_current_track().await.as_ref() == Some(track);
        }
        tokio::time::sleep((deadline - now).min(Duration::from_millis(250))).await;
        if player.pause_generation() != pause_generation
            || queue.get_current_track().await.as_ref() != Some(track)
        {
            return false;
        }
    }
}

/// Stops the previous track when the current one's stream could not be
/// fetched. The queue (and MPRIS metadata) already points at the new track;
/// leaving the old pipeline running makes the UI report that track as playing
/// while the previous song's audio continues. Marks the old URI stale so the
/// next Play fetches a fresh stream instead of replaying it. Returns false
/// when another track became current first.
async fn stop_failed_playback(
    player: &Arc<MpvPlayer>,
    queue: &Arc<QueueManager>,
    playback_command_lock: &Arc<tokio::sync::Mutex<()>>,
    track: &TrackItem,
    pause_generation: u64,
) -> bool {
    let _guard = playback_command_lock.lock().await;
    if queue.get_current_track().await.as_ref() != Some(track)
        || player.pause_generation() != pause_generation
    {
        return false;
    }
    if let Err(e) = run_pipeline_op(player, TRANSPORT_OP_TIMEOUT, |p| p.stop_internal()).await {
        error!("Failed to stop stale playback after a stream fetch failure: {e}");
    }
    player.refresh_failed();
    true
}

fn playback_failure_message(track: &TrackItem, error: &str) -> String {
    let reason = if error.contains("HTTP error 429") {
        "TIDAL is rate limiting playback. Try again in a moment."
    } else if error.contains("HTTP error 5") {
        "TIDAL returned an error. Try again in a moment."
    } else if error.starts_with("Request failed:") || error.starts_with("Retry failed:") {
        "TIDAL could not be reached. Check your connection."
    } else if error.contains(AUDIO_SERVER_NOT_READY) {
        "The audio server is not responding, so playback was not attempted. Restart PipeWire to recover."
    } else if error.contains(AUDIO_STALLED) {
        "The sound device stopped receiving audio. Check your audio output, then press Play."
    } else if error.contains("Could not start mpv") {
        "The mpv player is not installed or could not start. Install it with `omarchy pkg add mpv`."
    } else if error.contains("HTTP error 404") {
        "TIDAL could not find this track."
    } else if is_track_unavailable_error(error) {
        "This track is not available for streaming."
    } else if error.contains("No stream URL") {
        "TIDAL did not provide a stream for this track."
    } else if error.contains("Not logged in") {
        "Your TIDAL session has expired. Please log in again."
    } else if pipeline_operation_wedged(error) || error.contains("audio pipeline was replaced") {
        "The audio output stalled. Try again, or restart PipeWire if it persists."
    } else if error.contains("Audio pipeline is busy") || error.contains("mpv process is busy") {
        "The audio pipeline is busy. Try again."
    } else if lost_cast_connection(error) {
        "The connection to the cast device was lost."
    } else {
        "The stream could not be loaded."
    };
    format!("Couldn't play “{}”: {reason}", track.title)
}

/// Whether TIDAL rejected playback because the track is unavailable in the
/// user's region or not streamable (as opposed to an expired session or
/// transient failure).
fn is_track_unavailable_error(error: &str) -> bool {
    error.contains("Asset is not ready for playback")
        || error.contains("\"subStatus\":4005")
        || error.contains("\"subStatus\": 4005")
        || error.contains("No content matching subscription location")
        || error.contains("\"subStatus\":4032")
        || error.contains("\"subStatus\": 4032")
}

/// Whether a failure was a lost cast connection (device sleep, a suspend, a
/// Wi-Fi drop, a power pull). Attempt failures with these errors are logged
/// but never surfaced: the session's recovery is what announces the loss, once,
/// so the user is not toasted twice for one incident.
fn lost_cast_connection(error: &str) -> bool {
    error.contains("cast device connection is closed")
        || error.contains("cast device closed the connection")
        || error.contains("cast device did not answer")
}

async fn record_playback_error(
    playback_error: &Arc<RwLock<Option<PlaybackError>>>,
    track: &TrackItem,
    error: &str,
) {
    let message = playback_failure_message(track, error);
    warn!("Playback failed: {message}");
    if !lost_cast_connection(error) {
        store_playback_error(playback_error, message).await;
    }
}

/// Records an already-worded failure. The message is shown to the user as-is.
async fn record_playback_message(
    playback_error: &Arc<RwLock<Option<PlaybackError>>>,
    message: String,
) {
    warn!("{message}");
    store_playback_error(playback_error, message).await;
}

/// Stores the error the UI shows. The message is deduplicated: one incident
/// can reach this from both a failed attempt and the recovery that follows
/// it, and a second identical toast adds nothing. A new play attempt clears
/// the slot first, so a repeated failure after a retry still notifies.
async fn store_playback_error(
    playback_error: &Arc<RwLock<Option<PlaybackError>>>,
    message: String,
) {
    let mut guard = playback_error.write().await;
    if guard.as_ref().map(|existing| existing.message.as_str()) == Some(message.as_str()) {
        return;
    }
    let now_id = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or(1);
    let id = match guard.as_ref() {
        Some(prev) => now_id.max(prev.id.saturating_add(1)),
        None => now_id,
    };
    *guard = Some(PlaybackError { id, message });
}

/// Warms the next queue track into mpv's playlist while the current track has
/// started. `--prefetch-playlist` buffers it while the current one plays, so
/// advancing at EOS or on a skip needs no TIDAL or CDN round trip. The fetch
/// starts right away: a skip that lands before it completes takes the ordinary
/// fetch-and-replace path, which is exactly what would have happened without
/// the preload, so a skip storm only costs the metadata fetches it discards.
pub(crate) fn spawn_preload(
    player: Arc<MpvPlayer>,
    queue: Arc<QueueManager>,
    catalogue: Arc<CatalogueManager>,
    current: TrackItem,
) {
    tokio::spawn(async move {
        let still_current = |track: Option<&TrackItem>| {
            track.is_some_and(|track| same_queue_entry(track, &current))
        };
        if !still_current(queue.get_current_track().await.as_ref()) {
            return;
        }
        let Some(next) = queue.peek_next_track().await else {
            return;
        };
        if next.tlid == current.tlid && next.id == current.id {
            // Repeat-song: the "next" entry is the track already loaded.
            return;
        }
        let (url, format) = match catalogue.get_stream_url(&next.id).await {
            Ok(stream) => stream,
            Err(e) => {
                warn!("Could not fetch the next track for preloading: {e}");
                return;
            }
        };
        // The user may have skipped while the metadata was in flight.
        if !still_current(queue.get_current_track().await.as_ref()) {
            return;
        }
        info!("Preloading next track: {} - {}", next.title, next.artist);
        let preload_current = current.clone();
        if let Err(e) = run_pipeline_op(&player, TRANSPORT_OP_TIMEOUT, move |p| {
            p.append_next(&preload_current, &next, &url, format)
        })
        .await
        {
            warn!("Could not preload the next track: {e}");
        }
    });
}

fn queue_state_path() -> std::path::PathBuf {
    AuthManager::state_dir().join("queue.json")
}

fn load_queue_snapshot(path: &Path) -> Option<QueueSnapshot> {
    let content = std::fs::read_to_string(path).ok()?;
    match serde_json::from_str::<QueueSnapshot>(&content) {
        Ok(snapshot) if !snapshot.tracks.is_empty() => Some(snapshot),
        Ok(_) => None,
        Err(e) => {
            warn!("Ignoring unreadable play queue at {}: {e}", path.display());
            None
        }
    }
}

fn playback_path() -> std::path::PathBuf {
    AuthManager::state_dir().join("playback.json")
}

/// Renames the files written by older builds before anything reads them. The
/// daemon is the only writer, so a plain rename is enough; an existing new file
/// wins and the stale legacy copy is removed.
fn migrate_legacy_files(dir: &Path) {
    // Playback-info caching is gone; drop the files older builds wrote.
    for stale in ["stream_cache.json", "playback_cache.json"] {
        let path = dir.join(stale);
        if path.exists() {
            if let Err(e) = std::fs::remove_file(&path) {
                warn!("Could not remove stale {}: {e}", path.display());
            }
        }
    }
    for (legacy, current) in [
        ("player_state.json", "playback.json"),
        ("resume_after_restart.json", "restart_resume.json"),
        ("client_restart.json", "restart_cooldown.json"),
    ] {
        let legacy_path = dir.join(legacy);
        if !legacy_path.exists() {
            continue;
        }
        let current_path = dir.join(current);
        if current_path.exists() {
            if let Err(e) = std::fs::remove_file(&legacy_path) {
                warn!("Could not remove stale {}: {e}", legacy_path.display());
            }
            continue;
        }
        match std::fs::rename(&legacy_path, &current_path) {
            Ok(()) => info!(
                "Renamed {} to {}",
                legacy_path.display(),
                current_path.display()
            ),
            Err(e) => warn!(
                "Could not rename {} to {}: {e}",
                legacy_path.display(),
                current_path.display()
            ),
        }
    }
}

/// Moves the state written by the pre-rename builds. The daemon is the only
/// writer, so a plain rename is enough; an existing new directory wins.
fn migrate_legacy_state_dir(base: &Path) {
    let legacy = base.join("omarchy-tidal");
    let current = base.join("scorchedegg.tidalplayer");
    if !legacy.is_dir() || current.exists() {
        return;
    }
    match std::fs::rename(&legacy, &current) {
        Ok(()) => info!(
            "Moved legacy state from {} to {}",
            legacy.display(),
            current.display()
        ),
        Err(e) => warn!(
            "Could not move legacy state from {} to {}: {e}",
            legacy.display(),
            current.display()
        ),
    }
}

fn load_player_state(path: &Path) -> Option<PersistedPlayerState> {
    let content = std::fs::read_to_string(path).ok()?;
    match serde_json::from_str::<PersistedPlayerState>(&content) {
        Ok(state) => Some(state),
        Err(e) => {
            warn!(
                "Ignoring unreadable player state at {}: {e}",
                path.display()
            );
            None
        }
    }
}

/// Writes the playhead/volume snapshot through a temporary file, like the
/// queue, so a crash mid-write cannot truncate the next boot's state.
async fn persist_player_state(path: &Path, state: &PersistedPlayerState) {
    let json = match serde_json::to_vec(state) {
        Ok(json) => json,
        Err(e) => {
            warn!("Could not serialize the player state: {e}");
            return;
        }
    };
    let tmp = path.with_extension("json.tmp");
    if let Err(e) = tokio::fs::write(&tmp, json).await {
        warn!("Could not write the player state: {e}");
        return;
    }
    if let Err(e) = tokio::fs::rename(&tmp, path).await {
        warn!("Could not replace the player state file: {e}");
    }
}

/// The full playback snapshot: the player's playhead when it has one, the
/// queue's selected track when the player is stopped, and the session's
/// shuffle/repeat settings. `playback.json` is the source of truth for all of
/// it; `queue.json` only stores the static list.
async fn current_player_state_with_cast(
    player: &MpvPlayer,
    queue: &QueueManager,
    cast: Option<&cast::CastManager>,
) -> PersistedPlayerState {
    let mut state = player.persisted_state();
    if let Some(cast_snap) = cast.and_then(|c| c.snapshot()) {
        state.position = cast_snap.position.max(0.0);
        state.volume = cast_snap.volume;
    }
    if state.track.is_none() {
        state.track = queue.get_current_track().await;
    }
    let (shuffle, repeat_mode) = queue.playback_settings().await;
    state.shuffle = shuffle;
    state.repeat_mode = repeat_mode;
    state
}

#[cfg(test)]
async fn current_player_state(player: &MpvPlayer, queue: &QueueManager) -> PersistedPlayerState {
    current_player_state_with_cast(player, queue, None).await
}

/// Writes the queue through a temporary file so a crash mid-write cannot
/// truncate the snapshot being used on the next boot.
async fn persist_queue_state(path: &Path, state: &QueueSnapshot) {
    let json = match serde_json::to_vec(state) {
        Ok(json) => json,
        Err(e) => {
            warn!("Could not serialize the play queue: {e}");
            return;
        }
    };
    let tmp = path.with_extension("json.tmp");
    if let Err(e) = tokio::fs::write(&tmp, json).await {
        warn!("Could not write the play queue: {e}");
        return;
    }
    if let Err(e) = tokio::fs::rename(&tmp, path).await {
        warn!("Could not replace the play queue file: {e}");
    }
}

fn cli_exit(result: Result<(), Box<dyn std::error::Error>>) -> Result<(), Box<dyn std::error::Error>> {
    match result {
        Ok(()) => Ok(()),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // One binary, one name: `daemon` runs the daemon (the systemd unit's
    // ExecStart), everything else is the CLI. No args keeps the old CLI
    // default of `status`.
    let mut args = std::env::args();
    let _ = args.next();
    let command = args.next();
    let rest: Vec<String> = args.collect();
    match command.as_deref() {
        Some("daemon") => match rest.first() {
            None => {}
            Some(action) => return cli_exit(cli::daemon_action(action)),
        },
        Some(command) => return cli_exit(cli::run(command, &rest)),
        None => return cli_exit(cli::run("status", &[])),
    }
    // The state directory moved with the rename; move it before anything
    // creates the new one.
    migrate_legacy_state_dir(&AuthManager::state_base());
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    let result = runtime.block_on(run());
    // A stuck IPC read must not keep the process alive and turn a daemon
    // restart into a systemd stop timeout.
    runtime.shutdown_timeout(Duration::from_secs(3));
    result
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize tracing
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "omarchy_tidalplayer=info,info".into()),
        )
        .init();

    info!("Starting omarchy-tidalplayer daemon...");
    migrate_legacy_files(&AuthManager::state_dir());

    // Channels for coordination
    let (eos_tx, mut eos_rx) = mpsc::unbounded_channel::<()>();
    let (play_tx, mut play_rx) = mpsc::unbounded_channel::<QueuedPlay>();
    let (refresh_tx, mut refresh_rx) = mpsc::unbounded_channel::<()>();
    // The player's poller fires this when mpv reports playback but nothing is
    // consuming the audio (no sink, an unlinked node, a wedged device).
    let (stall_tx, mut stall_rx) = mpsc::unbounded_channel::<()>();
    // End-of-track and connection-loss from a cast receiver: the device, not
    // mpv, owns the stream while a session is active.
    let (cast_event_tx, mut cast_event_rx) = mpsc::unbounded_channel::<cast::CastEvent>();
    // Every successful stream load and preloaded promotion announces the track
    // that started, so the loop can arm the next-track preload uniformly.
    let (stream_started_tx, mut stream_started_rx) = mpsc::unbounded_channel::<TrackItem>();

    // Core managers
    let auth = Arc::new(AuthManager::new());
    let player = Arc::new(MpvPlayer::new(
        eos_tx,
        refresh_tx,
        stall_tx,
        stream_started_tx,
    )?);
    let queue = Arc::new(QueueManager::new());
    let now_playing = Arc::new(RwLock::new(None::<TrackItem>));
    let playback_error = Arc::new(RwLock::new(None::<PlaybackError>));
    let catalogue = Arc::new(CatalogueManager::new(auth.clone()));
    let playback_command_lock = Arc::new(tokio::sync::Mutex::new(()));

    // Casting owns a LAN listener and one session at a time. It starts before
    // MPRIS because MPRIS dispatches transport calls through it.
    let cast = cast::CastManager::start(
        player.clone(),
        queue.clone(),
        catalogue.clone(),
        play_tx.clone(),
        cast_event_tx,
        playback_error.clone(),
    )
    .await;
    cast.startup_sweep();

    // Start background volume synchronization and sleep/wake monitor
    player.start_volume_sync();
    sleep::start_sleep_monitor(
        player.clone(),
        queue.clone(),
        catalogue.clone(),
        playback_command_lock.clone(),
        playback_error.clone(),
        cast.clone(),
    );

    // Restore the static queue and the playback state the previous process (or
    // the last boot) left behind. `playback.json` names the selected track,
    // so the queue only contributes the list; the selection comes back parked
    // with its playhead, and nothing starts on its own. A Play fetches a fresh
    // stream URL because the persisted one died with the old process.
    let queue_path = queue_state_path();
    let playback_file = playback_path();
    let saved_player_state = load_player_state(&playback_file);
    if let Some(saved) = &saved_player_state {
        player.set_volume(saved.volume);
    }
    let snapshot = load_queue_snapshot(&queue_path);
    let (shuffle, repeat_mode) = saved_player_state
        .as_ref()
        .map(|state| (state.shuffle, state.repeat_mode.as_str()))
        .unwrap_or((false, "off"));
    queue
        .restore(snapshot.clone().unwrap_or_default(), shuffle, repeat_mode)
        .await;
    if let Some(snapshot) = snapshot {
        info!(
            "Restored {} queued tracks from {}",
            snapshot.tracks.len(),
            queue_path.display()
        );
    }

    // The player state is authoritative for the selection. If the queue no
    // longer contains that track (only possible if the queue was replaced
    // while the player state still named the old one), the queue is rebuilt
    // around it.
    let mut restored_current = None;
    if let Some(saved) = &saved_player_state {
        restored_current = queue.restore_selection(saved.track.as_ref()).await;
    }
    if restored_current.is_none() {
        restored_current = queue.get_current_track().await;
    }
    if let Some(track) = restored_current {
        player.mark_stream_stale();
        if let Some(saved) = saved_player_state.as_ref().filter(|saved| {
            saved
                .track
                .as_ref()
                .is_some_and(|saved_track| saved_track.id == track.id)
                && saved.position > 0.0
        }) {
            if let Err(e) = player.restore_parked_state(&track, saved.position) {
                warn!("Could not restore the saved playback position: {e}");
            } else {
                info!(
                    "Restored the playhead for “{}” at {:.2}s",
                    track.title, saved.position
                );
            }
        }
        *now_playing.write().await = Some(track);
    }

    // `queue.json` is the static list: it is written only when the list or its
    // order changes, never when the selection moves. An in-place client
    // restart (which starts the new image immediately) therefore loses at most
    // the last second of queue changes.
    let persist_queue = queue.clone();
    let persist_path = queue_path.clone();
    let queue_persist_task = tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(1));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            ticker.tick().await;
            if persist_queue.take_dirty() {
                let snapshot = persist_queue.snapshot().await;
                persist_queue_state(&persist_path, &snapshot).await;
            }
        }
    });

    // The playhead, selection, volume and session settings live in their own
    // file: the queue is large and static, while the playhead moves
    // continuously. While playing this writes every two seconds (a crash loses
    // at most that much); pause, seek, stop, volume, track, repeat and shuffle
    // changes mark the state dirty so they land on the next tick.
    let persist_player = player.clone();
    let persist_state_queue = queue.clone();
    let persist_cast = cast.clone();
    let persist_playback_path = playback_file.clone();
    let playback_persist_task = tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(2));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut last_written: Option<PersistedPlayerState> = None;
        loop {
            ticker.tick().await;
            let cast_playing = persist_cast
                .snapshot()
                .is_some_and(|snap| snap.state == PlaybackState::Playing);
            let playing = cast_playing || persist_player.get_state() == PlaybackState::Playing;
            let player_dirty = persist_player.take_persist_dirty();
            let settings_dirty = persist_state_queue.take_settings_dirty();
            if !playing && !player_dirty && !settings_dirty {
                continue;
            }
            let state = current_player_state_with_cast(
                &persist_player,
                &persist_state_queue,
                Some(&persist_cast),
            )
            .await;
            if last_written.as_ref() == Some(&state) {
                continue;
            }
            persist_player_state(&persist_playback_path, &state).await;
            last_written = Some(state);
        }
    });

    let recent_contexts_path = AuthManager::state_dir().join("recent_contexts.json");
    let mut recent_contexts = std::fs::read_to_string(&recent_contexts_path)
        .ok()
        .and_then(|content| serde_json::from_str::<Vec<RecentItem>>(&content).ok())
        .unwrap_or_default();
    for item in &mut recent_contexts {
        if item.title == "Favorite Tracks" {
            item.title = "Tracks".to_string();
        }
        if item.id == "favorites" || item.item_type == "favorites" {
            item.art_url = None;
        }
    }

    // Load recent searches
    let searches_path = AuthManager::state_dir().join("recent_searches.json");
    let mut initial_searches = Vec::new();
    if searches_path.exists() {
        if let Ok(content) = std::fs::read_to_string(&searches_path) {
            if let Ok(list) = serde_json::from_str::<Vec<String>>(&content) {
                initial_searches = list;
            }
        }
    }
    let recent_searches = Arc::new(RwLock::new(initial_searches));

    // Start MPRIS Server
    let _mpris_conn = match mpris::start_mpris_server(
        Arc::new(cast::CastAwarePlayback::new(player.clone(), cast.clone())),
        queue.clone(),
        now_playing.clone(),
        play_tx.clone(),
        playback_command_lock.clone(),
    )
    .await
    {
        Ok(conn) => Some(conn),
        Err(e) => {
            warn!("Could not start MPRIS D-Bus server: {e}");
            None
        }
    };

    // Playback loop handler
    let player_loop = player.clone();
    let queue_loop = queue.clone();
    let catalogue_loop = catalogue.clone();
    let play_tx_loop = play_tx.clone();
    let now_playing_loop = now_playing.clone();
    let playback_error_loop = playback_error.clone();
    let playback_command_lock_loop = playback_command_lock.clone();
    let cast_loop = cast.clone();

    tokio::spawn(async move {
        loop {
            tokio::select! {
                Some(mut request) = play_rx.recv() => {
                    // Collapse a burst of skips: only the newest queued request
                    // can still be current, and loading the ones in between
                    // only delays the track the user is waiting for.
                    while let Ok(newer) = play_rx.try_recv() {
                        request = newer;
                    }
                    let track = request.track;
                    let pause_generation = request.pause_generation;
                    info!("Received play command for track: {} - {}", track.title, track.artist);
                    // Play requests can be superseded while they wait in the
                    // channel. Drop them before spending a TIDAL API call.
                    if queue_loop.get_current_track().await.as_ref() != Some(&track) {
                        info!("Skipping stale playback request for {}", track.title);
                        continue;
                    }
                    if player_loop.pause_generation() != pause_generation {
                        player_loop.mark_stream_stale();
                        info!("Playback request for {} was paused before it started", track.title);
                        continue;
                    }
                    // A new attempt supersedes any error the user has seen —
                    // but a cast hand-off is not an attempt; the notice that
                    // came with it is still current.
                    if !request.handoff {
                        *playback_error_loop.write().await = None;
                    }

                    // While casting, the device fetches TIDAL's segments itself
                    // via CastManager::play_track; avoid fetching the local
                    // stream URL twice or holding playback_command_lock across
                    // network I/O.
                    if cast_loop.is_active() {
                        let play_track = track.clone();
                        match cast_loop.play_track(&play_track).await {
                            Ok(()) => {
                                if !request.handoff {
                                    *playback_error_loop.write().await = None;
                                }
                                *now_playing_loop.write().await = Some(play_track);
                            }
                            Err(e) => {
                                error!("Could not cast {}: {e}", track.title);
                                if player_loop.pause_generation() == pause_generation
                                    && cast_loop.is_active()
                                    && queue_loop.get_current_track().await.as_ref() == Some(&track)
                                {
                                    record_playback_error(&playback_error_loop, &track, &e)
                                        .await;
                                }
                            }
                        }
                        continue;
                    }

                    // The next track is already buffered in mpv's playlist;
                    // switch to it without a TIDAL or CDN round trip.
                    if player_loop.preloaded_matches(&track) {
                        let _guard = playback_command_lock_loop.lock().await;
                        if queue_loop.get_current_track().await.as_ref() != Some(&track) {
                            continue;
                        }
                        if player_loop.pause_generation() != pause_generation {
                            player_loop.mark_stream_stale();
                            continue;
                        }
                        match run_pipeline_op(&player_loop, TRANSPORT_OP_TIMEOUT, |p| {
                            p.play_preloaded()
                        })
                        .await
                        {
                            Ok(Some(played)) => {
                                if !request.handoff {
                                    *playback_error_loop.write().await = None;
                                }
                                *now_playing_loop.write().await = Some(played);
                                // The promotion announces the started track,
                                // which re-arms the preload in the loop below.
                                continue;
                            }
                            Ok(None) => {}
                            Err(e) => warn!(
                                "Could not switch to the preloaded track, loading it instead: {e}"
                            ),
                        }
                    }

                    // The queue, MPRIS and the UI already point at this track.
                    // Silence the outgoing stream now, before the TIDAL round
                    // trip: leaving it running underneath the new artwork makes
                    // the old song claim to be the new one, and a burst of skips
                    // would keep it playing until the last fetch lands.
                    // `stop_internal` does not register a user pause, so the
                    // play request continues.
                    {
                        let _guard = playback_command_lock_loop.lock().await;
                        if queue_loop.get_current_track().await.as_ref() != Some(&track) {
                            continue;
                        }
                        if player_loop.pause_generation() != pause_generation {
                            player_loop.mark_stream_stale();
                            continue;
                        }
                        if let Err(e) = run_pipeline_op(
                            &player_loop,
                            TRANSPORT_OP_TIMEOUT,
                            |p| p.stop_internal(),
                        )
                        .await
                        {
                            warn!(
                                "Could not stop the previous stream before loading {}: {e}",
                                track.title
                            );
                        }
                    }

                    // No status probe here: just fetch and play. The pipeline
                    // operation is bounded and the failure path cleans up a
                    // wedged client, so a healthy Play never pays for a
                    // subprocess.
                    let mut stream = None;
                    let mut last_error = String::new();
                    let mut cancelled = false;
                    for attempt in 1..=STREAM_FETCH_ATTEMPTS {
                        match catalogue_loop.get_stream_url(&track.id).await {
                            Ok(fresh) => {
                                stream = Some(fresh);
                                break;
                            }
                            Err(e) => {
                                last_error = e;
                                if !stream_fetch_error_is_retryable(&last_error)
                                    || attempt == STREAM_FETCH_ATTEMPTS
                                {
                                    break;
                                }
                                // The UI has already switched to this track.
                                // Leaving the previous stream running would
                                // make it claim the new song is playing while
                                // the old audio continues.
                                if attempt == 1 {
                                    warn!(
                                        "Stream fetch for {} failed: {last_error}; stopping the previous stream",
                                        track.title
                                    );
                                    stop_failed_playback(
                                        &player_loop,
                                        &queue_loop,
                                        &playback_command_lock_loop,
                                        &track,
                                        pause_generation,
                                    )
                                    .await;
                                }
                                warn!(
                                    "Retrying stream fetch for {} in {}s",
                                    track.title,
                                    STREAM_FETCH_RETRY_DELAY.as_secs()
                                );
                                if !wait_while_current(
                                    &player_loop,
                                    &queue_loop,
                                    &track,
                                    pause_generation,
                                    STREAM_FETCH_RETRY_DELAY,
                                )
                                .await
                                {
                                    cancelled = true;
                                    break;
                                }
                            }
                        }
                    }
                    if cancelled {
                        if player_loop.pause_generation() != pause_generation {
                            player_loop.mark_stream_stale();
                        }
                        info!("Skipping cancelled playback request for {}", track.title);
                        continue;
                    }

                    let Some((url, format)) = stream else {
                        error!("Failed to fetch stream URL for {}: {last_error}", track.id);
                        let handled = stop_failed_playback(
                            &player_loop,
                            &queue_loop,
                            &playback_command_lock_loop,
                            &track,
                            pause_generation,
                        )
                        .await;
                        if handled {
                            if cast_loop.is_active() {
                                cast_loop.stop();
                            }
                            record_playback_error(&playback_error_loop, &track, &last_error).await;
                        } else if player_loop.pause_generation() != pause_generation {
                            player_loop.mark_stream_stale();
                        }
                        continue;
                    };

                    // Casting may have started while the local fetch was in flight.
                    if cast_loop.is_active() {
                        if queue_loop.get_current_track().await.as_ref() != Some(&track)
                            || player_loop.pause_generation() != pause_generation
                        {
                            continue;
                        }
                        let play_track = track.clone();
                        match cast_loop.play_track(&play_track).await {
                            Ok(()) => {
                                if !request.handoff {
                                    *playback_error_loop.write().await = None;
                                }
                                *now_playing_loop.write().await = Some(play_track);
                            }
                            Err(e) => {
                                error!("Could not cast {}: {e}", track.title);
                                if player_loop.pause_generation() == pause_generation
                                    && cast_loop.is_active()
                                {
                                    record_playback_error(&playback_error_loop, &track, &e)
                                        .await;
                                }
                            }
                        }
                        continue;
                    }

                    let _guard = playback_command_lock_loop.lock().await;
                    if queue_loop.get_current_track().await.as_ref() != Some(&track) {
                        info!("Skipping stale playback request for {}", track.title);
                        continue;
                    }
                    if player_loop.pause_generation() != pause_generation {
                        player_loop.mark_stream_stale();
                        info!(
                            "Playback for {} was paused before its stream was ready",
                            track.title
                        );
                        continue;
                    }
                    let play_track = track.clone();
                    if let Err(e) = run_stream_op(&player_loop, STREAM_LOAD_TIMEOUT, move |p| {
                        // Re-check the pause intent for each attempt: a pause
                        // during the first timeout must not let the retry
                        // start playback.
                        if p.pause_generation() != pause_generation {
                            return Err("playback request was paused".to_string());
                        }
                        p.play_uri(&play_track, &url, format.clone())
                    })
                    .await
                    {
                        error!("Failed to play URI: {e}");
                        let _ = run_pipeline_op(
                            &player_loop,
                            TRANSPORT_OP_TIMEOUT,
                            |p| p.stop_internal(),
                        )
                        .await;
                        player_loop.refresh_failed();
                        if player_loop.pause_generation() == pause_generation {
                            // The URL may have come from the recent-stream
                            // cache; drop it so the next attempt fetches fresh
                            // instead of retrying the same dead one.
                            catalogue_loop.invalidate_stream(&track.id);
                            record_playback_error(&playback_error_loop, &track, &e).await;
                        }
                    } else {
                        if !request.handoff {
                            *playback_error_loop.write().await = None;
                        }
                        *now_playing_loop.write().await = Some(track);
                        // The load announces the started track, which re-arms
                        // the preload in the loop below.
                    }
                }
                Some(loaded) = stream_started_rx.recv() => {
                    // A stream load or a preloaded promotion just started a
                    // track: arm the preload for its successor. Every play path
                    // lands here, so no caller can forget to re-arm it. While
                    // casting, mpv holds nothing to preload into.
                    if !cast_loop.is_active() {
                        spawn_preload(
                            player_loop.clone(),
                            queue_loop.clone(),
                            catalogue_loop.clone(),
                            loaded,
                        );
                    }
                }
                Some(_) = eos_rx.recv() => {
                    let _guard = playback_command_lock_loop.lock().await;
                    info!("Track finished, advancing queue...");
                    if let Some(next_t) = queue_loop.next_track().await {
                        // Sync now_playing with the track that is now in the queue
                        *now_playing_loop.write().await = Some(next_t.clone());
                        let _ = play_tx_loop.send(QueuedPlay::new(
                            next_t,
                            player_loop.pause_generation(),
                        ));
                    }
                }
                Some(event) = cast_event_rx.recv() => {
                    let _guard = playback_command_lock_loop.lock().await;
                    match event {
                        cast::CastEvent::Finished => {
                            // A device that finished before the user stopped
                            // casting must not move the queue after the
                            // session ended.
                            if !cast_loop.is_active() {
                                continue;
                            }
                            info!("Cast device finished the track, advancing queue...");
                            if let Some(next_t) = queue_loop.next_track().await {
                                *now_playing_loop.write().await = Some(next_t.clone());
                                let _ = play_tx_loop.send(QueuedPlay::new(
                                    next_t,
                                    player_loop.pause_generation(),
                                ));
                            }
                        }
                        cast::CastEvent::Dropped => {
                            // The bridge died (device reboot, network drop,
                            // suspend): end the session before anyone touches
                            // the transport again and hand the track back to
                            // this machine.
                            cast_loop.connection_lost().await;
                        }
                    }
                }
                Some(_) = refresh_rx.recv() => {
                    // A stale stream (after wake, or after a stream error) was
                    // requested; spawn the refresh (deduplicated by
                    // `begin_stream_refresh`) so retries never starve cast or
                    // skip events in this loop.
                    let player_ref = player_loop.clone();
                    let queue_ref = queue_loop.clone();
                    let catalogue_ref = catalogue_loop.clone();
                    let lock_ref = playback_command_lock_loop.clone();
                    let error_ref = playback_error_loop.clone();
                    tokio::spawn(async move {
                        if let Err(e) = sleep::refresh_current_stream(
                            &player_ref,
                            &queue_ref,
                            &catalogue_ref,
                            &lock_ref,
                            false,
                            &error_ref,
                        )
                        .await
                        {
                            warn!("Stream refresh failed: {e}");
                        }
                    });
                }
                Some(_) = stall_rx.recv() => {
                    // mpv stopped moving its audio clock while reporting
                    // playback: the stream has no consumer. The player has
                    // already paused mpv and marked the stream stale, so the
                    // next Play reloads; here the user gets to see why.
                    if let Some(track) = queue_loop.get_current_track().await {
                        record_playback_error(&playback_error_loop, &track, AUDIO_STALLED).await;
                    }
                }
            }
        }
    });

    // The private RPC channel. There is no TCP listener for the plugin's API:
    // the socket is the only way in, and it dies with the user session.
    // Drop the initial receiver immediately so `receiver_count() == 0` lets
    // `publish_events` idle when no client is connected.
    let (event_tx, _) = tokio::sync::broadcast::channel::<rpc::Event>(64);
    let app_state = AppState {
        player: player.clone(),
        queue: queue.clone(),
        catalogue: catalogue.clone(),
        auth: auth.clone(),
        cast: cast.clone(),
        recent_searches: recent_searches.clone(),
        recent_contexts: Arc::new(RwLock::new(recent_contexts)),
        playback_command_lock,
        play_trigger_tx: play_tx.clone(),
        now_playing: now_playing.clone(),
        playback_error: playback_error.clone(),
        events: event_tx,
    };

    tokio::select! {
        result = rpc::serve(app_state) => result?,
        _ = shutdown_signal() => {}
    }
    rpc::remove_socket();

    // Stop the background persistence tasks before the final flush so they
    // cannot race on the shared `.json.tmp` paths.
    queue_persist_task.abort();
    playback_persist_task.abort();
    let _ = queue_persist_task.await;
    let _ = playback_persist_task.await;

    // Flush both files once more on the way out so a stop/restart immediately
    // after a change (including while casting) is not lost.
    let final_queue = queue.snapshot().await;
    persist_queue_state(&queue_path, &final_queue).await;
    let final_player = current_player_state_with_cast(&player, &queue, Some(&cast)).await;
    persist_player_state(&playback_file, &final_player).await;

    // The final playback.json flush above already carries the playhead for a
    // manual restart; the player process is disposable state.

    // Bound the final teardown well under the shutdown watchdog so
    // `player.shutdown()` and `cast.shutdown()` always run.
    let stop_player = player.clone();
    let _ = tokio::time::timeout(
        Duration::from_millis(1500),
        tokio::task::spawn_blocking(move || stop_player.stop_internal()),
    )
    .await;
    player.shutdown();
    cast.shutdown();
    info!("omarchy-tidalplayer shut down gracefully");
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to install signal handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {
            info!("Received Ctrl+C, initiating shutdown...");
        },
        _ = terminate => {
            info!("Received SIGTERM, initiating shutdown...");
        },
    }

    // Start a 4-second watchdog timer (below systemd's TimeoutStopSec=5) so
    // graceful flush + teardown can complete while guaranteeing a prompt exit.
    tokio::spawn(async {
        tokio::time::sleep(std::time::Duration::from_secs(4)).await;
        warn!("Graceful shutdown timed out after 4 seconds, forcing exit");
        std::process::exit(0);
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retries_rate_limits_and_transient_failures() {
        assert!(stream_fetch_error_is_retryable(
            "HTTP error 429 Too Many Requests: "
        ));
        assert!(stream_fetch_error_is_retryable(
            "HTTP error 503 Service Unavailable: "
        ));
        assert!(stream_fetch_error_is_retryable(
            "Request failed: connection reset"
        ));
        assert!(stream_fetch_error_is_retryable("Retry failed: timed out"));
        assert!(!stream_fetch_error_is_retryable(
            "HTTP error 404 Not Found: "
        ));
        assert!(!stream_fetch_error_is_retryable(
            "No stream URL in manifest"
        ));
        assert!(!stream_fetch_error_is_retryable("Not logged in"));
    }

    #[test]
    fn legacy_state_files_are_renamed_once() {
        let dir = std::env::temp_dir().join(format!(
            "omarchy-tidalplayer-file-migration-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        // A legacy file with no replacement is renamed.
        std::fs::write(dir.join("resume_after_restart.json"), b"marker").unwrap();
        // A legacy file with a current replacement is dropped; the new file
        // is authoritative.
        std::fs::write(dir.join("player_state.json"), b"old").unwrap();
        std::fs::write(dir.join("playback.json"), b"new").unwrap();
        // Playback-info caching was removed; its file must be deleted.
        std::fs::write(dir.join("stream_cache.json"), b"stale").unwrap();

        migrate_legacy_files(&dir);

        assert!(dir.join("restart_resume.json").exists());
        assert!(!dir.join("resume_after_restart.json").exists());
        assert_eq!(std::fs::read(dir.join("playback.json")).unwrap(), b"new");
        assert!(!dir.join("player_state.json").exists());
        assert!(!dir.join("stream_cache.json").exists());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn legacy_state_directory_is_renamed_once() {
        let base = std::env::temp_dir().join(format!(
            "omarchy-tidalplayer-state-migration-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join("omarchy-tidal")).unwrap();
        std::fs::write(base.join("omarchy-tidal/session.json"), b"session").unwrap();

        migrate_legacy_state_dir(&base);

        assert_eq!(
            std::fs::read(base.join("scorchedegg.tidalplayer/session.json")).unwrap(),
            b"session"
        );
        assert!(!base.join("omarchy-tidal").exists());

        // A stale legacy directory never replaces state the new name holds.
        std::fs::create_dir_all(base.join("omarchy-tidal")).unwrap();
        std::fs::write(base.join("omarchy-tidal/session.json"), b"stale").unwrap();
        migrate_legacy_state_dir(&base);
        assert_eq!(
            std::fs::read(base.join("scorchedegg.tidalplayer/session.json")).unwrap(),
            b"session"
        );

        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn the_persisted_state_combines_the_selection_and_session_settings() {
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let (refresh_tx, _refresh_rx) = tokio::sync::mpsc::unbounded_channel();
        let (stall_tx, _stall_rx) = tokio::sync::mpsc::unbounded_channel();
        let (started_tx, _started_rx) = tokio::sync::mpsc::unbounded_channel();
        let player = MpvPlayer::new(tx, refresh_tx, stall_tx, started_tx).unwrap();
        let queue = QueueManager::new();
        queue
            .set_queue(
                vec![
                    TrackItem {
                        id: "a".into(),
                        ..Default::default()
                    },
                    TrackItem {
                        id: "b".into(),
                        title: "B".into(),
                        ..Default::default()
                    },
                ],
                1,
                Some("Album".into()),
            )
            .await;
        queue.set_repeat("all").await;
        queue.set_shuffle(true).await;

        // A stopped player has no playhead of its own: the queue's selected
        // track is what gets persisted, at 0.
        let state = current_player_state(&player, &queue).await;
        assert_eq!(
            state.track.as_ref().map(|track| track.id.as_str()),
            Some("b")
        );
        assert_eq!(state.position, 0.0);
        assert!(state.shuffle);
        assert_eq!(state.repeat_mode, "all");

        // A parked playhead wins over the queue's selection and is kept.
        let current = queue.get_current_track().await.unwrap();
        player.restore_parked_state(&current, 12.5).unwrap();
        let state = current_player_state(&player, &queue).await;
        assert_eq!(state.track, Some(current));
        assert_eq!(state.position, 12.5);
    }

    #[test]
    fn playback_failure_message_names_the_track_and_cause() {
        let track = TrackItem {
            title: "Everything Matters".to_string(),
            ..Default::default()
        };

        assert!(
            playback_failure_message(&track, "HTTP error 429 Too Many Requests")
                .contains("rate limiting")
        );
        assert!(
            playback_failure_message(&track, "HTTP error 500 Internal Server Error")
                .contains("returned an error")
        );
        assert!(
            playback_failure_message(&track, "Request failed: connection reset")
                .contains("could not be reached")
        );
        assert!(
            playback_failure_message(&track, "HTTP error 404 Not Found").contains("could not find")
        );
        for unavail in [
            r#"HTTP error 401 Unauthorized: {"status":401,"subStatus":4005,"userMessage":"Asset is not ready for playback"}"#,
            r#"HTTP error 403 Forbidden: {"status":403,"subStatus":4032,"userMessage":"No content matching subscription location."}"#,
        ] {
            let msg = playback_failure_message(&track, unavail);
            assert!(msg.contains("not available for streaming"), "{msg}");
            assert!(!msg.contains("could not be loaded"), "{msg}");
        }
        assert!(
            playback_failure_message(&track, "No stream URL in manifest")
                .contains("did not provide a stream")
        );
        assert!(
            playback_failure_message(&track, crate::mpv::PIPELINE_WEDGED_ERROR)
                .contains("audio output stalled")
        );
        let unreachable = playback_failure_message(&track, AUDIO_SERVER_NOT_READY);
        assert!(unreachable.contains("audio server is not responding"));
        assert!(unreachable.contains("was not attempted"));

        let stalled = playback_failure_message(&track, AUDIO_STALLED);
        assert!(stalled.contains("sound device stopped receiving audio"));
        assert!(stalled.contains("audio output"));
        // A stalled output is not a TIDAL problem, so it must not look like one.
        assert!(!stalled.contains("could not be loaded"));

        let missing = playback_failure_message(
            &track,
            "Could not start mpv (mpv): No such file or directory",
        );
        assert!(missing.contains("mpv player is not installed"));
        assert!(missing.contains("omarchy pkg add mpv"));

        // A lost cast connection is not a stream problem; the message must
        // not send the user looking at their network or firewall for a
        // stream that never loaded.
        for error in [
            "the device could not play the stream: the cast device connection is closed",
            "the device could not play the stream: the cast device closed the connection",
            "the device could not play the stream: the cast device did not answer",
        ] {
            let lost = playback_failure_message(&track, error);
            assert!(lost.contains("connection to the cast device was lost"), "{lost}");
            assert!(!lost.contains("could not be loaded"), "{lost}");
        }

        // Retrying an unreachable audio server only delays the notification.
        assert!(!stream_fetch_error_is_retryable(AUDIO_SERVER_NOT_READY));

        let generic = playback_failure_message(&track, "something odd");
        assert!(generic.contains("Everything Matters"));
        assert!(generic.contains("could not be loaded"));
    }

    #[tokio::test]
    async fn attempt_failures_from_a_lost_connection_are_not_surfaced() {
        let slot: Arc<RwLock<Option<PlaybackError>>> = Arc::new(RwLock::new(None));
        let track = TrackItem {
            title: "Everything Matters".to_string(),
            ..Default::default()
        };

        // The session's recovery announces a lost connection once, by device
        // name; attempt failures with these errors must not double-toast.
        for error in [
            "the device could not play the stream: the cast device connection is closed",
            "the device could not play the stream: the cast device closed the connection",
            "the device could not play the stream: the cast device did not answer",
        ] {
            record_playback_error(&slot, &track, error).await;
            assert!(slot.read().await.is_none(), "lost connection alerted: {error}");
        }

        // A real failure still notifies.
        record_playback_error(&slot, &track, "HTTP error 429 Too Many Requests").await;
        assert!(slot.read().await.is_some());
    }

    #[tokio::test]
    async fn one_incident_only_stores_the_first_identical_message() {
        let slot: Arc<RwLock<Option<PlaybackError>>> = Arc::new(RwLock::new(None));

        store_playback_error(&slot, "Casting stopped: the connection was lost.".to_string()).await;
        let first = slot.read().await.clone().unwrap();

        // The same message arriving again (a failed attempt and the recovery
        // that follows it) must not become a second notification.
        store_playback_error(&slot, "Casting stopped: the connection was lost.".to_string()).await;
        let second = slot.read().await.clone().unwrap();
        assert_eq!(first.id, second.id, "the duplicate replaced the error");

        // A different message is a new incident and does notify. The id is
        // epoch-ms, so give the clock a tick to make the change observable
        // the way the UI's `id !== lastPlaybackErrorId` check sees it.
        tokio::time::sleep(std::time::Duration::from_millis(2)).await;
        store_playback_error(&slot, "Something else failed.".to_string()).await;
        let third = slot.read().await.clone().unwrap();
        assert_ne!(first.id, third.id);
        assert_eq!(third.message, "Something else failed.");
    }
}
