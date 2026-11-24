//! Casting to Chromecast-family devices on the LAN.
//!
//! While a session is active it is the transport authority: `/status`, MPRIS
//! and `/playback/action` read and drive it, and the local mpv pipeline is
//! stopped. Disconnecting hands playback back to mpv at the cast position.

mod bridge;
mod discovery;
mod media;
mod protocol;

pub use discovery::{CastDevice, CastDeviceKind};
use crate::api::PlaybackError;
use crate::auth::AuthManager;
use crate::catalogue::CatalogueManager;
use crate::mpris::MprisPlayback;
use crate::mpv::{same_queue_entry, FormatInfo, MpvPlayer, PipelineOwner, PlaybackState};
use crate::queue::{QueueManager, QueuedPlay, TrackItem};
use crate::{record_playback_error, record_playback_message};
use bridge::Bridge;
pub use bridge::CastEvent;
use media::{local_ip_toward, now_ms, stream_url, StreamServer};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tracing::{info, warn};

/// How long a LOAD may go without the device fetching its stream before the
/// UI offers the firewall command. A receiver normally connects immediately.
const STREAM_BLOCKED_AFTER_MS: u64 = 6000;

/// How long a Cast-port connect may take before the device counts as
/// unreachable. A receiver that is up accepts in milliseconds; only a dead
/// host leaves the SYN unanswered.
const PROBE_TIMEOUT: Duration = Duration::from_millis(600);
/// How long an unreachable device stays in the list, dimmed as Unavailable,
/// before it is dropped. Covers a transient Wi-Fi hiccup; a device that is
/// really gone does not linger.
const UNAVAILABLE_GRACE: Duration = Duration::from_secs(60);

/// The device the user cast to last, so the sheet can float it to the top and
/// the panel can offer it before mDNS has answered. Persisted as
/// `cast_last_used.json` beside the other state files.
const LAST_USED_FILE: &str = "cast_last_used.json";

#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct LastUsedDevice {
    device_id: String,
}

fn last_used_path() -> PathBuf {
    AuthManager::state_dir().join(LAST_USED_FILE)
}

/// Returns the remembered device id, if any. A missing or unreadable file is
/// simply "nothing remembered": the hint is a convenience, not state worth
/// failing over.
fn load_last_used(path: &Path) -> Option<String> {
    let content = std::fs::read_to_string(path).ok()?;
    let saved: LastUsedDevice = serde_json::from_str(&content).ok()?;
    if saved.device_id.is_empty() {
        None
    } else {
        Some(saved.device_id)
    }
}

fn save_last_used(path: &Path, device_id: &str) {
    let Ok(data) = serde_json::to_vec(&LastUsedDevice {
        device_id: device_id.to_string(),
    }) else {
        return;
    };
    let tmp = path.with_extension("json.tmp");
    if let Err(error) = std::fs::write(&tmp, data).and_then(|_| std::fs::rename(&tmp, path)) {
        warn!("Could not remember the last cast device: {error}");
    }
}

#[derive(Debug, Clone)]
pub struct CastSnapshot {
    pub device_id: String,
    pub device_name: String,
    /// What the device can output, from its own `ca` capability report. The
    /// household has a TV and a speaker on the same network, so the panel's
    /// Cast button wears the active device's class rather than one generic
    /// glyph; the session is the only authority on what that is.
    pub kind: CastDeviceKind,
    /// The track the receiver has actually loaded. The queue can move first;
    /// until this matches, `format` describes the previous cast track.
    pub track_id: String,
    pub state: PlaybackState,
    pub position: f64,
    pub duration: f64,
    pub volume: f64,
    /// What TIDAL delivered, which is now exactly what the device receives.
    pub format: FormatInfo,
    /// The playhead is frozen until the receiver's clock confirms that the
    /// stream is running (a LOAD, SEEK or resume is in flight). Consumers must
    /// not extrapolate the position while this is true.
    pub pending: bool,
    /// True when the receiver accepted the LOAD but never fetched the
    /// manifest — almost always an inbound firewall rule missing.
    pub stream_blocked: bool,
}

struct Session {
    device: CastDevice,
    bridge: Arc<Bridge>,
    token: parking_lot::RwLock<String>,
    track: parking_lot::RwLock<Option<TrackItem>>,
    format: parking_lot::RwLock<FormatInfo>,
    /// Track length from the queue, used until the receiver reports its own.
    duration: parking_lot::RwLock<f64>,
    /// Epoch-ms of the last LOAD handed to the receiver.
    loaded_at_ms: AtomicU64,
    /// The local output level when the session started. Casting adopts the
    /// device's own level, so this is what has to come back on disconnect.
    local_volume: f64,
}

impl Session {
    fn new(device: CastDevice, bridge: Arc<Bridge>, local_volume: f64) -> Self {
        Self {
            device,
            bridge,
            token: parking_lot::RwLock::new(String::new()),
            track: parking_lot::RwLock::new(None),
            format: parking_lot::RwLock::new(FormatInfo::default()),
            duration: parking_lot::RwLock::new(0.0),
            loaded_at_ms: AtomicU64::new(0),
            local_volume,
        }
    }
}

/// The playhead an outgoing session leaves for whatever takes over: another
/// cast device or the local pipeline.
struct Handoff {
    track: TrackItem,
    position: f64,
}

/// What a teardown leaves on the local pipeline.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Handback {
    /// A device switch: the new session continues from the returned playhead,
    /// nothing is loaded locally, and the manifest server stays open for the
    /// incoming receiver.
    Switch,
    /// Logging out: ends the session and closes the manifest server without
    /// handing playback back to local mpv.
    Logout,
    /// Hand playback back to this machine following the device's transport
    /// state. A dropped bridge counts as stopped, matching what the panel
    /// reported.
    FollowDevice,
    /// Hand playback back parked at the device's playhead. Used when the
    /// system is going to sleep: nothing may start on its own on wake.
    Parked,
    /// Hand playback back and start it: the user pressed Play on a session
    /// that can no longer be commanded.
    Resume,
}

