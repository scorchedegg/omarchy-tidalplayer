//! One CastV2 connection: TLS to the device's port 8009, a framed protobuf
//! writer, a reader that answers heartbeats and tracks media state, and a
//! one-second status poll so the UI's playhead follows the device.

use super::media::now_ms;
use super::protocol::{
    self, CastMessage, DEFAULT_RECEIVER, NS_CONNECTION, NS_HEARTBEAT, NS_MEDIA,
    NS_RECEIVER, RECEIVER_ID,
};
use crate::mpv::PlaybackState;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot, Mutex, Notify};
use tracing::{debug, info, warn};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

/// What the bridge reported to the playback loop.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CastEvent {
    /// The receiver ran the stream to its end (`IDLE`/`FINISHED`): the queue
    /// advances.
    Finished,
    /// The connection died on its own — a device reboot, a network drop or a
    /// system suspend. The session cannot be commanded any more and must be
    /// torn down before anyone touches the transport again. A deliberate
    /// `close()` never produces this.
    Dropped,
}

/// A Cast receiver answers its control port in milliseconds. This bounds the
/// TCP + TLS setup: without it a device that vanished between the probe and
/// the click leaves the sheet on "Connecting..." for the kernel's SYN timeout,
/// which is over two minutes.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(5);
const STATUS_POLL_INTERVAL: Duration = Duration::from_secs(1);
/// How long the device may stay silent before the connection counts as dead.
/// A power-pulled receiver leaves a half-open socket that never errors, so
/// silence is the only sign it is gone: the device answers the 1 s status
/// polls and sends its own heartbeats every few seconds, so ten seconds of
/// nothing means it stopped listening — long enough to ride out a Wi-Fi
/// hiccup, short enough to notice before the user does.
const SILENCE_LIMIT: Duration = Duration::from_secs(10);
const MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;

/// How far below the requested start a receiver sample may sit and still
/// count as that stream. A receiver reports `currentTime: 0` while it opens a
/// mid-track manifest, and a status already in flight can still describe the
/// pre-seek playhead.
const HOLD_TOLERANCE: f64 = 1.0;
/// How much the receiver's clock must advance between two samples before the
/// local clock may run from it. A receiver answers `PLAYING` at the start
/// position while the manifest is still opening, so the first plausible
/// sample is only a probe; the second proves audio is actually running.
const HOLD_ADVANCE: f64 = 0.2;

/// A playhead freeze while a track is handed to the receiver or a seek is
/// sent. The receiver needs one to three seconds to open a DASH manifest and
/// acknowledge the command, and a clock started before that runs ahead of the
/// audio, then has to snap back on the next device sample — or, visibly, when
/// the user pauses.
#[derive(Debug, Clone, Copy)]
struct Hold {
    /// Where the stream is expected to start (or resume).
    expected: f64,
    /// When the hold began; the upper edge of the window widens as the
    /// receiver's own clock advances.
    since: Instant,
    /// The first plausible sample from the receiver.
    sample: Option<f64>,
}

/// What the receiver reports about the stream it is playing. `position` is the
/// device's clock inside the current stream, so the track position is the
/// stream offset plus this value.
#[derive(Debug, Clone, Default)]
pub struct MediaInfo {
    pub player_state: String,
    pub position: f64,
    /// The anchor for the local clock: set only by a device sample that proves
    /// the receiver's clock is running. `None` freezes `position`.
    pub updated: Option<Instant>,
    pub duration: f64,
    pub media_session_id: Option<i64>,
    pub idle_reason: Option<String>,
    hold: Option<Hold>,
}

impl MediaInfo {
    /// Advances between polls while the receiver is playing and its clock has
    /// been confirmed running.
    pub fn live_position(&self) -> f64 {
        if self.player_state == "PLAYING" {
            self.position + self.updated.map(|at| at.elapsed().as_secs_f64()).unwrap_or(0.0)
        } else {
            self.position
        }
    }

    /// Freezes the playhead at `position` until the receiver reports that its
    /// own clock is running. Called when a track is handed over and when a
    /// seek is sent.
    pub fn hold_at(&mut self, position: f64) {
        let position = if position.is_finite() {
            position.max(0.0)
        } else {
            0.0
        };
        self.position = position;
        self.updated = None;
        self.hold = Some(Hold {
            expected: position,
            since: Instant::now(),
            sample: None,
        });
    }

    /// Drops the hold without starting a clock: the next receiver sample
    /// re-anchors it. Used when a LOAD was abandoned and the previous stream
    /// is still what the device is playing.
    pub fn release_hold(&mut self) {
        self.hold = None;
        self.updated = None;
    }

    /// True while the playhead is waiting for the receiver to start, resume
    /// or complete a seek.
    pub fn awaiting_start(&self) -> bool {
        self.hold.is_some()
    }

    /// The transport state the receiver reports. Our own commands set it
    /// optimistically in `mark_playing`/`mark_paused`/`mark_stopped`, but the
    /// device is the authority: a pause, resume or stop made on the receiver
    /// (or by another sender) has to reach MPRIS and the panel exactly like
    /// one of ours. There is deliberately no session-level mirror of this.
    pub fn playback_state(&self) -> PlaybackState {
        match self.player_state.as_str() {
            "PLAYING" => PlaybackState::Playing,
            "PAUSED" => PlaybackState::Paused,
            _ => PlaybackState::Stopped,
        }
    }

    /// Whether a receiver sample may move the playhead at all. While held,
    /// the window rejects the pre-start zero and statuses from before the
    /// seek; without a hold every sample is the clock.
    fn plausible(&self, time: f64) -> bool {
        if time <= 0.0 && self.position > HOLD_TOLERANCE {
            return false;
        }
        let Some(hold) = self.hold else {
            return true;
        };
        let elapsed = hold.since.elapsed().as_secs_f64();
        // The window's upper edge is where the device's clock could honestly
        // be now: the wait so far plus at most one poll interval, since the
        // stream may have started just before the sample was taken.
        let ahead = elapsed + STATUS_POLL_INTERVAL.as_secs_f64() + HOLD_ADVANCE;
        time >= hold.expected - HOLD_TOLERANCE && time <= hold.expected + ahead
    }

