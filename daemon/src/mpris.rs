use crate::mpv::{run_pipeline_op, PipelineOwner, PlaybackState, TRANSPORT_OP_TIMEOUT};
use crate::queue::{QueueManager, QueuedPlay, TrackItem};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tracing::{info, warn};
use zbus::connection::Builder;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{ObjectPath, Value};
use zbus::{interface, Connection};

const OBJECT_PATH: &str = "/org/mpris/MediaPlayer2";
#[cfg(test)]
const ROOT_INTERFACE: &str = "org.mpris.MediaPlayer2";
#[cfg(test)]
const PLAYER_INTERFACE: &str = "org.mpris.MediaPlayer2.Player";
const BUS_NAME: &str = "org.mpris.MediaPlayer2.tidalplayer";

fn track_object_path(track_id: &str) -> String {
    let mut sanitized = String::with_capacity(track_id.len());
    for byte in track_id.bytes() {
        if byte.is_ascii_alphanumeric() || byte == b'_' {
            sanitized.push(byte as char);
        } else {
            sanitized.push('_');
            sanitized.push_str(&format!("{byte:02x}"));
        }
    }
    if sanitized.is_empty() {
        sanitized.push('0');
    }
    format!("/org/mpris/MediaPlayer2/Track/{sanitized}")
}

pub trait MprisPlayback: PipelineOwner + Send + Sync + 'static {
    fn get_state(&self) -> PlaybackState;
    fn get_position(&self) -> f64;
    fn get_duration(&self) -> f64;
    fn seek(&self, seconds: f64) -> Result<(), String>;
    fn pause(&self) -> Result<(), String>;
    fn play(&self) -> Result<(), String>;
    fn stop(&self) -> Result<(), String>;
    fn toggle(&self) -> Result<PlaybackState, String>;
    fn get_volume(&self) -> f64;
    fn set_volume(&self, volume: f64);
    fn set_rate(&self, rate: f64) -> Result<(), String>;
    fn note_user_pause(&self);
}

pub struct MprisRoot;

#[interface(name = "org.mpris.MediaPlayer2")]
impl MprisRoot {
    async fn raise(&self) {}

    // The daemon is managed by the user's systemd service, so MPRIS clients
    // must not terminate it behind systemd's back.
    async fn quit(&self) {}

    #[zbus(property)]
    fn can_quit(&self) -> bool {
        false
    }

    #[zbus(property)]
    fn can_raise(&self) -> bool {
        false
    }

    #[zbus(property)]
    fn has_track_list(&self) -> bool {
        false
    }

    #[zbus(property)]
    fn identity(&self) -> &str {
        "TIDAL Player"
    }

    #[zbus(property)]
    fn desktop_entry(&self) -> &str {
        ""
    }

    #[zbus(property)]
    fn supported_uri_schemes(&self) -> Vec<&str> {
        Vec::new()
    }

    #[zbus(property)]
    fn supported_mime_types(&self) -> Vec<&str> {
        Vec::new()
    }
}

#[derive(Clone)]
pub struct MprisPlayer {
    player: Arc<dyn MprisPlayback>,
    queue: Arc<QueueManager>,
    now_playing: Arc<tokio::sync::RwLock<Option<TrackItem>>>,
    play_tx: tokio::sync::mpsc::UnboundedSender<QueuedPlay>,
    playback_command_lock: Arc<tokio::sync::Mutex<()>>,
}

impl MprisPlayer {
    pub fn new(
        player: Arc<dyn MprisPlayback>,
        queue: Arc<QueueManager>,
        now_playing: Arc<tokio::sync::RwLock<Option<TrackItem>>>,
        play_tx: tokio::sync::mpsc::UnboundedSender<QueuedPlay>,
        playback_command_lock: Arc<tokio::sync::Mutex<()>>,
    ) -> Self {
        Self {
            player,
            queue,
            now_playing,
            play_tx,
            playback_command_lock,
        }
    }

    async fn emit_seeked(
        &self,
        emitter: &SignalEmitter<'_>,
        seconds: f64,
    ) -> zbus::fdo::Result<()> {
        let position_micros = (seconds.max(0.0) * 1_000_000.0) as i64;
        emitter
            .seeked(position_micros)
            .await
            .map_err(|error| failed(error.to_string()))
    }