/// Where a new session should start. A device switch continues from the
/// outgoing receiver's playhead; the local pipeline is stopped for the whole
/// cast session, so its own position is 0 and must not be used. Only when the
/// queue has moved on to another track does the fallback apply.
fn session_offset(handoff: Option<&Handoff>, track: &TrackItem, local_position: f64) -> f64 {
    match handoff {
        Some(handoff) if same_queue_entry(&handoff.track, track) => handoff.position,
        _ => local_position,
    }
}

/// The lost-connection announcement for a dead session, or `None` when the
/// loss must stay silent. A paused or stopped session losing its link
/// interrupts nothing — the track only parks on this machine — so a toast
/// would just narrate silence. Only a session that was playing is announced:
/// audio stopped (or moved to this machine) and the user deserves to know why.
fn lost_connection_message(
    handback: Handback,
    device: &str,
    state: PlaybackState,
) -> Option<String> {
    if state != PlaybackState::Playing {
        return None;
    }
    Some(match handback {
        Handback::Resume => {
            format!("The connection to {device} was lost. Playing on this computer instead.")
        }
        _ => format!("Casting stopped: the connection to {device} was lost."),
    })
}

/// A device as the panel sees it: the cached identity plus the result of a
/// live Cast-port probe. Unreachable devices are still listed for
/// `UNAVAILABLE_GRACE` so a transient Wi-Fi hiccup does not make the row and
/// the Cast button flicker, then they are dropped.
#[derive(Debug, Clone, serde::Serialize)]
pub struct VisibleDevice {
    #[serde(flatten)]
    pub device: CastDevice,
    pub available: bool,
}

pub struct CastManager {
    /// One long-lived mDNS browser plus its device cache. It keeps listening
    /// between panel opens, so a receiver that answers only occasionally is
    /// still found, and its cache remembers identities for
    /// `discovery::DEVICE_TTL`.
    discovery: discovery::Browser,
    session: parking_lot::RwLock<Option<Arc<Session>>>,
    /// Serialises session lifecycle transitions (`connect`/`disconnect`/`suspend`/`recover`)
    /// so concurrent connects cannot leak an orphaned bridge or manifest token.
    lifecycle_lock: tokio::sync::Mutex<()>,
    player: Arc<MpvPlayer>,
    queue: Arc<QueueManager>,
    catalogue: Arc<CatalogueManager>,
    play_tx: mpsc::UnboundedSender<QueuedPlay>,
    /// Manifest server, bound only while a cast session is active so no LAN
    /// port stays open when idle.
    streams: parking_lot::RwLock<Option<Arc<StreamServer>>>,
    events_tx: mpsc::UnboundedSender<CastEvent>,
    /// The user-visible error slot. A lost connection must reach the user as
    /// a notification, not just a log line.
    playback_error: Arc<tokio::sync::RwLock<Option<PlaybackError>>>,
    volume: parking_lot::RwLock<f64>,
    /// When each device first failed its Cast-port probe. A device drops out
    /// of the list once it has been unavailable for `UNAVAILABLE_GRACE`.
    /// Identity stays in the discovery cache either way.
    unavailable_since: parking_lot::Mutex<HashMap<String, Instant>>,
    /// The device that was cast to last, across restarts. Only a hint for the
    /// sheet's ordering and for offering the device before mDNS answers.
    last_used: parking_lot::RwLock<Option<String>>,
}

impl CastManager {
    pub async fn start(
        player: Arc<MpvPlayer>,
        queue: Arc<QueueManager>,
        catalogue: Arc<CatalogueManager>,
        play_tx: mpsc::UnboundedSender<QueuedPlay>,
        events_tx: mpsc::UnboundedSender<CastEvent>,
        playback_error: Arc<tokio::sync::RwLock<Option<PlaybackError>>>,
    ) -> Arc<Self> {
        let discovery =
            discovery::Browser::start(AuthManager::state_dir().join(discovery::DEVICES_FILE));
        let remembered = load_last_used(&last_used_path());
        Arc::new(Self {
            discovery,
            session: parking_lot::RwLock::new(None),
            lifecycle_lock: tokio::sync::Mutex::new(()),
            player,
            queue,
            catalogue,
            play_tx,
            streams: parking_lot::RwLock::new(None),
            events_tx,
            playback_error,
            volume: parking_lot::RwLock::new(1.0),
            unavailable_since: parking_lot::Mutex::new(HashMap::new()),
            last_used: parking_lot::RwLock::new(remembered),
        })
    }

    async fn ensure_stream_server(&self) -> Result<Arc<StreamServer>, String> {
        if let Some(server) = self.streams.read().clone() {
            return Ok(server);
        }
        let server = Arc::new(StreamServer::start().await?);
        info!(
            "Cast media proxy listening on port {} (inbound TCP must be allowed)",
            server.port
        );
        *self.streams.write() = Some(Arc::clone(&server));
        Ok(server)
    }

    async fn stop_stream_server(&self) {
        let server = self.streams.write().take();
        if let Some(server) = server {
            let port = server.port;
            server.shutdown().await;
            info!("Stopped cast media proxy on port {port}");
        }
    }

    /// The device id used last, remembered across daemon restarts.
    pub fn last_used(&self) -> Option<String> {
        self.last_used.read().clone()
    }

    /// One scan at boot so the first panel open already has the device list.
    pub fn startup_sweep(self: &Arc<Self>) {
        let manager = Arc::clone(self);
        tokio::spawn(async move {
            manager.refresh_devices().await;
        });
    }

    /// Forces a query burst and returns the list once the scan window closes.
    pub async fn refresh_devices(&self) -> Vec<VisibleDevice> {
        let devices = self.discovery.scan(true).await;
        let visible = self.visible_devices(devices).await;
        let available = visible.iter().filter(|entry| entry.available).count();
        info!(
            "Cast device list: {available} available, {} unavailable",
            visible.len() - available
        );
        visible
    }

    /// `refresh` asks for a query burst (rate-limited by the browser); without
    /// it the cached identities are used, which is what the panel polls
    /// between scans. Either way presence is decided by a live probe, so the
    /// list reflects what is actually reachable now.
    pub async fn devices(&self, refresh: bool) -> Vec<VisibleDevice> {
        let devices = if refresh {
            self.discovery.scan(false).await
        } else {
            self.discovery.snapshot()
        };
        self.visible_devices(devices).await
    }