    /// Whether a `PLAYING` sample may anchor the clock. While held, the first
    /// plausible sample only records where the receiver says it is; the clock
    /// starts when a later sample shows that position advancing.
    fn takes_playing_sample(&mut self, time: f64) -> bool {
        if !self.plausible(time) {
            return false;
        }
        let Some(hold) = self.hold else {
            return true;
        };
        match hold.sample {
            Some(previous) if time >= previous + HOLD_ADVANCE => {
                self.hold = None;
                true
            }
            _ => {
                if let Some(hold) = self.hold.as_mut() {
                    hold.sample = Some(time);
                }
                false
            }
        }
    }

    /// Resumes a paused timeline without moving the frozen position. The
    /// clock waits for the receiver: a `PLAY` is acknowledged before audio
    /// actually restarts.
    fn mark_playing(&mut self) {
        let position = self.live_position();
        self.player_state = "PLAYING".to_string();
        self.idle_reason = None;
        self.hold_at(position);
    }

    fn mark_paused(&mut self) {
        self.position = self.live_position();
        self.hold = None;
        self.player_state = "PAUSED".to_string();
        self.updated = None;
    }

    fn mark_stopped(&mut self) {
        self.position = 0.0;
        self.hold = None;
        self.player_state = "IDLE".to_string();
        self.updated = None;
    }

    /// The receiver app exited (idle timeout, voice stop, crash, or another
    /// app took over) while the Cast control connection to the device stayed
    /// open. Park the playhead at its last known position and drop the dead
    /// media session so the next Play or track change relaunches cleanly.
    fn mark_app_closed(&mut self) {
        self.position = self.live_position();
        self.hold = None;
        self.updated = None;
        self.media_session_id = None;
        self.player_state = "IDLE".to_string();
        self.idle_reason = None;
    }
}

struct LoadRequest<'a> {
    url: &'a str,
    content_type: &'a str,
    stream_type: &'a str,
    title: &'a str,
    artist: &'a str,
    start_at: f64,
}

pub struct Bridge {
    tx: mpsc::UnboundedSender<CastMessage>,
    pending: Arc<Mutex<HashMap<u32, oneshot::Sender<Value>>>>,
    pub media: Arc<parking_lot::RwLock<MediaInfo>>,
    pub volume: Arc<parking_lot::RwLock<f64>>,
    /// False until the device has actually reported its level. Casting starts
    /// on the device's own volume, so a default of 1.0 must not be mistaken for
    /// a real reading.
    volume_known: Arc<AtomicBool>,
    transport_id: Arc<parking_lot::RwLock<Option<String>>>,
    session_id: Arc<parking_lot::RwLock<Option<String>>>,
    /// The `requestId` of the latest `LAUNCH`, so a `RECEIVER_STATUS` reply to
    /// an earlier poll cannot clear a freshly launched receiver transport.
    launch_request_id: Arc<AtomicU32>,
    /// Serialises receiver launches so concurrent callers cannot race `STOP`
    /// and `LAUNCH` against each other.
    launch_lock: Arc<Mutex<()>>,
    request_counter: Arc<AtomicU32>,
    alive: Arc<AtomicBool>,
    shutdown: Arc<Notify>,
    eos_signaled: Arc<AtomicBool>,
    /// The receiver reported IDLE/ERROR for the current LOAD.
    failed: Arc<AtomicBool>,
}