    async fn metadata_value(&self) -> HashMap<String, Value<'_>> {
        // Drive MPRIS metadata from the queue (source of truth) so that
        // clients see track changes immediately on Next/Previous/Jump without
        // waiting for async stream fetch or now_playing write.
        let track = self.queue.get_current_track().await;
        let mut map = HashMap::new();
        if let Some(track) = track {
            let path = track_object_path(&track.id);
            if let Ok(object_path) = ObjectPath::try_from(path) {
                map.insert("mpris:trackid".to_owned(), Value::ObjectPath(object_path));
            }

            map.insert(
                "mpris:length".to_owned(),
                Value::I64((track.duration.max(0.0) * 1_000_000.0) as i64),
            );
            map.insert("xesam:title".to_owned(), Value::Str(track.title.into()));
            let artists: Vec<String> = if track.artists.is_empty() {
                vec![track.artist]
            } else {
                track
                    .artists
                    .into_iter()
                    .map(|artist| artist.name)
                    .collect()
            };
            map.insert("xesam:artist".to_owned(), Value::from(artists));
            map.insert("xesam:album".to_owned(), Value::Str(track.album.into()));

            if let Some(art) = track.art_url {
                map.insert("mpris:artUrl".to_owned(), Value::Str(art.into()));
            }
        }
        map
    }
}

#[interface(name = "org.mpris.MediaPlayer2.Player")]
impl MprisPlayer {
    async fn next(&self, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) {
        let _guard = self.playback_command_lock.lock().await;
        if let Some(next_track) = self.queue.next_track_for_user().await {
            info!("MPRIS Next: {}", next_track.title);
            // Update now_playing immediately so MPRIS clients see the new track
            // without waiting for the async stream fetch + play_uri to complete.
            *self.now_playing.write().await = Some(next_track.clone());
            let _ = self.metadata_changed(&emitter).await;
            let _ = self.can_go_next_changed(&emitter).await;
            let _ = self.can_go_previous_changed(&emitter).await;
            let _ = self
                .play_tx
                .send(QueuedPlay::new(next_track, self.player.pause_generation()));
        }
    }

    async fn previous(
        &self,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        let _guard = self.playback_command_lock.lock().await;
        if self.player.get_position() >= 5.0 {
            run_pipeline_op(&self.player, TRANSPORT_OP_TIMEOUT, |p| p.seek(0.0))
                .await
                .map_err(failed)?;
            self.emit_seeked(&emitter, 0.0).await?;
        } else if let Some(previous_track) = self.queue.prev_track_for_user().await {
            info!("MPRIS Previous: {}", previous_track.title);
            // Update now_playing immediately for consistent MPRIS metadata.
            *self.now_playing.write().await = Some(previous_track.clone());
            let _ = self.metadata_changed(&emitter).await;
            let _ = self.can_go_next_changed(&emitter).await;
            let _ = self.can_go_previous_changed(&emitter).await;
            let _ = self
                .play_tx
                .send(QueuedPlay::new(previous_track, self.player.pause_generation()));
        }
        Ok(())
    }

    async fn pause(
        &self,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        self.player.note_user_pause();
        let _guard = self.playback_command_lock.lock().await;
        run_pipeline_op(&self.player, TRANSPORT_OP_TIMEOUT, |p| p.pause())
            .await
            .map_err(failed)?;
        let _ = self.playback_status_changed(&emitter).await;
        Ok(())
    }

    async fn play_pause(
        &self,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        if self.player.get_state() == PlaybackState::Playing {
            self.player.note_user_pause();
        }
        let _guard = self.playback_command_lock.lock().await;
        run_pipeline_op(&self.player, TRANSPORT_OP_TIMEOUT, |p| {
            p.toggle().map(|_| ())
        })
        .await
        .map_err(failed)?;
        let _ = self.playback_status_changed(&emitter).await;
        Ok(())
    }

    async fn stop(
        &self,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        self.player.note_user_pause();
        let _guard = self.playback_command_lock.lock().await;
        run_pipeline_op(&self.player, TRANSPORT_OP_TIMEOUT, |p| p.stop())
            .await
            .map_err(failed)?;
        let _ = self.playback_status_changed(&emitter).await;
        Ok(())
    }

    async fn play(
        &self,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        let _guard = self.playback_command_lock.lock().await;
        run_pipeline_op(&self.player, TRANSPORT_OP_TIMEOUT, |p| p.play())
            .await
            .map_err(failed)?;
        let _ = self.playback_status_changed(&emitter).await;
        Ok(())
    }