    /// Probes every known device's Cast port concurrently and folds in the
    /// unavailable grace. Reachable devices sort first (alphabetically, as the
    /// discovery cache hands them over); an unreachable one drops to the
    /// bottom, then out of the list once its grace has run out.
    async fn visible_devices(&self, devices: Vec<CastDevice>) -> Vec<VisibleDevice> {
        if devices.is_empty() {
            self.unavailable_since.lock().clear();
            return Vec::new();
        }
        let reachable = futures::future::join_all(
            devices
                .iter()
                .map(|device| probe_cast_port(&device.host, device.port)),
        )
        .await;
        // While a session is live the bridge's own connection is the better
        // presence signal; a stray probe failure must not dim the row of the
        // device that is playing.
        let active = self
            .session
            .read()
            .as_ref()
            .filter(|session| session.bridge.is_alive())
            .map(|session| session.device.id.clone());
        let mut unavailable_since = self.unavailable_since.lock();
        fold_presence(
            devices,
            reachable,
            active.as_deref(),
            &mut unavailable_since,
            Instant::now(),
        )
    }

    pub fn is_active(&self) -> bool {
        self.session.read().is_some()
    }

    pub fn shutdown(&self) {
        self.discovery.shutdown();
        if let Some(session) = self.session.write().take() {
            session.bridge.close();
        }
        if let Some(server) = self.streams.write().take() {
            server.trigger_shutdown();
        }
    }

    fn position_of(&self, session: &Session) -> f64 {
        let position = session.bridge.media.read().live_position();
        let duration = self.duration_of(session);
        let position = if duration > 0.0 {
            position.min(duration)
        } else {
            position
        };
        position.max(0.0)
    }

    fn duration_of(&self, session: &Session) -> f64 {
        let reported = session.bridge.media.read().duration;
        if reported > 0.0 {
            reported
        } else {
            *session.duration.read()
        }
    }

    fn stream_blocked(&self, session: &Session) -> bool {
        let Some(server) = self.streams.read().clone() else {
            return false;
        };
        is_stream_blocked(
            session.bridge.is_alive(),
            session.bridge.transport().is_some(),
            session.loaded_at_ms.load(Ordering::SeqCst),
            server.last_request_ms(),
            now_ms(),
        )
    }

    pub fn snapshot(&self) -> Option<CastSnapshot> {
        let session = self.session.read().clone()?;
        let duration = self.duration_of(&session);
        let live = session.bridge.is_alive() && !session.bridge.has_failed();
        // The receiver is the transport authority, not just for our own
        // commands: a pause, resume or stop made on the device or by another
        // sender arrives as a MEDIA_STATUS and must reach MPRIS and the panel
        // the same way. `Bridge` holds the one copy of that state.
        let state = if live {
            session.bridge.media.read().playback_state()
        } else {
            // The device dropped the connection or rejected the stream; stop
            // claiming it is playing.
            PlaybackState::Stopped
        };
        let pending = live && session.bridge.awaiting_start();
        let format = session.format.read().clone();
        // The receiver's own level wins: it is the speaker the user is actually
        // hearing, and it can be changed on the device itself or by another
        // sender, so /status has to report the live value, not the last one we
        // wrote.
        let volume = session
            .bridge
            .volume()
            .unwrap_or_else(|| *self.volume.read());
        *self.volume.write() = volume;
        let stream_blocked = self.stream_blocked(&session);
        let track_id = session
            .track
            .read()
            .as_ref()
            .map(|track| track.id.clone())
            .unwrap_or_default();
        Some(CastSnapshot {
            device_id: session.device.id.clone(),
            device_name: session.device.name.clone(),
            kind: session.device.kind(),
            track_id,
            state,
            position: self.position_of(&session),
            duration,
            volume,
            format,
            pending,
            stream_blocked,
        })
    }

    /// Connects to `device_id`, moves the current track onto it and stops the
    /// local pipeline. A failure leaves local playback untouched.
    pub async fn connect(self: &Arc<Self>, device_id: &str) -> Result<CastDevice, String> {
        let _lifecycle = self.lifecycle_lock.lock().await;
        let result = self.connect_unlocked(device_id).await;
        if result.is_err() && self.session.read().is_none() {
            self.stop_stream_server().await;
        }
        result
    }