impl Bridge {
    pub async fn connect(
        host: &str,
        port: u16,
        events: mpsc::UnboundedSender<CastEvent>,
    ) -> Result<Arc<Self>, String> {
        let tls = connect_transport(host, port, CONNECT_TIMEOUT).await?;
        let (mut reader, mut writer) = tokio::io::split(tls);

        let (tx, mut rx) = mpsc::unbounded_channel::<CastMessage>();
        let pending: Arc<Mutex<HashMap<u32, oneshot::Sender<Value>>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let media = Arc::new(parking_lot::RwLock::new(MediaInfo::default()));
        let volume = Arc::new(parking_lot::RwLock::new(1.0));
        let volume_known = Arc::new(AtomicBool::new(false));
        let transport_id = Arc::new(parking_lot::RwLock::new(None::<String>));
        let session_id = Arc::new(parking_lot::RwLock::new(None::<String>));
        let launch_request_id = Arc::new(AtomicU32::new(0));
        let launch_lock = Arc::new(Mutex::new(()));
        let request_counter = Arc::new(AtomicU32::new(0));
        let alive = Arc::new(AtomicBool::new(true));
        let shutdown = Arc::new(Notify::new());
        let eos_signaled = Arc::new(AtomicBool::new(false));
        let failed = Arc::new(AtomicBool::new(false));
        // Any frame from the device proves it is there. Silence is how a
        // power-pulled receiver is caught: the socket stays half-open and
        // never errors, so nothing else notices it is gone.
        let last_seen = Arc::new(AtomicU64::new(now_ms()));

        let writer_alive = alive.clone();
        let writer_events = events.clone();
        let writer_shutdown = shutdown.clone();
        let poll_events = events.clone();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    biased;
                    message = rx.recv() => {
                        let Some(message) = message else {
                            break;
                        };
                        let frame = protocol::encode_frame(&message);
                        if let Err(error) = writer.write_all(&frame).await {
                            debug!("Cast writer stopped: {error}");
                            if writer_alive.swap(false, Ordering::SeqCst) {
                                let _ = writer_events.send(CastEvent::Dropped);
                            }
                            break;
                        }
                    }
                    _ = writer_shutdown.notified() => {
                        // Drain any final STOP/CLOSE frames queued right before shutdown.
                        while let Ok(message) = rx.try_recv() {
                            let frame = protocol::encode_frame(&message);
                            if writer.write_all(&frame).await.is_err() {
                                break;
                            }
                        }
                        let _ = writer.shutdown().await;
                        break;
                    }
                }
            }
        });

        let reader_tx = tx.clone();
        let reader_pending = pending.clone();
        let reader_media = media.clone();
        let reader_volume = volume.clone();
        let reader_volume_known = volume_known.clone();
        let reader_transport = transport_id.clone();
        let reader_launch_request_id = launch_request_id.clone();
        let reader_alive = alive.clone();
        let reader_shutdown = shutdown.clone();
        let reader_last_seen = last_seen.clone();
        let reader_eos_signaled = eos_signaled.clone();
        let reader_failed = failed.clone();
        tokio::spawn(async move {
            loop {
                let mut header = [0u8; 4];
                let header_read = tokio::select! {
                    _ = reader_shutdown.notified() => break,
                    res = reader.read_exact(&mut header) => res,
                };
                if header_read.is_err() {
                    break;
                }
                let length = u32::from_be_bytes(header) as usize;
                if length == 0 || length > MAX_FRAME_BYTES {
                    break;
                }
                let mut buffer = vec![0u8; length];
                let body_read = tokio::select! {
                    _ = reader_shutdown.notified() => break,
                    res = reader.read_exact(&mut buffer) => res,
                };
                if body_read.is_err() {
                    break;
                }
                // Any frame proves the device is still there.
                reader_last_seen.store(now_ms(), Ordering::SeqCst);
                let Ok(message) = protocol::decode(&buffer) else {
                    continue;
                };
                let Some(payload) = message.payload() else {
                    continue;
                };
                if message.namespace == NS_HEARTBEAT {
                    if payload.get("type").and_then(|value| value.as_str()) == Some("PING") {
                        let _ = reader_tx.send(CastMessage::new(
                            &message.source_id,
                            NS_HEARTBEAT,
                            protocol::pong_payload(),
                        ));
                    }
                    continue;
                }
                if message.namespace == NS_CONNECTION
                    && payload.get("type").and_then(Value::as_str) == Some("CLOSE")
                {
                    if message.source_id == RECEIVER_ID {
                        warn!("Cast device closed the control connection");
                        break;
                    }
                    if clear_closed_transport(&reader_transport, &reader_media, &message.source_id)
                    {
                        info!("Cast receiver app closed ({})", message.source_id);
                    }
                    continue;
                }
                if message.namespace == NS_MEDIA {
                    if let Some(status) = payload.get("status").and_then(Value::as_array) {
                        if let Some(first) = status.first() {
                            let before = {
                                let media = reader_media.read();
                                (
                                    media.player_state.clone(),
                                    media.idle_reason.clone(),
                                )
                            };
                            apply_media_status(&reader_media, first);
                            debug!("Cast media status: {first}");
                            let after = {
                                let media = reader_media.read();
                                (
                                    media.player_state.clone(),
                                    media.idle_reason.clone(),
                                )
                            };
                            if before != after {
                                info!("Cast receiver state: {:?}", after);
                            }
                            // FINISHED advances the queue; ERROR means the
                            // receiver could not play the stream, so park the
                            // session instead of skipping every few seconds.
                            if first.get("playerState").and_then(Value::as_str) == Some("IDLE") {
                                match first.get("idleReason").and_then(Value::as_str) {
                                    Some("FINISHED")
                                        if !reader_eos_signaled.swap(true, Ordering::SeqCst) =>
                                    {
                                        let _ = events.send(CastEvent::Finished);
                                    }
                                    Some("ERROR")
                                        if !reader_failed.swap(true, Ordering::SeqCst) =>
                                    {
                                        tracing::warn!(
                                            "Cast receiver failed to play the stream"
                                        );
                                    }
                                    _ => {}
                                }
                            }
                        }
                    }
                }
                if message.namespace == NS_RECEIVER {
                    if let Some(level) = payload
                        .get("status")
                        .and_then(|status| status.get("volume"))
                        .and_then(|volume| volume.get("level"))
                        .and_then(Value::as_f64)
                    {
                        *reader_volume.write() = level;
                        reader_volume_known.store(true, Ordering::SeqCst);
                    }
                    let response_id = payload
                        .get("requestId")
                        .and_then(Value::as_u64)
                        .unwrap_or(0) as u32;
                    let min_id = reader_launch_request_id.load(Ordering::SeqCst);
                    if response_id == 0 || response_id >= min_id {
                        if let Some(closed) = sync_receiver_applications(
                            &reader_transport,
                            &reader_media,
                            &payload,
                        ) {
                            info!("Cast receiver app is no longer running ({closed})");
                        }
                    }
                }
                if let Some(request_id) = payload.get("requestId").and_then(Value::as_u64) {
                    let waiter = reader_pending
                        .lock()
                        .await
                        .remove(&(request_id as u32));
                    if let Some(waiter) = waiter {
                        let _ = waiter.send(payload);
                    }
                }
            }
            // The socket is gone: every in-flight request must fail instead of
            // waiting for its timeout. If `close()` has not already claimed
            // the shutdown, the connection died on its own and the session
            // must be torn down.
            if reader_alive.swap(false, Ordering::SeqCst) {
                let _ = events.send(CastEvent::Dropped);
            }
            reader_shutdown.notify_waiters();
            reader_pending.lock().await.clear();
        });

        let bridge = Arc::new(Self {
            tx: tx.clone(),
            pending,
            media: media.clone(),
            volume,
            volume_known,
            transport_id: transport_id.clone(),
            session_id,
            launch_request_id,
            launch_lock,
            request_counter: request_counter.clone(),
            alive: alive.clone(),
            shutdown: shutdown.clone(),
            eos_signaled,
            failed,
        });

        // `receiver-0` is always present; the connection namespace needs a
        // CONNECT before it will deliver status.
        bridge.send(CastMessage::new(
            RECEIVER_ID,
            NS_CONNECTION,
            protocol::connect_payload(),
        ))?;

        // Heartbeat: the device drops a sender that goes quiet.
        let heartbeat_tx = tx.clone();
        let heartbeat_alive = alive.clone();
        let heartbeat_shutdown = shutdown.clone();
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(HEARTBEAT_INTERVAL);
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                tokio::select! {
                    _ = heartbeat_shutdown.notified() => return,
                    _ = ticker.tick() => {}
                }
                if !heartbeat_alive.load(Ordering::SeqCst) {
                    return;
                }
                if heartbeat_tx
                    .send(CastMessage::new(
                        RECEIVER_ID,
                        NS_HEARTBEAT,
                        protocol::ping_payload(),
                    ))
                    .is_err()
                {
                    return;
                }
            }
        });

        // Status poll: the only source of an accurate playhead, and it keeps
        // `mediaSessionId` fresh for transport commands.
        let poll_tx = tx;
        let poll_alive = alive;
        let poll_shutdown = shutdown;
        let poll_last_seen = last_seen;
        let poll_transport = transport_id;
        let poll_media = media;
        let poll_counter = request_counter;
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(STATUS_POLL_INTERVAL);
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                tokio::select! {
                    _ = poll_shutdown.notified() => return,
                    _ = ticker.tick() => {}
                }
                if !poll_alive.load(Ordering::SeqCst) {
                    return;
                }
                // Silence means the device is gone even though the socket
                // never errored (a power-pulled receiver leaves it half
                // open). Declaring the drop here bounds how long the panel
                // can keep claiming a session that cannot be commanded.
                if now_ms().saturating_sub(poll_last_seen.load(Ordering::SeqCst))
                    > SILENCE_LIMIT.as_millis() as u64
                {
                    warn!("Cast device stopped answering; dropping the connection");
                    if poll_alive.swap(false, Ordering::SeqCst) {
                        let _ = poll_events.send(CastEvent::Dropped);
                    }
                    poll_shutdown.notify_waiters();
                    return;
                }
                // Only poll NS_MEDIA while a receiver app is running; always
                // poll NS_RECEIVER so device volume and connection liveness
                // stay fresh even after the receiver app idles out.
                if let Some(transport) = poll_transport.read().clone() {
                    let id = poll_counter.fetch_add(1, Ordering::SeqCst) + 1;
                    let session = poll_media.read().media_session_id;
                    if poll_tx
                        .send(CastMessage::new(
                            &transport,
                            NS_MEDIA,
                            protocol::media_status_payload(id, session),
                        ))
                        .is_err()
                    {
                        return;
                    }
                }
                let id = poll_counter.fetch_add(1, Ordering::SeqCst) + 1;
                if poll_tx
                    .send(CastMessage::new(
                        RECEIVER_ID,
                        NS_RECEIVER,
                        protocol::receiver_status_payload(id),
                    ))
                    .is_err()
                {
                    return;
                }
            }
        });

        Ok(bridge)
    }

    pub fn is_alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }

    /// True when the receiver reported IDLE/ERROR for the current stream.
    pub fn has_failed(&self) -> bool {
        self.failed.load(Ordering::SeqCst)
    }

    fn send(&self, message: CastMessage) -> Result<(), String> {
        if !self.alive.load(Ordering::SeqCst) {
            return Err("the cast device connection is closed".to_string());
        }
        self.tx
            .send(message)
            .map_err(|_| "the cast device connection is closed".to_string())
    }

    fn next_request_id(&self) -> u32 {
        self.request_counter.fetch_add(1, Ordering::SeqCst) + 1
    }

    async fn request(
        &self,
        namespace: &str,
        destination: &str,
        payload: Value,
        request_id: u32,
    ) -> Result<Value, String> {
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(request_id, tx);
        if let Err(error) = self.send(CastMessage::new(destination, namespace, payload)) {
            self.pending.lock().await.remove(&request_id);
            return Err(error);
        }
        match tokio::time::timeout(REQUEST_TIMEOUT, rx).await {
            Ok(Ok(payload)) => Ok(payload),
            Ok(Err(_)) => Err("the cast device closed the connection".to_string()),
            Err(_) => {
                self.pending.lock().await.remove(&request_id);
                Err("the cast device did not answer".to_string())
            }
        }
    }

    pub fn transport(&self) -> Option<String> {
        self.transport_id.read().clone()
    }

    /// Starts the Default Media Receiver and returns its transport id.
    pub async fn launch_receiver(&self) -> Result<String, String> {
        let _guard = self.launch_lock.lock().await;
        // Clear any dead transport before stopping/launching so intermediate
        // RECEIVER_STATUS messages cannot race with the relaunch.
        *self.transport_id.write() = None;
        // A previous daemon may have died without stopping its receiver. A
        // stale instance answers the new LOAD with IDLE and never plays, so
        // always start from a clean app.
        let stop_id = self.next_request_id();
        let _ = self
            .request(
                NS_RECEIVER,
                RECEIVER_ID,
                protocol::stop_app_payload(stop_id, DEFAULT_RECEIVER),
                stop_id,
            )
            .await;
        let request_id = self.next_request_id();
        self.launch_request_id.store(request_id, Ordering::SeqCst);
        let reply = self
            .request(
                NS_RECEIVER,
                RECEIVER_ID,
                protocol::launch_payload(request_id, DEFAULT_RECEIVER),
                request_id,
            )
            .await?;
        if reply.get("type").and_then(Value::as_str) == Some("LAUNCH_ERROR") {
            return Err(reply
                .get("reason")
                .and_then(Value::as_str)
                .unwrap_or("the device refused to start a receiver")
                .to_string());
        }
        let app = reply
            .get("status")
            .and_then(|status| status.get("applications"))
            .and_then(Value::as_array)
            .and_then(|apps| {
                apps.iter()
                    .find(|app| app.get("appId").and_then(Value::as_str) == Some(DEFAULT_RECEIVER))
                    .or_else(|| apps.first())
            });
        let transport = app
            .and_then(|app| app.get("transportId"))
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| "the device did not start a receiver".to_string())?;
        let app_session_id = app
            .and_then(|app| app.get("sessionId"))
            .and_then(Value::as_str)
            .map(str::to_string);
        if let Some(level) = reply
            .get("status")
            .and_then(|status| status.get("volume"))
            .and_then(|volume| volume.get("level"))
            .and_then(Value::as_f64)
        {
            *self.volume.write() = level;
            self.volume_known.store(true, Ordering::SeqCst);
        }
        self.send(CastMessage::new(
            &transport,
            NS_CONNECTION,
            protocol::connect_payload(),
        ))?;
        *self.transport_id.write() = Some(transport.clone());
        *self.session_id.write() = app_session_id;
        info!("Cast receiver launched on transport {transport}");
        Ok(transport)
    }

    /// Hands the receiver the manifest URL and returns the monotonic-ms when
    /// the accepted `LOAD` was sent. Resets the end-of-stream latch. `BUFFERED`
    /// (not `LIVE`) is what makes the receiver treat the track as a finite,
    /// seekable asset. If the receiver app exited while the device stayed
    /// connected, relaunches Default Media Receiver automatically.
    pub async fn load(
        &self,
        url: &str,
        content_type: &str,
        stream_type: &str,
        title: &str,
        artist: &str,
        start_at: f64,
    ) -> Result<u64, String> {
        let start_at = if start_at.is_finite() {
            start_at.max(0.0)
        } else {
            0.0
        };
        let req = LoadRequest {
            url,
            content_type,
            stream_type,
            title,
            artist,
            start_at,
        };
        let mut relaunched = false;
        let transport = match self.transport() {
            Some(transport) => transport,
            None => {
                info!("Cast receiver app is not running; launching Default Media Receiver");
                relaunched = true;
                self.launch_receiver().await?
            }
        };
        match self.load_on_transport(&transport, &req).await {
            Ok(sent_at_ms) => Ok(sent_at_ms),
            Err(first_error)
                if !relaunched
                    && self.is_alive()
                    && should_relaunch_on_load_error(&first_error) =>
            {
                warn!(
                    "Cast LOAD failed on existing receiver ({first_error}); relaunching Default Media Receiver"
                );
                let fresh_transport = self.launch_receiver().await?;
                self.load_on_transport(&fresh_transport, &req).await
            }
            Err(error) => Err(error),
        }
    }

    async fn load_on_transport(&self, transport: &str, req: &LoadRequest<'_>) -> Result<u64, String> {
        self.eos_signaled.store(false, Ordering::SeqCst);
        self.failed.store(false, Ordering::SeqCst);
        // Stamped right before this LOAD attempt: any manifest fetch triggered
        // by this LOAD lands at or after this instant, and an earlier timed-out
        // attempt cannot eat into the firewall-detection grace window.
        let sent_at_ms = now_ms();
        let request_id = self.next_request_id();
        let reply = self
            .request(
                NS_MEDIA,
                transport,
                protocol::load_payload(
                    request_id,
                    req.url,
                    req.content_type,
                    req.stream_type,
                    req.title,
                    req.artist,
                    req.start_at,
                ),
                request_id,
            )
            .await?;
        match reply.get("type").and_then(Value::as_str) {
            Some("LOAD_FAILED") | Some("INVALID_REQUEST") | Some("INVALID_MEDIA_SESSION_ID") => {
                let fallback = if reply.get("type").and_then(Value::as_str)
                    == Some("INVALID_MEDIA_SESSION_ID")
                {
                    "INVALID_MEDIA_SESSION_ID"
                } else {
                    "the device rejected the stream"
                };
                return Err(reply
                    .get("reason")
                    .and_then(Value::as_str)
                    .or_else(|| reply.get("detailedErrorCode").and_then(Value::as_str))
                    .unwrap_or(fallback)
                    .to_string());
            }
            _ => {}
        }
        let status = reply
            .get("status")
            .and_then(|value| value.as_array())
            .and_then(|status| status.first());
        let reply_type = reply
            .get("type")
            .and_then(|value| value.as_str())
            .unwrap_or("MEDIA_STATUS");
        let reply_state = status
            .and_then(|status| status.get("playerState"))
            .and_then(|value| value.as_str())
            .unwrap_or("?");
        let reply_idle = status
            .and_then(|status| status.get("idleReason"))
            .and_then(|value| value.as_str())
            .unwrap_or("-");
        if reply_state == "IDLE" && reply_idle == "ERROR" {
            self.failed.store(true, Ordering::SeqCst);
            return Err("the receiver failed to play the stream".to_string());
        }
        info!("Cast LOAD accepted (type={reply_type}, state={reply_state}, idle={reply_idle})");
        {
            let mut media = self.media.write();
            // The LOAD reply only means the receiver accepted the URL, not
            // that audio is running. Hold the playhead at the requested start
            // and let the receiver's clock prove it (a DASH manifest takes one
            // to three seconds to open). `apply_media_status` below may
            // already carry a first sample, but it cannot anchor the clock
            // until the device shows that sample advancing.
            media.hold_at(req.start_at);
            media.player_state = "PLAYING".to_string();
            media.idle_reason = None;
        }
        if let Some(status) = status {
            // A DASH track reports a real duration and currentTime, so the
            // receiver's own timeline is trustworthy; keep it instead of
            // running a local clock.
            apply_media_status(&self.media, status);
        }
        debug!("Cast receiver loaded {}", req.url);
        Ok(sent_at_ms)
    }

    /// Seeks the receiver's own timeline. The manifest is a finite asset, so
    /// this is a real seek rather than a re-`LOAD`. If the receiver app has
    /// closed, parks the target position so the next Play resumes there.
    pub fn seek(&self, seconds: f64) {
        if !seconds.is_finite() {
            return;
        }
        let target = seconds.max(0.0);
        let Some(transport) = self.transport() else {
            let mut media = self.media.write();
            media.position = target;
            media.hold = None;
            media.updated = None;
            return;
        };
        let request_id = self.next_request_id();
        let session = self.media.read().media_session_id;
        if let Err(error) = self.send(CastMessage::new(
            &transport,
            NS_MEDIA,
            protocol::seek_payload(request_id, session, target),
        )) {
            warn!("Cast SEEK was not sent: {error}");
            return;
        }
        // The receiver acknowledges the SEEK before its clock reaches the
        // target; hold the playhead there until the device confirms it.
        self.media.write().hold_at(target);
    }

    /// Drops a hand-off hold when the LOAD was abandoned: the previous stream
    /// is still the device's, and the status poll will re-anchor the clock.
    pub fn release_hold(&self) {
        self.media.write().release_hold();
    }

    /// Marks the transport as loading before a `LOAD`. A stopped receiver has
    /// no media session left to command and a receiver only reports `IDLE`
    /// until the new manifest is accepted, so the state is set here and the
    /// playhead held at `position`; without it MPRIS and the panel would show
    /// Stopped for the whole manifest fetch, including between cast tracks.
    pub fn mark_loading(&self, position: f64) {
        let mut media = self.media.write();
        media.hold_at(position);
        media.player_state = "PLAYING".to_string();
        media.idle_reason = None;
    }

    /// A resume LOAD failed: the receiver has nothing loaded, so report it
    /// stopped. The playhead stays where the hand-off was attempted, so a
    /// second Play retries from there instead of jumping to zero.
    pub fn mark_resume_failed(&self) {
        let mut media = self.media.write();
        media.hold = None;
        media.updated = None;
        media.player_state = "IDLE".to_string();
    }

    /// True while the playhead is waiting for the receiver to start, resume
    /// or land a seek.
    pub fn awaiting_start(&self) -> bool {
        self.media.read().awaiting_start()
    }

    pub fn play(&self) {
        let Some(transport) = self.transport() else {
            return;
        };
        let request_id = self.next_request_id();
        let session = self.media.read().media_session_id;
        if let Err(error) = self.send(CastMessage::new(
            &transport,
            NS_MEDIA,
            protocol::media_command_payload("PLAY", request_id, session),
        )) {
            warn!("Cast PLAY was not sent: {error}");
            return;
        }
        self.media.write().mark_playing();
    }

    pub fn pause(&self) {
        let Some(transport) = self.transport() else {
            return;
        };
        let request_id = self.next_request_id();
        let session = self.media.read().media_session_id;
        if let Err(error) = self.send(CastMessage::new(
            &transport,
            NS_MEDIA,
            protocol::media_command_payload("PAUSE", request_id, session),
        )) {
            warn!("Cast PAUSE was not sent: {error}");
            return;
        }
        self.media.write().mark_paused();
    }

    pub fn stop(&self) {
        let Some(transport) = self.transport() else {
            return;
        };
        let request_id = self.next_request_id();
        let session = self.media.read().media_session_id;
        if let Err(error) = self.send(CastMessage::new(
            &transport,
            NS_MEDIA,
            protocol::media_command_payload("STOP", request_id, session),
        )) {
            warn!("Cast STOP was not sent: {error}");
            return;
        }
        self.media.write().mark_stopped();
    }

    pub fn set_volume(&self, level: f64) {
        if !level.is_finite() {
            return;
        }
        let level = level.clamp(0.0, 1.0);
        let request_id = self.next_request_id();
        if let Err(error) = self.send(CastMessage::new(
            RECEIVER_ID,
            NS_RECEIVER,
            protocol::set_volume_payload(request_id, level),
        )) {
            warn!("Cast volume was not sent: {error}");
            return;
        }
        *self.volume.write() = level;
        self.volume_known.store(true, Ordering::SeqCst);
    }

    /// The receiver's own level, or `None` before it has told us one.
    pub fn volume(&self) -> Option<f64> {
        if self.volume_known.load(Ordering::SeqCst) {
            Some(*self.volume.read())
        } else {
            None
        }
    }

    /// Leaves the receiver and closes the connection. Sends STOP before CLOSE
    /// so the receiver exits the Default Media Receiver cleanly, then notifies
    /// the reader/writer/poller tasks so the TLS socket and tasks unwind.
    pub fn close(&self) {
        self.alive.store(false, Ordering::SeqCst);
        let stop_payload = match self.session_id.read().clone() {
            Some(session_id) => json!({
                "type": "STOP",
                "requestId": self.next_request_id(),
                "sessionId": session_id,
            }),
            None => json!({
                "type": "STOP",
                "requestId": self.next_request_id(),
            }),
        };
        let _ = self.tx.send(CastMessage::new(
            RECEIVER_ID,
            NS_RECEIVER,
            stop_payload,
        ));
        if let Some(transport) = self.transport() {
            let _ = self.tx.send(CastMessage::new(
                &transport,
                NS_CONNECTION,
                protocol::close_payload(),
            ));
        }
        let _ = self.tx.send(CastMessage::new(
            RECEIVER_ID,
            NS_CONNECTION,
            protocol::close_payload(),
        ));
        self.shutdown.notify_waiters();
    }
}