    async fn seek(
        &self,
        offset_micros: i64,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        let _guard = self.playback_command_lock.lock().await;
        let current_micros = (self.player.get_position().max(0.0) * 1_000_000.0) as i64;
        let target_micros = current_micros.saturating_add(offset_micros).max(0);
        let target_seconds = target_micros as f64 / 1_000_000.0;
        run_pipeline_op(&self.player, TRANSPORT_OP_TIMEOUT, move |p| {
            p.seek(target_seconds)
        })
        .await
        .map_err(failed)?;
        emitter
            .seeked(target_micros)
            .await
            .map_err(|error| failed(error.to_string()))
    }

    async fn set_position(
        &self,
        track_id: ObjectPath<'_>,
        position_micros: i64,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        let _guard = self.playback_command_lock.lock().await;
        let current_track_path = self
            .queue
            .get_current_track()
            .await
            .map(|track| track_object_path(&track.id));
        if current_track_path.as_deref() != Some(track_id.as_str()) {
            return Ok(());
        }

        let target_micros = position_micros.max(0);
        let target_seconds = target_micros as f64 / 1_000_000.0;
        run_pipeline_op(&self.player, TRANSPORT_OP_TIMEOUT, move |p| {
            p.seek(target_seconds)
        })
        .await
        .map_err(failed)?;
        emitter
            .seeked(target_micros)
            .await
            .map_err(|error| failed(error.to_string()))
    }

    async fn open_uri(&self, _uri: String) -> zbus::fdo::Result<()> {
        Err(zbus::fdo::Error::NotSupported(
            "TIDAL URI playback is not available through MPRIS OpenUri".into(),
        ))
    }

    #[zbus(signal)]
    async fn seeked(emitter: &SignalEmitter<'_>, position: i64) -> zbus::Result<()>;

    #[zbus(property)]
    fn playback_status(&self) -> &str {
        match self.player.get_state() {
            PlaybackState::Playing => "Playing",
            PlaybackState::Paused => "Paused",
            PlaybackState::Stopped => "Stopped",
        }
    }

    #[zbus(property)]
    async fn loop_status(&self) -> String {
        let (_, repeat_mode) = self.queue.playback_settings().await;
        match repeat_mode.as_str() {
            "track" => "Track".into(),
            "all" => "Playlist".into(),
            _ => "None".into(),
        }
    }

    #[zbus(property)]
    async fn set_loop_status(&self, value: String) -> zbus::fdo::Result<()> {
        let repeat_mode = match value.as_str() {
            "None" => "off",
            "Track" => "track",
            "Playlist" => "all",
            _ => {
                return Err(zbus::fdo::Error::InvalidArgs(format!(
                    "Unsupported LoopStatus: {value}"
                )))
            }
        };
        self.queue.set_repeat(repeat_mode).await;
        Ok(())
    }

    #[zbus(property)]
    fn rate(&self) -> f64 {
        1.0
    }

    #[zbus(property)]
    fn set_rate(&self, rate: f64) -> zbus::fdo::Result<()> {
        self.player.set_rate(rate).map_err(failed)
    }

    #[zbus(property)]
    async fn shuffle(&self) -> bool {
        self.queue.playback_settings().await.0
    }

    #[zbus(property)]
    async fn set_shuffle(&self, enabled: bool) {
        self.queue.set_shuffle(enabled).await;
    }

    #[zbus(property)]
    async fn metadata(&self) -> HashMap<String, Value<'_>> {
        self.metadata_value().await
    }

    #[zbus(property)]
    fn volume(&self) -> f64 {
        self.player.get_volume()
    }

    #[zbus(property)]
    fn set_volume(&self, volume: f64) {
        self.player.set_volume(volume);
    }

    #[zbus(property(emits_changed_signal = "false"))]
    fn position(&self) -> i64 {
        (self.player.get_position().max(0.0) * 1_000_000.0) as i64
    }

    #[zbus(property)]
    async fn can_go_next(&self) -> bool {
        // Consult the same helper the property watcher uses so MPRIS and the
        // emitted CanGoNext signal cannot disagree.
        self.queue.can_go_next().await
    }

    #[zbus(property)]
    async fn can_go_previous(&self) -> bool {
        self.queue.can_go_previous().await
    }