    async fn connect_unlocked(self: &Arc<Self>, device_id: &str) -> Result<CastDevice, String> {
        let mut device = self
            .devices(false)
            .await
            .into_iter()
            .map(|entry| entry.device)
            .find(|device| device.id == device_id);
        if device.is_none() {
            device = self
                .refresh_devices()
                .await
                .into_iter()
                .map(|entry| entry.device)
                .find(|device| device.id == device_id);
        }
        let mut device =
            device.ok_or_else(|| "that cast device is no longer on the network".to_string())?;

        // When reconnecting to the same device, tear down first so the single
        // receiver app isn't raced. When switching to a different device, keep
        // the old session alive until the new device connects and launches, so
        // an unreachable target leaves current playback intact.
        let switching_same = self
            .session
            .read()
            .as_ref()
            .is_some_and(|s| s.device.id == device.id);
        let mut handoff = if switching_same {
            self.teardown_unlocked(Handback::Switch).await
        } else {
            None
        };

        let bridge = match Bridge::connect(&device.host, device.port, self.events_tx.clone()).await {
            Ok(bridge) => bridge,
            Err(first_error) => {
                // The cached address can be stale (a fresh DHCP lease, or an
                // mDNS answer that only carried the other address family).
                let Some(refreshed) = self
                    .refresh_devices()
                    .await
                    .into_iter()
                    .map(|entry| entry.device)
                    .find(|candidate| candidate.id == device.id)
                    .filter(|candidate| candidate.host != device.host)
                else {
                    return Err(first_error);
                };
                let bridge =
                    Bridge::connect(&refreshed.host, refreshed.port, self.events_tx.clone())
                        .await
                        .map_err(|error| format!("{first_error}; retry failed: {error}"))?;
                device = refreshed;
                bridge
            }
        };
        if let Err(error) = bridge.launch_receiver().await {
            warn!("Cast launch on {} failed: {error}", device.name);
            bridge.close();
            return Err(error);
        }

        // Now that the new receiver is live, capture the outgoing session's
        // playhead and preserve the original local volume when switching.
        let outgoing_local_volume = self.session.read().as_ref().map(|s| s.local_volume);
        if handoff.is_none() && self.session.read().is_some() {
            handoff = self.teardown_unlocked(Handback::Switch).await;
        }
        let local_volume = outgoing_local_volume.unwrap_or_else(|| self.player.get_volume());
        let level = bridge.volume().unwrap_or_else(|| local_volume.clamp(0.0, 1.0));
        *self.volume.write() = level;

        let session = Session::new(device.clone(), bridge.clone(), local_volume);
        if let Err(error) = self.ensure_stream_server().await {
            warn!("Cast stream server failed to start: {error}");
            bridge.close();
            return Err(error);
        }
        let local_position = if self.player.get_state() == PlaybackState::Stopped {
            0.0
        } else {
            self.player.get_position()
        };
        if let Err(error) = self
            .prepare_session(&session, handoff.as_ref(), local_position)
            .await
        {
            warn!("Cast connect to {} failed: {error}", device.name);
            bridge.close();
            return Err(error);
        }

        // The device has the stream; only now silence the local output.
        let _ = self.player.stop_internal();
        *self.session.write() = Some(Arc::new(session));
        self.remember_last_used(&device);
        info!("Casting to {} ({})", device.name, device.host);
        Ok(device)
    }

    /// Records the device for the sheet's ordering. Only a successful connect
    /// counts: a failed click must not become the "last used" device.
    fn remember_last_used(&self, device: &CastDevice) {
        *self.last_used.write() = Some(device.id.clone());
        let id = device.id.clone();
        let path = last_used_path();
        tokio::task::spawn_blocking(move || save_last_used(&path, &id));
    }

    async fn prepare_session(
        &self,
        session: &Session,
        handoff: Option<&Handoff>,
        local_position: f64,
    ) -> Result<(), String> {
        let Some(track) = self.queue.get_current_track().await else {
            return Ok(());
        };
        let offset = session_offset(handoff, &track, local_position);
        let offset = if track.duration > 0.0 {
            offset.min((track.duration - 0.5).max(0.0))
        } else {
            offset
        };
        self.load_into(session, &track, offset).await
    }

    /// Serves the track's DASH manifest and hands its URL to the receiver. The
    /// device fetches TIDAL's segments itself, so nothing is re-encoded and the
    /// device owns the timeline.
    async fn load_into(
        &self,
        session: &Session,
        track: &TrackItem,
        start_at: f64,
    ) -> Result<(), String> {
        // Freeze the playhead from the moment the hand-off begins. The
        // manifest fetch below plus the receiver's own start-up take long
        // enough that a clock started here would lead the audio by that much
        // and snap back on the first device sample. Report it as loading too:
        // the receiver answers `IDLE` until the new manifest is accepted, and
        // a track change must not flicker through Stopped in the panel.
        session.bridge.mark_loading(start_at);
        match self.load_into_loaded(session, track, start_at).await {
            Ok(()) => Ok(()),
            Err(error) => {
                if session.bridge.is_alive() && session.bridge.transport().is_some() {
                    // The receiver still has the previous stream: drop the
                    // hold and let the status poll re-anchor the clock to it.
                    session.bridge.release_hold();
                } else {
                    // The connection or receiver app is gone, so there is no
                    // stream to re-anchor to: report the session stopped
                    // instead of leaving the optimistic loading state behind.
                    session.bridge.mark_resume_failed();
                }
                Err(error)
            }
        }
    }

    async fn load_into_loaded(
        &self,
        session: &Session,
        track: &TrackItem,
        start_at: f64,
    ) -> Result<(), String> {
        let server = self
            .streams
            .read()
            .clone()
            .ok_or_else(|| "the cast stream server is not running".to_string())?;
        let (manifest, format) = self.catalogue.get_cast_manifest(&track.id).await?;

        let token = server.register(manifest).await;
        let url = stream_url_for(session, &server, &token);
        let loaded_at_ms = match session
            .bridge
            .load(
                &url,
                "application/dash+xml",
                "BUFFERED",
                &track.title,
                &track.artist,
                start_at,
            )
            .await
        {
            Ok(sent_at_ms) => sent_at_ms,
            Err(error) => {
                server.remove(&token).await;
                return Err(format!("the device could not play the stream: {error}"));
            }
        };
        // Only stamp `loaded_at_ms` once the receiver actually accepted the
        // LOAD: a failed LOAD drops its token and never asks the device to
        // fetch, so stamping beforehand turned receiver timeouts into false
        // firewall prompts. `sent_at_ms` was captured right before the
        // accepted LOAD was written, so any fetch it triggered lands at or
        // after it.
        session.loaded_at_ms.store(loaded_at_ms, Ordering::SeqCst);

        let previous = std::mem::take(&mut *session.token.write());
        if !previous.is_empty() {
            server.remove(&previous).await;
        }
        // If teardown ran while `bridge.load()` was awaiting, don't leak the
        // new token on an orphaned session.
        if !session.bridge.is_alive() {
            server.remove(&token).await;
            return Err("the cast device connection is closed".to_string());
        }
        *session.token.write() = token;
        *session.track.write() = Some(track.clone());
        *session.format.write() = format.clone();
        *session.duration.write() = track.duration;
        info!(
            "Casting “{}” from {start_at:.1}s ({})",
            track.title, format.badge
        );
        Ok(())
    }

    /// A new track arrived while casting. The playback loop passes the stream
    /// it already fetched for local playback; casting re-reads the manifest so
    /// the device gets one it can pull segments from.
    pub async fn play_track(&self, track: &TrackItem) -> Result<(), String> {
        let Some(session) = self.session.read().clone() else {
            return Ok(());
        };
        self.load_into(&session, track, 0.0).await
    }