/// Clears the active media transport when its `CLOSE` arrives over
/// `NS_CONNECTION` and parks media state so the next `load()` relaunches.
fn clear_closed_transport(
    transport: &Arc<parking_lot::RwLock<Option<String>>>,
    media: &Arc<parking_lot::RwLock<MediaInfo>>,
    source_id: &str,
) -> bool {
    let mut guard = transport.write();
    if guard.as_deref() != Some(source_id) {
        return false;
    }
    *guard = None;
    drop(guard);
    media.write().mark_app_closed();
    true
}

/// Checks a `RECEIVER_STATUS` payload against our active media transport. If
/// the receiver app is no longer listed in `status.applications` (idle
/// timeout, voice stop, crash, or another app taking over), clears the dead
/// transport and parks media state so `load()` relaunches instead of timing
/// out against a closed transport id.
fn sync_receiver_applications(
    transport: &Arc<parking_lot::RwLock<Option<String>>>,
    media: &Arc<parking_lot::RwLock<MediaInfo>>,
    payload: &Value,
) -> Option<String> {
    if payload.get("type").and_then(Value::as_str) != Some("RECEIVER_STATUS") {
        return None;
    }
    let status = payload.get("status")?;
    let current = transport.read().clone()?;
    let still_running = status
        .get("applications")
        .and_then(Value::as_array)
        .is_some_and(|apps| {
            apps.iter().any(|app| {
                app.get("transportId").and_then(Value::as_str) == Some(current.as_str())
            })
        });
    if still_running {
        return None;
    }
    let mut guard = transport.write();
    if guard.as_deref() != Some(current.as_str()) {
        return None;
    }
    *guard = None;
    drop(guard);
    media.write().mark_app_closed();
    Some(current)
}