    #[zbus(property)]
    fn can_play(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn can_pause(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn can_seek(&self) -> bool {
        self.player.get_duration() > 0.0
    }

    #[zbus(property)]
    fn can_control(&self) -> bool {
        true
    }
}

fn failed(error: String) -> zbus::fdo::Error {
    zbus::fdo::Error::Failed(error)
}

#[derive(Debug, PartialEq)]
struct PropertySnapshot {
    state: PlaybackState,
    track: Option<TrackItem>,
    repeat_mode: String,
    shuffle: bool,
    volume: f64,
    can_go_next: bool,
    can_go_previous: bool,
    can_seek: bool,
}

async fn snapshot(mpris: &MprisPlayer) -> PropertySnapshot {
    let (current_track, repeat_mode, shuffle, can_go_next, can_go_previous) =
        mpris.queue.mpris_snapshot().await;
    PropertySnapshot {
        state: mpris.player.get_state(),
        track: current_track,
        repeat_mode,
        shuffle,
        volume: mpris.player.get_volume(),
        can_go_next,
        can_go_previous,
        can_seek: mpris.player.get_duration() > 0.0,
    }
}

async fn watch_property_changes(mpris: MprisPlayer, emitter: SignalEmitter<'static>) {
    let mut previous = snapshot(&mpris).await;
    let mut ticker = tokio::time::interval(Duration::from_millis(100));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        ticker.tick().await;
        let current = snapshot(&mpris).await;

        // Publish metadata before status so clients see the new track before a
        // Playing notification can trigger an OS toast.
        if current.track != previous.track {
            if let Err(error) = mpris.metadata_changed(&emitter).await {
                warn!("Could not emit MPRIS Metadata change: {error}");
                break;
            }
        }
        if current.repeat_mode != previous.repeat_mode {
            if let Err(error) = mpris.loop_status_changed(&emitter).await {
                warn!("Could not emit MPRIS LoopStatus change: {error}");
                break;
            }
        }
        if current.shuffle != previous.shuffle {
            if let Err(error) = mpris.shuffle_changed(&emitter).await {
                warn!("Could not emit MPRIS Shuffle change: {error}");
                break;
            }
        }
        if current.volume != previous.volume {
            if let Err(error) = mpris.volume_changed(&emitter).await {
                warn!("Could not emit MPRIS Volume change: {error}");
                break;
            }
        }
        if current.state != previous.state {
            if let Err(error) = mpris.playback_status_changed(&emitter).await {
                warn!("Could not emit MPRIS PlaybackStatus change: {error}");
                break;
            }
        }
        if current.can_go_next != previous.can_go_next {
            if let Err(error) = mpris.can_go_next_changed(&emitter).await {
                warn!("Could not emit MPRIS CanGoNext change: {error}");
                break;
            }
        }
        if current.can_go_previous != previous.can_go_previous {
            if let Err(error) = mpris.can_go_previous_changed(&emitter).await {
                warn!("Could not emit MPRIS CanGoPrevious change: {error}");
                break;
            }
        }
        if current.can_seek != previous.can_seek {
            if let Err(error) = mpris.can_seek_changed(&emitter).await {
                warn!("Could not emit MPRIS CanSeek change: {error}");
                break;
            }
        }
        previous = current;
    }
}

pub async fn start_mpris_server(
    player: Arc<dyn MprisPlayback>,
    queue: Arc<QueueManager>,
    now_playing: Arc<tokio::sync::RwLock<Option<TrackItem>>>,
    play_tx: tokio::sync::mpsc::UnboundedSender<QueuedPlay>,
    playback_command_lock: Arc<tokio::sync::Mutex<()>>,
) -> Result<Connection, zbus::Error> {
    start_mpris_server_named(
        BUS_NAME,
        player,
        queue,
        now_playing,
        play_tx,
        playback_command_lock,
    )
    .await
}

async fn start_mpris_server_named(
    bus_name: &str,
    player: Arc<dyn MprisPlayback>,
    queue: Arc<QueueManager>,
    now_playing: Arc<tokio::sync::RwLock<Option<TrackItem>>>,
    play_tx: tokio::sync::mpsc::UnboundedSender<QueuedPlay>,
    playback_command_lock: Arc<tokio::sync::Mutex<()>>,
) -> Result<Connection, zbus::Error> {
    let mpris_player = MprisPlayer::new(player, queue, now_playing, play_tx, playback_command_lock);
    let connection = Builder::session()?
        .name(bus_name)?
        .serve_at(OBJECT_PATH, MprisRoot)?
        .serve_at(OBJECT_PATH, mpris_player.clone())?
        .build()
        .await?;

    let emitter = SignalEmitter::new(&connection, OBJECT_PATH)?.into_owned();
    tokio::spawn(watch_property_changes(mpris_player, emitter));
    info!("Registered MPRIS D-Bus interface: {bus_name}");
    Ok(connection)
}

#[cfg(test)]
mod tests {
    use super::*;
    use parking_lot::RwLock;
    use std::sync::atomic::{AtomicU64, Ordering};
    use zbus::{Connection, Proxy};