    /// Stops casting and hands playback back to the local pipeline.
    pub async fn disconnect(&self) -> Result<(), String> {
        let _lifecycle = self.lifecycle_lock.lock().await;
        let _ = self.teardown_unlocked(Handback::FollowDevice).await;
        Ok(())
    }

    /// Stops casting during logout without handing playback back to local mpv.
    pub async fn disconnect_for_logout(&self) {
        let _lifecycle = self.lifecycle_lock.lock().await;
        let local_volume = self.session.read().as_ref().map(|s| s.local_volume);
        let _ = self.teardown_unlocked(Handback::Logout).await;
        if let Some(level) = local_volume {
            self.player.set_volume(level);
            *self.volume.write() = level;
        }
    }

    /// The system is going to sleep. End the session while the network still
    /// works and leave the track parked on this machine at the device's
    /// playhead, mirroring what happens to local playback: nothing starts on
    /// its own on wake.
    pub async fn suspend(&self) {
        let _lifecycle = self.lifecycle_lock.lock().await;
        let _ = self.teardown_unlocked(Handback::Parked).await;
    }

    /// The bridge died on its own — a device reboot, a network drop or a
    /// suspend the clean-up missed. The session cannot be commanded any more:
    /// end it, hand the track back to the local pipeline and tell the user
    /// where playback went.
    pub async fn connection_lost(&self) {
        self.recover(Handback::FollowDevice).await;
    }

    /// Ends a session whose bridge is dead. A stale event from an earlier
    /// connection finds the session gone (or its replacement healthy) and does
    /// nothing. `handback` decides the play intent of the hand-off. A loss is
    /// announced once and only when the session was playing: playback moved
    /// back to this machine, so the user knows to resume here or reconnect
    /// from the sheet. A paused or stopped session stays silent — nothing was
    /// interrupted and the track only parks here.
    async fn recover(&self, handback: Handback) {
        let _lifecycle = self.lifecycle_lock.lock().await;
        let Some(session) = self.session.read().clone() else {
            return;
        };
        if session.bridge.is_alive() {
            // A stale event from an earlier connection; the session that is
            // active now is healthy.
            return;
        }
        let device = session.device.name.clone();
        let track = session.track.read().clone();
        // What the receiver last reported, read before the teardown drops the
        // session: whether anything was audible decides if the loss is worth
        // telling the user about.
        let state = session.bridge.media.read().playback_state();
        let _ = self.teardown_unlocked(handback).await;
        info!("Lost the cast connection to {device}");
        if track.is_some() {
            if let Some(message) = lost_connection_message(handback, &device, state) {
                record_playback_message(&self.playback_error, message).await;
            }
        }
    }

    /// Takes the session down and returns the playhead it leaves behind, for a
    /// device switch to continue from. `handback` decides what happens on this
    /// machine: nothing (a switch), or the track parked/resuming at the
    /// device's playhead.
    async fn teardown_unlocked(&self, handback: Handback) -> Option<Handoff> {
        // Scope the session lock so no parking_lot guard is held across the
        // awaits below (that would make the future non-Send).
        let Some(session) = ({
            let mut guard = self.session.write();
            guard.take()
        }) else {
            if handback != Handback::Switch {
                self.stop_stream_server().await;
            }
            return None;
        };
        let position = self.position_of(&session);
        let track = session.track.read().clone();
        let token = session.token.read().clone();
        // What the panel last reported: a dropped bridge is a stopped session
        // regardless of the transport state it was left in.
        let state = if session.bridge.is_alive() && !session.bridge.has_failed() {
            session.bridge.media.read().playback_state()
        } else {
            PlaybackState::Stopped
        };
        session.bridge.close();
        let server = self.streams.read().clone();
        if let Some(server) = server {
            server.remove(&token).await;
        }
        if handback != Handback::Switch {
            self.stop_stream_server().await;
        }
        // A switch hands the playhead to the new device instead of loading
        // anything locally; logout drops the session without resuming locally.
        let resume = match handback {
            Handback::Switch | Handback::Logout => None,
            Handback::Resume => Some(true),
            Handback::Parked => Some(false),
            Handback::FollowDevice => Some(state == PlaybackState::Playing),
        };
        if let Some(resume) = resume {
            // Casting adopted the device's own level; hand the speakers back
            // at the level this machine was on before the session started.
            self.player.set_volume(session.local_volume);
            *self.volume.write() = session.local_volume;
            if let Some(track) = track.clone() {
                if resume {
                    self.player.resume_local_at(&track, position);
                } else {
                    // A session that was paused, stopped or dropped hands the
                    // track back parked: ending the cast must not start the
                    // song on this machine.
                    self.player.park_local_at(&track, position);
                }
                let _ = self.play_tx.send(QueuedPlay::for_handoff(
                    track,
                    self.player.pause_generation(),
                ));
            }
        }
        info!("Stopped casting");
        track.map(|track| Handoff { track, position })
    }

    pub fn play(self: &Arc<Self>) {
        let Some(session) = self.session.read().clone() else {
            return;
        };
        if !session.bridge.is_alive() {
            // The connection died without the drop being handled yet. The
            // user asked for playback: hand it back to this machine and
            // start it from the device's playhead.
            self.spawn_recover(Handback::Resume);
            return;
        }
        if session.bridge.media.read().playback_state() == PlaybackState::Stopped
            || session.bridge.transport().is_none()
        {
            // A STOP — ours, the device's own, or an idled-out receiver app —
            // leaves no media loaded, so Play has to hand it the manifest
            // again (relaunching Default Media Receiver if needed). Prefer the
            // queue's current track so a skip that landed while the receiver
            // was down plays that track rather than reverting to an older one.
            let at = session.bridge.media.read().position;
            let session_track = session.track.read().clone();
            session.bridge.mark_loading(at);
            let manager = Arc::clone(self);
            tokio::spawn(async move {
                let current_queue_track = manager.queue.get_current_track().await;
                let (track, start_at) = match (current_queue_track, session_track) {
                    (Some(queue_track), Some(loaded_track))
                        if same_queue_entry(&queue_track, &loaded_track) =>
                    {
                        (loaded_track, at)
                    }
                    (Some(queue_track), _) => (queue_track, 0.0),
                    (None, Some(loaded_track)) => (loaded_track, at),
                    (None, None) => {
                        session.bridge.mark_resume_failed();
                        return;
                    }
                };
                if let Err(error) = manager.load_into(&session, &track, start_at).await {
                    warn!("Could not resume the cast stream: {error}");
                    session.bridge.mark_resume_failed();
                    // Only a failure of the session this manager still holds
                    // reaches the user; a lost connection is never announced.
                    let still_ours = manager
                        .session
                        .read()
                        .as_ref()
                        .is_some_and(|current| Arc::ptr_eq(current, &session));
                    if still_ours {
                        record_playback_error(&manager.playback_error, &track, &error).await;
                    }
                }
            });
        } else {
            session.bridge.play();
        }
    }