/// Whether a `LOAD` error points at a dead receiver app on a still-live device
/// (so relaunching `CC1AD845` can recover it) rather than a rejected stream.
fn should_relaunch_on_load_error(error: &str) -> bool {
    error == "the cast device did not answer"
        || error == "INVALID_MEDIA_SESSION_ID"
        || error == "no cast receiver is running"
}

fn apply_media_status(media: &Arc<parking_lot::RwLock<MediaInfo>>, status: &Value) {
    let mut info = media.write();
    if let Some(duration) = status
        .get("media")
        .and_then(|media| media.get("duration"))
        .and_then(Value::as_f64)
    {
        info.duration = duration;
    }
    info.idle_reason = status
        .get("idleReason")
        .and_then(Value::as_str)
        .map(str::to_string);

    let current_time = status.get("currentTime").and_then(Value::as_f64);
    if let Some(state) = status.get("playerState").and_then(Value::as_str) {
        match state {
            "PLAYING" => {
                // A receiver reports `PLAYING` at the start position while it
                // opens the manifest. Only a sample that proves the clock is
                // moving may start the local clock; until then the playhead
                // holds where the LOAD/SEEK put it.
                if let Some(time) = current_time {
                    let held = info.awaiting_start();
                    if info.takes_playing_sample(time) {
                        if held {
                            // One line per hand-off: it is how a log confirms
                            // that the bar waited for the device.
                            info!("Cast playhead running at {time:.2}s");
                        }
                        info.position = time;
                        info.updated = Some(Instant::now());
                    }
                }
                info.player_state = "PLAYING".to_string();
            }
            "PAUSED" => {
                if let Some(time) = current_time {
                    if info.plausible(time) {
                        info.position = time;
                    }
                } else if info.player_state == "PLAYING" {
                    info.position = info.live_position();
                }
                info.updated = None;
                info.player_state = "PAUSED".to_string();
            }
            other => {
                if other == "IDLE" {
                    // No stream is loaded; there is nothing to start.
                    info.hold = None;
                }
                if let Some(time) = current_time {
                    if info.plausible(time) {
                        info.position = time;
                    }
                }
                info.updated = None;
                info.player_state = other.to_string();
            }
        }
    } else if let Some(time) = current_time {
        if info.takes_playing_sample(time) {
            info.position = time;
            info.updated = Some(Instant::now());
        }
    }
    if let Some(session) = status.get("mediaSessionId").and_then(Value::as_i64) {
        info.media_session_id = Some(session);
    }
}