    static NEXT_TEST_ID: AtomicU64 = AtomicU64::new(0);

    #[derive(Default)]
    struct FakePlayback {
        state: RwLock<PlaybackState>,
        position: RwLock<f64>,
        volume: RwLock<f64>,
    }

    impl MprisPlayback for FakePlayback {
        fn get_state(&self) -> PlaybackState {
            *self.state.read()
        }
        fn get_position(&self) -> f64 {
            *self.position.read()
        }
        fn get_duration(&self) -> f64 {
            180.0
        }
        fn seek(&self, seconds: f64) -> Result<(), String> {
            *self.position.write() = seconds;
            Ok(())
        }
        fn pause(&self) -> Result<(), String> {
            *self.state.write() = PlaybackState::Paused;
            Ok(())
        }
        fn play(&self) -> Result<(), String> {
            *self.state.write() = PlaybackState::Playing;
            Ok(())
        }
        fn stop(&self) -> Result<(), String> {
            *self.state.write() = PlaybackState::Stopped;
            Ok(())
        }
        fn toggle(&self) -> Result<PlaybackState, String> {
            let next = if *self.state.read() == PlaybackState::Playing {
                PlaybackState::Paused
            } else {
                PlaybackState::Playing
            };
            *self.state.write() = next;
            Ok(next)
        }
        fn get_volume(&self) -> f64 {
            *self.volume.read()
        }
        fn set_volume(&self, volume: f64) {
            *self.volume.write() = volume.clamp(0.0, 1.0);
        }
        fn set_rate(&self, rate: f64) -> Result<(), String> {
            if (rate - 1.0).abs() < f64::EPSILON {
                Ok(())
            } else {
                Err("unsupported rate".into())
            }
        }
        fn note_user_pause(&self) {}
    }

    impl PipelineOwner for FakePlayback {
        fn pipeline_generation(&self) -> u64 {
            0
        }
        fn rebuild_wedged_pipeline(&self) -> Result<(), String> {
            Ok(())
        }
        fn pause_generation(&self) -> u64 {
            0
        }
    }

    async fn player_proxy<'a>(connection: &'a Connection, bus_name: &'a str) -> Proxy<'a> {
        Proxy::new(connection, bus_name, OBJECT_PATH, PLAYER_INTERFACE)
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn mpris_controls_properties_and_signals_work_over_dbus() {
        let test_id = NEXT_TEST_ID.fetch_add(1, Ordering::Relaxed);
        let bus_name = format!(
            "org.mpris.MediaPlayer2.tidalplayer_test_{}_{}",
            std::process::id(),
            test_id
        );
        let queue = Arc::new(QueueManager::new());
        let fake_player = Arc::new(FakePlayback::default());
        let (play_tx, _play_rx) = tokio::sync::mpsc::unbounded_channel();
        let now_playing = Arc::new(tokio::sync::RwLock::new(None::<TrackItem>));
        let _service = start_mpris_server_named(
            &bus_name,
            fake_player.clone(),
            queue.clone(),
            now_playing.clone(),
            play_tx,
            Arc::new(tokio::sync::Mutex::new(())),
        )
        .await
        .unwrap();
        let client = Connection::session().await.unwrap();
        let root = Proxy::new(&client, bus_name.as_str(), OBJECT_PATH, ROOT_INTERFACE)
            .await
            .unwrap();
        let player = player_proxy(&client, &bus_name).await;

        // Verify basic MPRIS properties
        assert_eq!(
            root.get_property::<String>("Identity").await.unwrap(),
            "TIDAL Player"
        );
        assert_eq!(
            player
                .get_property::<String>("PlaybackStatus")
                .await
                .unwrap(),
            "Stopped"
        );
        assert!(player.get_property::<bool>("CanControl").await.unwrap());
        assert_eq!(player.get_property::<f64>("Rate").await.unwrap(), 1.0);

        // Test Play/Pause cycle - just verify commands are accepted
        player.call::<_, _, ()>("Play", &()).await.unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(
            player
                .get_property::<String>("PlaybackStatus")
                .await
                .unwrap(),
            "Playing"
        );

        player.call::<_, _, ()>("Pause", &()).await.unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(
            player
                .get_property::<String>("PlaybackStatus")
                .await
                .unwrap(),
            "Paused"
        );

        player.call::<_, _, ()>("Play", &()).await.unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(
            player
                .get_property::<String>("PlaybackStatus")
                .await
                .unwrap(),
            "Playing"
        );

        drop(client);
    }
}