    pub fn pause(self: &Arc<Self>) {
        let Some(session) = self.session.read().clone() else {
            return;
        };
        if !session.bridge.is_alive() {
            self.spawn_recover(Handback::FollowDevice);
            return;
        }
        session.bridge.pause();
    }

    pub fn toggle(self: &Arc<Self>) {
        let Some(session) = self.session.read().clone() else {
            return;
        };
        // The device's state, not a local mirror: a pause made on the
        // receiver or by another sender has to make the next press a play.
        if session.bridge.media.read().playback_state() == PlaybackState::Playing {
            self.pause();
        } else {
            self.play();
        }
    }

    pub fn stop(self: &Arc<Self>) {
        let Some(session) = self.session.read().clone() else {
            return;
        };
        if !session.bridge.is_alive() {
            self.spawn_recover(Handback::FollowDevice);
            return;
        }
        session.loaded_at_ms.store(0, Ordering::SeqCst);
        session.bridge.stop();
    }

    /// A DASH track is a finite asset, so the receiver seeks its own timeline.
    pub fn seek(self: &Arc<Self>, seconds: f64) {
        if !seconds.is_finite() {
            return;
        }
        let Some(session) = self.session.read().clone() else {
            return;
        };
        if !session.bridge.is_alive() {
            self.spawn_recover(Handback::FollowDevice);
            return;
        }
        let duration = self.duration_of(&session);
        let mut target = seconds.max(0.0);
        if duration > 0.0 {
            target = target.min((duration - 0.5).max(0.0));
        }
        session.bridge.seek(target);
    }

    pub fn set_volume(self: &Arc<Self>, volume: f64) {
        if !volume.is_finite() {
            return;
        }
        let level = volume.clamp(0.0, 1.0);
        if let Some(session) = self.session.read().clone() {
            if !session.bridge.is_alive() {
                self.spawn_recover(Handback::FollowDevice);
                return;
            }
            session.bridge.set_volume(level);
        }
        *self.volume.write() = level;
    }

    /// Ends a dead session off the transport path, where `teardown` cannot be
    /// awaited directly. `recover` ignores the call if the session came back
    /// (or was replaced) while this was queued.
    fn spawn_recover(self: &Arc<Self>, handback: Handback) {
        let manager = Arc::clone(self);
        tokio::spawn(async move {
            manager.recover(handback).await;
        });
    }

    pub fn get_volume(&self) -> f64 {
        if let Some(session) = self.session.read().as_ref() {
            if let Some(live) = session.bridge.volume() {
                *self.volume.write() = live;
                return live;
            }
        }
        *self.volume.read()
    }
}

fn stream_url_for(session: &Session, server: &StreamServer, token: &str) -> String {
    let ip = local_ip_toward(&session.device.host).unwrap_or_else(|| {
        // Fall back to a loopback address so the LOAD still carries a URL; the
        // receiver will fail to connect and the blocked state explains why.
        std::net::IpAddr::from([127, 0, 0, 1])
    });
    stream_url(ip, server.port, token)
}

/// Whether the receiver accepted a `LOAD` on a live receiver app and then
/// failed to reach our manifest server within `STREAM_BLOCKED_AFTER_MS`.
/// A dead connection, a closed receiver app, or a `LOAD` that was never
/// accepted (`loaded_at_ms == 0`) must never point at the firewall.
fn is_stream_blocked(
    bridge_alive: bool,
    has_transport: bool,
    loaded_at_ms: u64,
    last_request_ms: u64,
    now_ms: u64,
) -> bool {
    bridge_alive
        && has_transport
        && loaded_at_ms > 0
        && now_ms.saturating_sub(loaded_at_ms) > STREAM_BLOCKED_AFTER_MS
        && last_request_ms < loaded_at_ms
}

/// Folds probe results into the list the panel sees. Kept free of I/O so the
/// grace and the ordering can be tested: an unreachable device is reported as
/// unavailable (bottom of the list) for `UNAVAILABLE_GRACE`, then dropped. Its
/// identity stays in the discovery cache, which is why a later probe can bring
/// it straight back.
fn fold_presence(
    devices: Vec<CastDevice>,
    reachable: Vec<bool>,
    active: Option<&str>,
    unavailable_since: &mut HashMap<String, Instant>,
    now: Instant,
) -> Vec<VisibleDevice> {
    let mut live = HashSet::with_capacity(devices.len());
    let mut visible = Vec::with_capacity(devices.len());
    for (device, reachable) in devices.into_iter().zip(reachable) {
        live.insert(device.id.clone());
        if reachable || active == Some(device.id.as_str()) {
            unavailable_since.remove(&device.id);
            visible.push(VisibleDevice {
                device,
                available: true,
            });
            continue;
        }
        let since = *unavailable_since.entry(device.id.clone()).or_insert(now);
        if now.saturating_duration_since(since) < UNAVAILABLE_GRACE {
            visible.push(VisibleDevice {
                device,
                available: false,
            });
        }
    }
    unavailable_since.retain(|id, _| live.contains(id));
    visible.sort_by_key(|entry| !entry.available);
    visible
}