/// Opens the Cast control connection with a hard bound on each phase. A device
/// that is gone leaves the TCP SYN unanswered for the kernel's retry window
/// (minutes), and one that accepts but never finishes TLS would hang the same
/// way; both have to surface as an ordinary connect error.
async fn connect_transport(
    host: &str,
    port: u16,
    timeout: Duration,
) -> Result<tokio_rustls::client::TlsStream<TcpStream>, String> {
    let connector = tls_connector()?;
    let server_name = rustls::pki_types::ServerName::try_from(host.to_string())
        .map_err(|error| format!("invalid cast device name: {error}"))?;
    let address = resolve_address(host, port).await?;
    let tcp = tokio::time::timeout(timeout, TcpStream::connect(address))
        .await
        .map_err(|_| {
            format!(
                "the cast device did not answer at {address} within {}s",
                timeout.as_secs()
            )
        })?
        .map_err(|error| format!("could not reach the cast device at {address}: {error}"))?;
    tokio::time::timeout(timeout, connector.connect(server_name, tcp))
        .await
        .map_err(|_| {
            format!(
                "the cast device at {address} accepted a connection but did not complete the Cast handshake"
            )
        })?
        .map_err(|error| format!("cast TLS handshake failed: {error}"))
}

/// Discovery hands us literal addresses; resolving those directly avoids a
/// getaddrinfo round trip (and the resolver's socket options) entirely.
async fn resolve_address(host: &str, port: u16) -> Result<std::net::SocketAddr, String> {
    if let Ok(ip) = host.parse::<std::net::IpAddr>() {
        if let std::net::IpAddr::V6(address) = ip {
            // A link-local destination needs a scope id; mDNS does not give us
            // one, and connect() would fail with EINVAL.
            if address.segments()[0] & 0xffc0 == 0xfe80 {
                return Err(
                    "the cast device only advertised an IPv6 link-local address".to_string()
                );
            }
        }
        return Ok(std::net::SocketAddr::new(ip, port));
    }
    let mut addresses = tokio::net::lookup_host((host, port))
        .await
        .map_err(|error| format!("could not resolve the cast device: {error}"))?;
    addresses
        .next()
        .ok_or_else(|| "the cast device host did not resolve".to_string())
}