/// A Cast receiver that is powered and on the network accepts a TCP
/// connection on its advertised port immediately, even when it is ignoring
/// mDNS queries (the state that made discovery look broken). One connect is
/// enough: no CastV2 handshake, no TLS.
async fn probe_cast_port(host: &str, port: u16) -> bool {
    matches!(
        tokio::time::timeout(
            PROBE_TIMEOUT,
            tokio::net::TcpStream::connect((host, port)),
        )
        .await,
        Ok(Ok(_stream))
    )
}

/// The MPRIS handle: every transport call follows the active output. The
/// pipeline accessors always belong to mpv, because that is the process the
/// wedge/restart machinery supervises.
pub struct CastAwarePlayback {
    mpv: Arc<MpvPlayer>,
    cast: Arc<CastManager>,
}

impl CastAwarePlayback {
    pub fn new(mpv: Arc<MpvPlayer>, cast: Arc<CastManager>) -> Self {
        Self { mpv, cast }
    }

    fn active_state(&self) -> Option<PlaybackState> {
        self.cast.snapshot().map(|snapshot| snapshot.state)
    }
}

impl PipelineOwner for CastAwarePlayback {
    fn pipeline_generation(&self) -> u64 {
        self.mpv.pipeline_generation()
    }

    fn rebuild_wedged_pipeline(&self) -> Result<(), String> {
        self.mpv.rebuild_wedged_pipeline()
    }

    fn pause_generation(&self) -> u64 {
        self.mpv.pause_generation()
    }
}

impl MprisPlayback for CastAwarePlayback {
    fn get_state(&self) -> PlaybackState {
        self.active_state()
            .unwrap_or_else(|| MpvPlayer::get_state(&self.mpv))
    }

    fn get_position(&self) -> f64 {
        self.cast
            .snapshot()
            .map(|snapshot| snapshot.position)
            .unwrap_or_else(|| MpvPlayer::get_position(&self.mpv))
    }

    fn get_duration(&self) -> f64 {
        self.cast
            .snapshot()
            .map(|snapshot| snapshot.duration)
            .unwrap_or_else(|| MpvPlayer::get_duration(&self.mpv))
    }

    fn seek(&self, seconds: f64) -> Result<(), String> {
        if self.cast.is_active() {
            self.cast.seek(seconds);
            Ok(())
        } else {
            MpvPlayer::seek(&self.mpv, seconds)
        }
    }

    fn pause(&self) -> Result<(), String> {
        if self.cast.is_active() {
            self.cast.pause();
            Ok(())
        } else {
            MpvPlayer::pause(&self.mpv)
        }
    }

    fn play(&self) -> Result<(), String> {
        if self.cast.is_active() {
            self.cast.play();
            Ok(())
        } else {
            MpvPlayer::play(&self.mpv)
        }
    }

    fn stop(&self) -> Result<(), String> {
        if self.cast.is_active() {
            self.cast.stop();
            Ok(())
        } else {
            MpvPlayer::stop(&self.mpv)
        }
    }

    fn toggle(&self) -> Result<PlaybackState, String> {
        if self.cast.is_active() {
            self.cast.toggle();
            Ok(self.active_state().unwrap_or(PlaybackState::Playing))
        } else {
            MpvPlayer::toggle(&self.mpv)
        }
    }

    fn get_volume(&self) -> f64 {
        if self.cast.is_active() {
            self.cast.get_volume()
        } else {
            MpvPlayer::get_volume(&self.mpv)
        }
    }

    fn set_volume(&self, volume: f64) {
        if self.cast.is_active() {
            self.cast.set_volume(volume);
        } else {
            MpvPlayer::set_volume(&self.mpv, volume);
        }
    }

    fn set_rate(&self, rate: f64) -> Result<(), String> {
        if (rate - 1.0).abs() < f64::EPSILON {
            Ok(())
        } else {
            Err("TIDAL playback only supports a rate of 1.0".into())
        }
    }

    fn note_user_pause(&self) {
        // Still bump the local generation: an in-flight local load must be
        // cancelled even while the device owns playback.
        MpvPlayer::note_user_pause(&self.mpv);
    }
}

#[cfg(test)]
mod tests {
    use super::{
        fold_presence, is_stream_blocked, last_used_path, load_last_used, lost_connection_message,
        probe_cast_port, save_last_used, session_offset, CastDevice, Handback, Handoff,
        LastUsedDevice, STREAM_BLOCKED_AFTER_MS, UNAVAILABLE_GRACE,
    };
    use crate::mpv::PlaybackState;
    use crate::queue::TrackItem;
    use std::collections::HashMap;
    use std::time::{Duration, Instant};