/// Cast devices present a self-signed certificate and there is no trust chain
/// to validate against, so the certificate is accepted as-is. The connection
/// only carries media-control JSON for the device the user picked on the LAN.
#[derive(Debug)]
struct AcceptAnyCert(Arc<rustls::crypto::CryptoProvider>);

impl rustls::client::danger::ServerCertVerifier for AcceptAnyCert {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

fn tls_connector() -> Result<tokio_rustls::TlsConnector, String> {
    let provider = rustls::crypto::ring::default_provider();
    let config = rustls::ClientConfig::builder_with_provider(Arc::new(provider.clone()))
        .with_safe_default_protocol_versions()
        .map_err(|error| format!("cast TLS setup failed: {error}"))?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AcceptAnyCert(Arc::new(provider))))
        .with_no_client_auth();
    Ok(tokio_rustls::TlsConnector::from(Arc::new(config)))
}

#[cfg(test)]
mod tests {
    use super::{
        apply_media_status, clear_closed_transport, connect_transport,
        should_relaunch_on_load_error, sync_receiver_applications, MediaInfo,
    };
    use crate::mpv::PlaybackState;
    use serde_json::json;
    use std::sync::Arc;
    use std::time::{Duration, Instant};
    use tokio::net::TcpListener;

    fn held_media(position: f64) -> Arc<parking_lot::RwLock<MediaInfo>> {
        let media = Arc::new(parking_lot::RwLock::new(MediaInfo::default()));
        media.write().hold_at(position);
        media.write().player_state = "PLAYING".to_string();
        media
    }

    fn status(media: &Arc<parking_lot::RwLock<MediaInfo>>, state: &str, time: f64) {
        apply_media_status(
            media,
            &json!({ "playerState": state, "currentTime": time }),
        );
    }

    #[test]
    fn the_playhead_waits_for_the_receiver_to_show_its_clock_moving() {
        // A receiver answers `PLAYING` at the start position while it opens a
        // DASH manifest, so the first samples say nothing about audio.
        let media = held_media(0.0);
        status(&media, "PLAYING", 0.0);
        status(&media, "PLAYING", 0.0);
        assert_eq!(media.read().live_position(), 0.0);
        assert!(media.read().awaiting_start());

        // The first sample that proves the device clock advanced anchors it.
        status(&media, "PLAYING", 0.6);
        assert!(!media.read().awaiting_start());
        assert!(media.read().live_position() >= 0.6);
    }

    #[test]
    fn a_mid_track_load_ignores_the_zero_reported_while_the_manifest_opens() {
        let media = held_media(90.0);
        status(&media, "PLAYING", 0.0);
        assert_eq!(media.read().live_position(), 90.0);

        // The first genuine sample is a probe; the clock anchors on the next.
        status(&media, "PLAYING", 90.4);
        assert_eq!(media.read().live_position(), 90.0);
        status(&media, "PLAYING", 91.1);
        assert!(media.read().live_position() >= 91.1);
    }

    #[test]
    fn a_status_from_before_a_backward_seek_does_not_move_the_playhead() {
        let media = Arc::new(parking_lot::RwLock::new(MediaInfo::default()));
        {
            let mut info = media.write();
            info.player_state = "PLAYING".to_string();
            info.position = 200.0;
            info.updated = Some(Instant::now());
        }
        media.write().hold_at(10.0);

        // An in-flight status still describes the old playhead.
        status(&media, "PLAYING", 200.4);
        assert_eq!(media.read().live_position(), 10.0);

        status(&media, "PLAYING", 10.3);
        assert_eq!(media.read().live_position(), 10.0);
        status(&media, "PLAYING", 11.0);
        assert!(media.read().live_position() >= 11.0);
    }

    #[test]
    fn pausing_before_the_receiver_starts_keeps_the_target() {
        let media = held_media(45.0);
        status(&media, "PAUSED", 0.0);
        assert_eq!(media.read().live_position(), 45.0);
        assert_eq!(media.read().player_state, "PAUSED");
    }

    #[test]
    fn a_transport_change_made_on_the_device_is_the_reported_state() {
        // The receiver is the transport authority. A pause, resume or stop
        // made on the device (or by another sender) arrives only as a
        // MEDIA_STATUS, and the session reports exactly this state to MPRIS
        // and the panel — there is no session mirror that could go stale.
        let media = Arc::new(parking_lot::RwLock::new(MediaInfo::default()));
        {
            let mut info = media.write();
            info.player_state = "PLAYING".to_string();
            info.position = 42.0;
            info.updated = Some(Instant::now());
        }
        assert_eq!(media.read().playback_state(), PlaybackState::Playing);

        // Paused from the speaker: the state flips and the clock freezes at
        // the receiver's own playhead.
        status(&media, "PAUSED", 43.2);
        assert_eq!(media.read().playback_state(), PlaybackState::Paused);
        assert_eq!(media.read().live_position(), 43.2);

        // Resumed from the phone.
        status(&media, "PLAYING", 43.2);
        assert_eq!(media.read().playback_state(), PlaybackState::Playing);

        // Stopped from the device: no stream is loaded any more.
        status(&media, "IDLE", 0.0);
        assert_eq!(media.read().playback_state(), PlaybackState::Stopped);
    }

    #[test]
    fn resuming_waits_for_the_receiver_before_the_clock_runs() {
        let media = Arc::new(parking_lot::RwLock::new(MediaInfo::default()));
        {
            let mut info = media.write();
            info.player_state = "PAUSED".to_string();
            info.position = 17.0;
        }
        media.write().mark_playing();
        assert_eq!(media.read().live_position(), 17.0);

        // A stale sample at the paused position must not start the clock.
        status(&media, "PLAYING", 17.0);
        assert_eq!(media.read().live_position(), 17.0);
        status(&media, "PLAYING", 17.8);
        assert!(media.read().live_position() >= 17.8);
    }

    #[test]
    fn an_abandoned_hand_off_drops_the_hold_without_starting_a_clock() {
        let media = held_media(12.0);
        media.write().release_hold();
        assert!(!media.read().awaiting_start());
        assert_eq!(media.read().live_position(), 12.0);
    }

    #[tokio::test]
    async fn a_device_that_accepts_but_never_speaks_tls_times_out() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        // Accept the TCP connection, then stay silent: a stalled receiver, or
        // a firewall that answers SYN but drops everything after it.
        let hold = tokio::spawn(async move {
            let (_stream, _) = listener.accept().await.unwrap();
            tokio::time::sleep(Duration::from_secs(10)).await;
        });
        let started = Instant::now();
        let result = connect_transport("127.0.0.1", port, Duration::from_millis(250)).await;
        assert!(result.is_err());
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "the TLS handshake must not outlive the deadline"
        );
        hold.abort();
    }

    #[tokio::test]
    async fn a_device_that_is_not_listening_fails_at_once() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        // A closed port answers RST, so this is an immediate error rather than
        // a timeout: that is what a flash of "Connecting..." should look like.
        let started = Instant::now();
        let result = connect_transport("127.0.0.1", port, Duration::from_secs(5)).await;
        assert!(result.is_err());
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn a_connection_close_from_the_receiver_app_clears_transport_and_parks_playhead() {
        let transport = Arc::new(parking_lot::RwLock::new(Some("web-42".to_string())));
        let media = Arc::new(parking_lot::RwLock::new(MediaInfo::default()));
        {
            let mut info = media.write();
            info.player_state = "PLAYING".to_string();
            info.position = 63.5;
            info.media_session_id = Some(7);
        }

        // A CLOSE from an unrelated transport leaves our session untouched.
        assert!(!clear_closed_transport(&transport, &media, "web-99"));
        assert_eq!(transport.read().as_deref(), Some("web-42"));
        assert_eq!(media.read().playback_state(), PlaybackState::Playing);

        // A CLOSE from our receiver clears the dead transport, parks at the
        // last position and drops the stale mediaSessionId.
        assert!(clear_closed_transport(&transport, &media, "web-42"));
        assert!(transport.read().is_none());
        assert_eq!(media.read().playback_state(), PlaybackState::Stopped);
        assert_eq!(media.read().position, 63.5);
        assert_eq!(media.read().media_session_id, None);
    }

    #[test]
    fn receiver_status_detects_when_our_app_is_gone_and_preserves_it_while_running() {
        let transport = Arc::new(parking_lot::RwLock::new(Some("web-42".to_string())));
        let media = Arc::new(parking_lot::RwLock::new(MediaInfo::default()));
        {
            let mut info = media.write();
            info.player_state = "PAUSED".to_string();
            info.position = 18.0;
            info.media_session_id = Some(3);
        }

        // Still running: keep the transport and paused state.
        let running = json!({
            "type": "RECEIVER_STATUS",
            "status": {
                "applications": [{ "appId": "CC1AD845", "transportId": "web-42" }]
            }
        });
        assert_eq!(sync_receiver_applications(&transport, &media, &running), None);
        assert_eq!(transport.read().as_deref(), Some("web-42"));
        assert_eq!(media.read().playback_state(), PlaybackState::Paused);

        // App exited (idle timeout / voice stop leaves `applications` absent).
        let idle = json!({
            "type": "RECEIVER_STATUS",
            "status": { "volume": { "level": 0.4 } }
        });
        assert_eq!(
            sync_receiver_applications(&transport, &media, &idle).as_deref(),
            Some("web-42")
        );
        assert!(transport.read().is_none());
        assert_eq!(media.read().playback_state(), PlaybackState::Stopped);
        assert_eq!(media.read().position, 18.0);
        assert_eq!(media.read().media_session_id, None);

        // Another app replacing ours also clears the dead transport.
        *transport.write() = Some("web-50".to_string());
        let preempted = json!({
            "type": "RECEIVER_STATUS",
            "status": {
                "applications": [{ "appId": "233637DE", "transportId": "web-99" }]
            }
        });
        assert_eq!(
            sync_receiver_applications(&transport, &media, &preempted).as_deref(),
            Some("web-50")
        );
        assert!(transport.read().is_none());
    }

    #[test]
    fn load_relaunch_triggers_only_for_dead_receiver_errors() {
        assert!(should_relaunch_on_load_error("the cast device did not answer"));
        assert!(should_relaunch_on_load_error("INVALID_MEDIA_SESSION_ID"));
        assert!(should_relaunch_on_load_error("no cast receiver is running"));
        assert!(!should_relaunch_on_load_error("the device rejected the stream"));
        assert!(!should_relaunch_on_load_error("the cast device connection is closed"));
    }
}