    fn scratch_dir(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("omarchy-tidalplayer-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn device(id: &str, host: &str) -> CastDevice {
        CastDevice {
            id: id.to_string(),
            name: "Living Room speaker".to_string(),
            model: "Google Nest Mini".to_string(),
            capabilities: 198660,
            host: host.to_string(),
            port: 8009,
        }
    }

    fn track(id: &str) -> TrackItem {
        TrackItem {
            id: id.to_string(),
            title: format!("Track {id}"),
            artist: "Artist".to_string(),
            album: "Album".to_string(),
            duration: 300.0,
            ..Default::default()
        }
    }

    #[test]
    fn a_device_switch_continues_from_the_outgoing_receivers_playhead() {
        let current = track("3113167");
        let handoff = Handoff {
            track: current.clone(),
            position: 98.45,
        };
        // The local pipeline is stopped for the whole session, so its position
        // is 0; the outgoing receiver's playhead must win.
        assert_eq!(session_offset(Some(&handoff), &current, 0.0), 98.45);
        // The queue moved on while the switch was happening: the new device
        // starts the new track rather than jumping into the old playhead.
        assert_eq!(session_offset(Some(&handoff), &track("2"), 0.0), 0.0);
        // A first cast, with local playback as the source, keeps its position.
        assert_eq!(session_offset(None, &current, 42.0), 42.0);
    }

    #[test]
    fn a_lost_connection_is_only_announced_while_playing() {
        // A paused or stopped session losing its link interrupts nothing: the
        // track just parks here, so no toast may narrate the silence.
        for state in [PlaybackState::Paused, PlaybackState::Stopped] {
            for handback in [Handback::FollowDevice, Handback::Resume, Handback::Parked] {
                assert!(
                    lost_connection_message(handback, "Living Room speaker", state).is_none(),
                    "announced a loss while {state:?} ({handback:?})"
                );
            }
        }

        // Playing audio stopped by the loss is worth an explanation.
        let playing = lost_connection_message(
            Handback::FollowDevice,
            "Living Room speaker",
            PlaybackState::Playing,
        )
        .unwrap();
        assert!(playing.contains("Living Room speaker"), "{playing}");
        assert!(playing.contains("connection"), "{playing}");

        // A play press on a dead session starts playback here instead.
        let resumed = lost_connection_message(
            Handback::Resume,
            "Living Room speaker",
            PlaybackState::Playing,
        )
        .unwrap();
        assert!(resumed.contains("Playing on this computer instead"), "{resumed}");
    }

    #[test]
    fn the_last_used_device_round_trips_through_the_state_file() {
        let dir = scratch_dir("cast-last-used");
        let path = dir.join("cast_last_used.json");

        save_last_used(&path, &device("device-1", "192.0.2.10").id);
        assert_eq!(load_last_used(&path), Some("device-1".to_string()));

        // Casting to another device replaces the hint rather than appending.
        save_last_used(&path, &device("device-2", "192.0.2.11").id);
        assert_eq!(load_last_used(&path), Some("device-2".to_string()));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_missing_or_unreadable_last_used_file_remembers_nothing() {
        let dir = scratch_dir("cast-last-used-missing");
        let path = dir.join("cast_last_used.json");
        assert_eq!(load_last_used(&path), None);

        // Corruption and an empty id both degrade to "nothing remembered".
        std::fs::write(&path, b"not json").unwrap();
        assert_eq!(load_last_used(&path), None);
        std::fs::write(
            &path,
            serde_json::to_vec(&LastUsedDevice {
                device_id: String::new(),
            })
            .unwrap(),
        )
        .unwrap();
        assert_eq!(load_last_used(&path), None);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_last_used_device_lives_in_the_plugin_state_dir() {
        assert_eq!(
            last_used_path(),
            crate::auth::AuthManager::state_dir().join("cast_last_used.json")
        );
    }

    #[test]
    fn an_unreachable_device_moves_to_the_bottom_then_disappears() {
        let start = Instant::now();
        let mut since = HashMap::new();
        let devices = vec![
            device("a", "192.0.2.1"),
            device("b", "192.0.2.2"),
            device("c", "192.0.2.3"),
        ];
        let ids = |visible: &[super::VisibleDevice]| -> Vec<String> {
            visible.iter().map(|entry| entry.device.id.clone()).collect()
        };

        // Reachable devices keep the alphabetical order; the failing one is
        // dimmed and moved to the bottom.
        let first = fold_presence(
            devices.clone(),
            vec![true, false, true],
            None,
            &mut since,
            start,
        );
        assert_eq!(ids(&first), ["a", "c", "b"]);
        assert!(!first[2].available);

        // Still listed just before the grace ends...
        let before = fold_presence(
            devices.clone(),
            vec![true, false, true],
            None,
            &mut since,
            start + UNAVAILABLE_GRACE - Duration::from_secs(1),
        );
        assert_eq!(before.len(), 3);

        // ...and dropped once it has been unavailable for a minute.
        let after = fold_presence(
            devices.clone(),
            vec![true, false, true],
            None,
            &mut since,
            start + UNAVAILABLE_GRACE + Duration::from_secs(1),
        );
        assert_eq!(ids(&after), ["a", "c"]);

        // A later successful probe brings it back at once, in order, and
        // clears the grace state.
        let back = fold_presence(
            devices,
            vec![true, true, true],
            None,
            &mut since,
            start + UNAVAILABLE_GRACE + Duration::from_secs(2),
        );
        assert_eq!(ids(&back), ["a", "b", "c"]);
        assert!(since.is_empty());
    }

    #[test]
    fn a_live_cast_session_keeps_its_device_available() {
        let mut since = HashMap::new();
        let visible = fold_presence(
            vec![device("a", "192.0.2.1")],
            vec![false],
            Some("a"),
            &mut since,
            Instant::now(),
        );
        assert!(visible[0].available);
        assert!(since.is_empty());
    }

    #[tokio::test]
    async fn the_cast_port_probe_separates_a_listening_port_from_a_closed_one() {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let accept = tokio::spawn(async move {
            let _ = listener.accept().await;
        });
        assert!(probe_cast_port("127.0.0.1", port).await);
        accept.await.unwrap();
        // The listener task drops the socket, so the port is closed now.
        assert!(!probe_cast_port("127.0.0.1", port).await);
    }

    #[test]
    fn stream_blocked_requires_a_live_receiver_and_an_unfetched_accepted_load() {
        let loaded = 10_000;
        let past_grace = loaded + STREAM_BLOCKED_AFTER_MS + 1;

        // Genuine firewall block: live bridge, live receiver app, accepted
        // LOAD past grace, and no fetch since `loaded`.
        assert!(is_stream_blocked(true, true, loaded, 0, past_grace));
        assert!(is_stream_blocked(true, true, loaded, loaded - 1, past_grace));

        // Still inside grace window: not blocked yet.
        assert!(!is_stream_blocked(
            true,
            true,
            loaded,
            0,
            loaded + STREAM_BLOCKED_AFTER_MS
        ));

        // Receiver fetched the manifest (at or after `loaded`): open.
        assert!(!is_stream_blocked(true, true, loaded, loaded, past_grace));
        assert!(!is_stream_blocked(true, true, loaded, loaded + 50, past_grace));

        // Dead bridge, closed receiver app, or no accepted LOAD (e.g. a failed
        // LOAD never stored `loaded_at_ms`): never blame the firewall.
        assert!(!is_stream_blocked(false, true, loaded, 0, past_grace));
        assert!(!is_stream_blocked(true, false, loaded, 0, past_grace));
        assert!(!is_stream_blocked(true, true, 0, 0, past_grace));
    }
}
