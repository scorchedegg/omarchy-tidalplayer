use crate::auth::AuthManager;
use crate::cast::CastManager;
use crate::catalogue::{CatalogueManager, PlaylistItem, RecentItem, TrackPage};
use crate::mpv::{run_pipeline_op, MpvPlayer, PlaybackState, TRANSPORT_OP_TIMEOUT};
use crate::queue::{QueueManager, QueuedPlay, TrackItem};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::Arc;
use tokio::sync::{Mutex, RwLock};
use tracing::{error, info, warn};

#[derive(Clone)]
pub struct AppState {
    pub player: Arc<MpvPlayer>,
    pub queue: Arc<QueueManager>,
    pub catalogue: Arc<CatalogueManager>,
    pub auth: Arc<AuthManager>,
    pub cast: Arc<CastManager>,
    pub recent_searches: Arc<RwLock<Vec<String>>>,
    pub recent_contexts: Arc<RwLock<Vec<RecentItem>>>,
    pub playback_command_lock: Arc<Mutex<()>>,
    pub play_trigger_tx: tokio::sync::mpsc::UnboundedSender<QueuedPlay>,
    pub now_playing: Arc<RwLock<Option<TrackItem>>>,
    /// Last playback failure, surfaced by `status` until a new play succeeds.
    pub playback_error: Arc<RwLock<Option<PlaybackError>>>,
    /// Status/queue invalidations for connected RPC clients.
    pub events: tokio::sync::broadcast::Sender<crate::rpc::Event>,
}

#[derive(Clone, Debug, Serialize)]
pub struct PlaybackError {
    /// Wall-clock id so clients can notify once even across daemon restarts.
    pub id: u64,
    pub message: String,
}

#[derive(Debug, Deserialize)]
pub struct ActionRequest {
    pub action: String,
    pub value: Option<Value>,
}

#[derive(Debug, Deserialize)]
pub struct PlayRequest {
    pub tracks: Vec<TrackItem>,
    #[serde(default)]
    pub index: usize,
    pub context: Option<String>,
    #[serde(default)]
    pub recent_context: Option<RecentItem>,
}

#[derive(Debug, Deserialize)]
pub struct QueueAppendRequest {
    pub tracks: Vec<TrackItem>,
}

#[derive(Debug, Deserialize)]
pub struct IdParams {
    pub id: String,
}

#[derive(Debug, Deserialize)]
pub struct PagedIdParams {
    pub id: String,
    #[serde(default)]
    pub offset: usize,
    #[serde(default)]
    pub limit: usize,
}

#[derive(Debug, Deserialize)]
pub struct PagedParams {
    #[serde(default)]
    pub offset: usize,
    #[serde(default)]
    pub limit: usize,
}

#[derive(Debug, Deserialize)]
pub struct AlbumParams {
    pub id: String,
    #[serde(default)]
    pub track_limit: u32,
}

#[derive(Debug, Deserialize)]
pub struct SearchParams {
    pub q: String,
}

#[derive(Debug, Deserialize)]
pub struct LyricsParams {
    pub track_id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub artist: String,
    #[serde(default)]
    pub duration: f64,
}

#[derive(Debug, Deserialize)]
pub struct AuthPkceCompleteParams {
    pub redirect_url: String,
}

#[derive(Debug, Deserialize)]
pub struct AddSearchRequest {
    pub query: String,
}

#[derive(Debug, Deserialize)]
pub struct PlaylistCreateRequest {
    pub title: String,
    #[serde(default)]
    pub description: String,
}

#[derive(Debug, Deserialize)]
pub struct PlaylistUpdateRequest {
    pub id: String,
    pub title: Option<String>,
    pub description: Option<String>,
    /// Privacy toggle; sent on its own for the Private/Public button.
    #[serde(default)]
    pub public: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct PlaylistIdRequest {
    pub id: String,
}

#[derive(Debug, Deserialize)]
pub struct PlaylistAddRequest {
    pub id: String,
    #[serde(default)]
    pub track_ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct PlaylistRemoveRequest {
    pub id: String,
    #[serde(default)]
    pub indices: Vec<usize>,
}

#[derive(Debug, Deserialize)]
pub struct PlaylistRemoveTrackRequest {
    pub id: String,
    pub track_id: String,
}

#[derive(Debug, Deserialize)]
pub struct PlaylistMoveRequest {
    pub id: String,
    pub from: usize,
    pub to: usize,
}

#[derive(Debug, Deserialize)]
pub struct FavoriteRequest {
    #[serde(rename = "type")]
    pub item_type: String,
    pub id: String,
}

#[derive(Debug, Deserialize)]
pub struct CastDevicesParams {
    #[serde(default)]
    pub refresh: Option<Value>,
}

#[derive(Debug, Deserialize)]
pub struct CastConnectRequest {
    pub device_id: String,
}

/// Decodes one method's params, turning a serde error into the message the
/// client sees in an error frame.
fn decode<T: serde::de::DeserializeOwned>(params: Value) -> Result<T, String> {
    serde_json::from_value(params).map_err(|error| format!("invalid params: {error}"))
}

/// One status snapshot. `include_position` is false for pushed events: the
/// client already gets a 100 ms playhead from MPRIS, and a position in the
/// snapshot would make every publisher tick look like a change.
/// `fetch_favorite` is false for pushed events too, so a cold favourites cache
/// cannot delay a badge event on a TIDAL request.
pub async fn status_json(state: &AppState, include_position: bool, fetch_favorite: bool) -> Value {
    let mut track = state.queue.get_current_track().await;
    if let Some(current) = track.as_mut() {
        state.catalogue.enrich_video_url(current);
    }
    let mut position = state.player.get_position();
    let mut duration = if let Some(ref t) = track {
        if t.duration > 0.0 {
            t.duration
        } else {
            state.player.get_duration()
        }
    } else {
        state.player.get_duration()
    };
    let mut format = track
        .as_ref()
        .and_then(|t| state.player.format_for(&t.id));
    let mut volume = state.player.get_volume();
    let mut playback_state = state.player.get_state();
    // While a cast session is active it owns the transport: the local pipeline
    // is stopped, so its state would be a lie.
    let cast = state.cast.snapshot();
    if let Some(cast) = cast.as_ref() {
        // The local pipeline is stopped while casting, so its playhead is 0.
        position = cast.position;
        if cast.duration > 0.0 {
            duration = cast.duration;
        }
        // The queue moves before the receiver has the new manifest. Until the
        // session's loaded track matches, its format describes the old one.
        format = if track
            .as_ref()
            .is_some_and(|current| cast.track_id == current.id)
        {
            Some(cast.format.clone())
        } else {
            None
        };
        volume = cast.volume;
        playback_state = cast.state;
    }
    let cast_json = match cast.as_ref() {
        Some(cast) => json!({
            "active": true,
            "device_id": cast.device_id,
            "device_name": cast.device_name,
            // What the device can output (`tv`, `speaker`, `speaker_group`,
            // `unknown`). The header's Cast button wears the active device's
            // class, so the session carries it beside the name.
            "kind": cast.kind,
            "stream_blocked": cast.stream_blocked,
            // The playhead is frozen until the receiver confirms that its
            // clock is running: the UI must not run ahead of the audio while
            // a LOAD, SEEK or resume is in flight.
            "pending": cast.pending,
            // The track the receiver has actually loaded. The queue can move
            // first; this is what lets a client tell whether the playhead it
            // is about to apply belongs to the track on screen.
            "track_id": cast.track_id,
        }),
        None => json!({ "active": false }),
    };
    let (shuffle, repeat_mode) = state.queue.playback_settings().await;
    let logged_in = state.auth.is_logged_in().await;
    // Copy out the token fields instead of holding the read guard: the
    // favorite lookup below can trigger a token refresh (write lock) and the
    // two locks would deadlock on the same task.
    let (user_id, country_code) = {
        let tokens = state.auth.tokens.read().await;
        (tokens.user_id, tokens.country_code.clone())
    };

    let favorite = if let Some(ref t) = track {
        if fetch_favorite {
            Some(state.catalogue.is_track_favorited(&t.id).await)
        } else {
            state.catalogue.favorite_cached(&t.id).await
        }
    } else {
        Some(false)
    };

    let state_str = playback_state_str(playback_state);
    let playback_error = state.playback_error.read().await.clone();
    let auth_flow = state.auth.pkce_flow_snapshot().await;

    let mut status = json!({
        "state": state_str,
        "track": track,
        "duration": duration,
        "format": format,
        "volume": volume,
        "repeat": repeat_mode,
        "shuffle": shuffle,
        "current_tlid": track.as_ref().and_then(|t| t.tlid),
        "logged_in": logged_in,
        "auth_flow": auth_flow,
        "playback_error": playback_error,
        "cast": cast_json,
        "user": {
            "logged_in": logged_in,
            "user_id": user_id,
            "country_code": country_code
        }
    });
    if let Some(favorite) = favorite {
        status["favorite"] = json!(favorite);
    }
    if include_position {
        status["position"] = json!(position);
    }
    status
}

fn playback_state_str(state: PlaybackState) -> &'static str {
    match state {
        PlaybackState::Playing => "Playing",
        PlaybackState::Paused => "Paused",
        PlaybackState::Stopped => "Stopped",
    }
}

async fn handle_action(state: &AppState, req: ActionRequest) -> Value {
    // Record the user's pause intent before waiting for the transport lock:
    // the lock can be held for a few seconds by a failed play/stop, and an
    // in-flight play request must be cancelled as soon as the user asks.
    let effective_state = state
        .cast
        .snapshot()
        .map(|snapshot| snapshot.state)
        .unwrap_or_else(|| state.player.get_state());
    if req.action == "pause"
        || req.action == "stop"
        || (req.action == "toggle" && effective_state == PlaybackState::Playing)
    {
        state.player.note_user_pause();
    }
    let _playback_guard = if matches!(
        req.action.as_str(),
        "toggle" | "play" | "pause" | "stop" | "next" | "previous" | "jump"
    ) {
        Some(state.playback_command_lock.clone().lock_owned().await)
    } else {
        None
    };

    // A cast device owns playback while it is active: transport commands go to
    // it directly. Next/previous/jump stay in the normal path — the playback
    // loop re-loads the new track onto the device.
    if state.cast.is_active() {
        let handled = match req.action.as_str() {
            "play" => {
                state.cast.play();
                true
            }
            "pause" => {
                state.cast.pause();
                true
            }
            "toggle" => {
                state.cast.toggle();
                true
            }
            "stop" => {
                state.cast.stop();
                true
            }
            "seek" => {
                if let Some(value) = req.value.as_ref().and_then(|value| value.as_f64()) {
                    state.cast.seek(value);
                }
                true
            }
            "volume" => {
                if let Some(value) = req.value.as_ref().and_then(|value| value.as_f64()) {
                    state.cast.set_volume(value);
                }
                true
            }
            _ => false,
        };
        if handled {
            let cur_track = state.queue.get_current_track().await;
            let st = state
                .cast
                .snapshot()
                .map(|snapshot| snapshot.state)
                .unwrap_or(PlaybackState::Stopped);
            drop(_playback_guard);
            let favorite = if let Some(ref t) = cur_track {
                state.catalogue.is_track_favorited(&t.id).await
            } else {
                false
            };
            return json!({
                "status": "ok",
                "state": playback_state_str(st),
                "track": cur_track,
                "favorite": favorite
            });
        }
    }

    match req.action.as_str() {
        "toggle" => {
            if let Err(e) =
                run_pipeline_op(&state.player, TRANSPORT_OP_TIMEOUT, |p| p.toggle()).await
            {
                warn!("Toggle failed: {e}");
            }
        }
        "play" => {
            if let Err(e) = run_pipeline_op(&state.player, TRANSPORT_OP_TIMEOUT, |p| p.play()).await
            {
                warn!("Play failed: {e}");
            }
        }
        "pause" => {
            if let Err(e) =
                run_pipeline_op(&state.player, TRANSPORT_OP_TIMEOUT, |p| p.pause()).await
            {
                warn!("Pause failed: {e}");
            }
        }
        "stop" => {
            if let Err(e) = run_pipeline_op(&state.player, TRANSPORT_OP_TIMEOUT, |p| p.stop()).await
            {
                warn!("Stop failed: {e}");
            }
        }
        "next" => {
            if let Some(t) = state.queue.next_track_for_user().await {
                // Update now_playing early for MPRIS clients (same as MPRIS path)
                // The playback loop will also set it after successful play_uri.
                let _ = state.now_playing.write().await.insert(t.clone());
                let _ = state
                    .play_trigger_tx
                    .send(QueuedPlay::new(t, state.player.pause_generation()));
            }
        }
        "previous" => {
            let cast_pos = state.cast.snapshot().map(|snapshot| snapshot.position);
            let cur = cast_pos.unwrap_or_else(|| state.player.get_position());
            if cur >= 5.0 {
                if cast_pos.is_some() {
                    state.cast.seek(0.0);
                } else if let Err(e) =
                    run_pipeline_op(&state.player, TRANSPORT_OP_TIMEOUT, |p| p.seek(0.0)).await
                {
                    warn!("Seek to restart failed: {e}");
                }
            } else if let Some(t) = state.queue.prev_track_for_user().await {
                let _ = state.now_playing.write().await.insert(t.clone());
                let _ = state
                    .play_trigger_tx
                    .send(QueuedPlay::new(t, state.player.pause_generation()));
            }
        }
        "play_next" => {
            if let Some(val) = req.value {
                if let Ok(item) = serde_json::from_value::<TrackItem>(val) {
                    state.queue.play_next(item).await;
                }
            }
        }
        "seek" => {
            if let Some(val) = req.value.and_then(|v| v.as_f64()) {
                if let Err(e) =
                    run_pipeline_op(&state.player, TRANSPORT_OP_TIMEOUT, move |p| p.seek(val)).await
                {
                    warn!("Seek failed: {e}");
                }
            }
        }
        "volume" => {
            if let Some(val) = req.value.and_then(|v| v.as_f64()) {
                state.player.set_volume(val);
            }
        }
        "repeat" => {
            if let Some(val) = req.value.and_then(|v| v.as_str().map(|s| s.to_string())) {
                state.queue.set_repeat(&val).await;
            }
        }
        "shuffle" => {
            if let Some(val) = req.value.and_then(|v| v.as_bool()) {
                state.queue.set_shuffle(val).await;
            }
        }
        "jump" => {
            if let Some(idx) = req.value.and_then(|v| v.as_u64().map(|n| n as usize)) {
                if let Some(t) = state.queue.jump_to(idx).await {
                    let _ = state.now_playing.write().await.insert(t.clone());
                    let _ = state
                        .play_trigger_tx
                        .send(QueuedPlay::new(t, state.player.pause_generation()));
                }
            }
        }
        "favorite" => {
            let track_id =
                if let Some(val) = req.value.and_then(|v| v.as_str().map(|s| s.to_string())) {
                    val
                } else if let Some(t) = state.queue.get_current_track().await {
                    t.id
                } else {
                    String::new()
                };
            if !track_id.is_empty() {
                match state.catalogue.toggle_favorite_track(&track_id).await {
                    Ok(fav) => info!("Toggled favorite for {track_id}: {fav}"),
                    Err(e) => error!("Failed to toggle favorite for {track_id}: {e}"),
                }
            }
        }
        _ => {}
    }

    let cur_track = state.queue.get_current_track().await;
    // The cast session is authoritative while it is active; mpv is stopped.
    let st = state
        .cast
        .snapshot()
        .map(|snapshot| snapshot.state)
        .unwrap_or_else(|| state.player.get_state());
    // The favourite flag is not part of the transport decision, and this
    // handler must never hold the transport lock across a TIDAL lookup: a
    // burst of skips would serialize here and starve the playback loop.
    drop(_playback_guard);
    let favorite = if let Some(ref t) = cur_track {
        state.catalogue.is_track_favorited(&t.id).await
    } else {
        false
    };
    let state_str = playback_state_str(st);
    json!({
        "status": "ok",
        "state": state_str,
        "track": cur_track,
        "favorite": favorite
    })
}

async fn handle_play(state: &AppState, req: PlayRequest) -> Value {
    let mut recent_to_record = None;
    let result = {
        let _playback_guard = state.playback_command_lock.clone().lock_owned().await;
        if let Some(track) = state
            .queue
            .set_queue(req.tracks, req.index, req.context)
            .await
        {
            if let Some(context) = req.recent_context {
                let context_ref = json!({
                    "id": context.id,
                    "title": context.title,
                    "subtitle": context.subtitle,
                    "type": context.item_type,
                    "artUrl": context.art_url,
                    "own": context.own
                });
                state.queue.set_context_ref(Some(context_ref)).await;
                recent_to_record = Some(context);
            }
            // Update now_playing early so MPRIS clients see the new track immediately
            // (queue is source of truth; this keeps now_playing in sync for any direct readers).
            let _ = state.now_playing.write().await.insert(track.clone());
            let _ = state
                .play_trigger_tx
                .send(QueuedPlay::new(track.clone(), state.player.pause_generation()));
            json!({ "ok": true, "track": track })
        } else {
            json!({ "ok": false, "error": "No track found" })
        }
    };
    if let Some(context) = recent_to_record {
        record_recent_context(state, context).await;
    }
    result
}

async fn get_user_albums(state: &AppState) -> Value {
    match state.catalogue.get_user_albums().await {
        Ok(albums) => json!({ "albums": albums }),
        Err(e) => json!({ "albums": [], "error": e }),
    }
}

async fn get_user_artists(state: &AppState) -> Value {
    match state.catalogue.get_user_artists().await {
        Ok(artists) => json!({ "artists": artists }),
        Err(e) => json!({ "artists": [], "error": e }),
    }
}

async fn get_queue(state: &AppState) -> Value {
    let q = state.queue.get_state().await;
    json!({
        "tracks": q.tracks,
        "index": q.current_index,
        "context": q.playing_context,
        "context_ref": q.context_ref
    })
}

async fn append_queue(state: &AppState, req: QueueAppendRequest) -> Value {
    state.queue.append(req.tracks).await;
    json!({ "ok": true })
}

/// The cached device list; `refresh: true` forces a fresh mDNS sweep. A plain
/// poll never blocks on the network for longer than the cache is fresh.
async fn get_cast_devices(state: &AppState, params: CastDevicesParams) -> Value {
    let refresh = match params.refresh {
        Some(Value::Bool(value)) => value,
        Some(Value::String(value)) => matches!(value.as_str(), "1" | "true" | "yes"),
        _ => false,
    };
    let devices = state.cast.devices(refresh).await;
    json!({
        "devices": devices,
        "last_used_id": state.cast.last_used()
    })
}

async fn cast_connect(state: &AppState, req: CastConnectRequest) -> Value {
    match state.cast.connect(&req.device_id).await {
        Ok(device) => json!({ "ok": true, "device": device }),
        Err(error) => json!({ "ok": false, "error": error }),
    }
}

async fn cast_disconnect(state: &AppState) -> Value {
    match state.cast.disconnect().await {
        Ok(()) => json!({ "ok": true }),
        Err(error) => json!({ "ok": false, "error": error }),
    }
}

async fn get_mixes(state: &AppState) -> Value {
    match state.catalogue.get_mixes().await {
        Ok(mixes) => json!({ "mixes": mixes }),
        Err(e) => json!({ "mixes": [], "error": e }),
    }
}

async fn get_playlists(state: &AppState) -> Value {
    match state.catalogue.get_playlists().await {
        Ok(mut playlists) => {
            let recent = state.recent_contexts.read().await;
            sort_playlists_by_recent(&mut playlists, &recent);
            json!({ "playlists": playlists })
        }
        Err(e) => json!({ "playlists": [], "error": e }),
    }
}

/// Recently played playlists first (most recent first), then the catalogue
/// order for everything that has not been played from this device.
fn sort_playlists_by_recent(playlists: &mut [PlaylistItem], recent: &[RecentItem]) {
    let order: std::collections::HashMap<&str, usize> = recent
        .iter()
        .filter(|item| item.item_type == "playlist")
        .enumerate()
        .map(|(index, item)| (item.id.as_str(), index))
        .collect();
    playlists.sort_by_key(|playlist| {
        order
            .get(playlist.id.as_str())
            .copied()
            .unwrap_or(usize::MAX)
    });
}

fn track_page_json(page: TrackPage) -> Value {
    json!({
        "tracks": page.tracks,
        "total": page.total,
        "next_offset": page.next_offset
    })
}

fn track_page_error(error: String) -> Value {
    json!({
        "tracks": [],
        "total": 0,
        "next_offset": null,
        "error": error
    })
}

async fn get_playlist_tracks(state: &AppState, params: PagedIdParams) -> Value {
    match state
        .catalogue
        .get_playlist_tracks_page(&params.id, params.offset, params.limit)
        .await
    {
        Ok(page) => track_page_json(page),
        Err(e) => track_page_error(e),
    }
}

async fn get_playlist_info(state: &AppState, params: IdParams) -> Value {
    match state.catalogue.get_playlist_info(&params.id).await {
        Ok(info) => info,
        Err(e) => json!({ "error": e }),
    }
}

async fn create_playlist(state: &AppState, req: PlaylistCreateRequest) -> Value {
    let title = req.title.trim();
    if title.is_empty() {
        return json!({ "error": "title is required" });
    }
    match state
        .catalogue
        .create_playlist(title, req.description.trim())
        .await
    {
        Ok(playlist) => playlist,
        Err(e) => json!({ "error": e }),
    }
}

async fn update_playlist(state: &AppState, req: PlaylistUpdateRequest) -> Value {
    // Partial updates fall back to the current values, so callers that only
    // rename (or only edit the description) do not have to send both. A
    // privacy-only update skips the metadata call entirely.
    if req.title.is_some() || req.description.is_some() {
        let (title, description) = match (req.title, req.description) {
            (Some(title), Some(description)) => (title, description),
            (title, description) => match state.catalogue.get_playlist_info(&req.id).await {
                Ok(info) => (
                    title.unwrap_or_else(|| {
                        info.get("title")
                            .and_then(|value| value.as_str())
                            .unwrap_or_default()
                            .to_string()
                    }),
                    description.unwrap_or_else(|| {
                        info.get("description")
                            .and_then(|value| value.as_str())
                            .unwrap_or_default()
                            .to_string()
                    }),
                ),
                Err(e) => return json!({ "error": e }),
            },
        };

        if title.trim().is_empty() {
            return json!({ "error": "title is required" });
        }

        if let Err(e) = state
            .catalogue
            .update_playlist(&req.id, title.trim(), description.trim())
            .await
        {
            return json!({ "error": e });
        }
    }

    let mut response = json!({ "ok": true });
    if let Some(public) = req.public {
        if let Err(e) = state.catalogue.set_playlist_public(&req.id, public).await {
            return json!({ "error": e });
        }
        response["public"] = Value::Bool(public);
    }

    response
}

async fn delete_playlist(state: &AppState, req: PlaylistIdRequest) -> Value {
    match state.catalogue.delete_playlist(&req.id).await {
        Ok(ok) => json!({ "ok": ok }),
        Err(e) => json!({ "error": e }),
    }
}

async fn add_playlist_tracks(state: &AppState, req: PlaylistAddRequest) -> Value {
    match state
        .catalogue
        .add_tracks_to_playlist(&req.id, &req.track_ids)
        .await
    {
        Ok(added) => json!({ "ok": true, "added": added }),
        Err(e) => json!({ "error": e }),
    }
}

async fn remove_playlist_tracks(state: &AppState, req: PlaylistRemoveRequest) -> Value {
    match state
        .catalogue
        .remove_playlist_items(&req.id, &req.indices)
        .await
    {
        Ok(ok) => json!({ "ok": ok }),
        Err(e) => json!({ "error": e }),
    }
}

async fn remove_playlist_track(state: &AppState, req: PlaylistRemoveTrackRequest) -> Value {
    match state
        .catalogue
        .remove_playlist_item_by_track(&req.id, &req.track_id)
        .await
    {
        Ok(removed) => json!({ "ok": true, "removed": removed }),
        Err(e) => json!({ "error": e }),
    }
}

async fn move_playlist_track(state: &AppState, req: PlaylistMoveRequest) -> Value {
    match state
        .catalogue
        .move_playlist_item(&req.id, req.from, req.to)
        .await
    {
        Ok(ok) => json!({ "ok": ok }),
        Err(e) => json!({ "error": e }),
    }
}

async fn get_mix_tracks(state: &AppState, params: IdParams) -> Value {
    match state.catalogue.get_mix_tracks(&params.id).await {
        Ok(tracks) => json!({ "tracks": tracks }),
        Err(e) => json!({ "tracks": [], "error": e }),
    }
}

async fn get_favorites(state: &AppState, params: PagedParams) -> Value {
    let limit = u32::try_from(params.limit).unwrap_or(u32::MAX);
    let offset = u32::try_from(params.offset).unwrap_or(u32::MAX);
    match state.catalogue.get_favorites_page(limit, offset).await {
        Ok(page) => track_page_json(page),
        Err(e) => track_page_error(e),
    }
}

/// Toggles an album, artist, or playlist favourite. Track favourites keep
/// going through `playback.action` because `status` mirrors the current
/// track's flag.
async fn toggle_favorite(state: &AppState, req: FavoriteRequest) -> Value {
    let result = match req.item_type.as_str() {
        "album" => state.catalogue.toggle_favorite_album(&req.id).await,
        "artist" => state.catalogue.toggle_favorite_artist(&req.id).await,
        "playlist" => state.catalogue.toggle_favorite_playlist(&req.id).await,
        other => Err(format!("Unsupported favourite type: {other}")),
    };
    match result {
        Ok(favorite) => json!({ "favorite": favorite }),
        Err(e) => json!({ "favorite": null, "error": e }),
    }
}

async fn get_recent(state: &AppState) -> Value {
    // TIDAL's currently available API client exposes activity summaries, not a
    // listening-history feed. Keep a local history of contexts played here.
    let items = state.recent_contexts.read().await.clone();
    json!({ "items": items })
}

async fn record_recent_context(state: &AppState, mut item: RecentItem) {
    if item.title == "Favorite Tracks" {
        item.title = "Tracks".to_string();
    }
    if item.id == "favorites" || item.item_type == "favorites" {
        item.art_url = None;
    }
    let data = {
        let mut items = state.recent_contexts.write().await;
        if !update_recent_contexts(&mut items, item) {
            return;
        }
        serde_json::to_vec(&*items)
    };
    if let Ok(data) = data {
        let path = AuthManager::state_dir().join("recent_contexts.json");
        let tmp = path.with_extension("json.tmp");
        if tokio::fs::write(&tmp, data).await.is_ok() {
            let _ = tokio::fs::rename(&tmp, &path).await;
        }
    }
}

fn update_recent_contexts(items: &mut Vec<RecentItem>, item: RecentItem) -> bool {
    if item.id.is_empty() || item.title.is_empty() {
        return false;
    }
    items.retain(|old| old.item_type != item.item_type || old.id != item.id);
    items.insert(0, item);
    items.truncate(20);
    true
}

async fn get_artist(state: &AppState, params: IdParams) -> Value {
    match state.catalogue.get_artist(&params.id).await {
        Ok(data) => data,
        Err(e) => json!({ "error": e }),
    }
}

async fn get_artist_image(state: &AppState, params: IdParams) -> Value {
    match state.catalogue.get_artist_image_url(&params.id).await {
        Ok(art_url) => json!({ "id": params.id, "art_url": art_url }),
        Err(e) => json!({ "id": params.id, "art_url": null, "error": e }),
    }
}

async fn get_artist_radio(state: &AppState, params: IdParams) -> Value {
    match state.catalogue.get_artist_radio(&params.id).await {
        Ok(tracks) => json!({ "tracks": tracks }),
        Err(e) => json!({ "tracks": [], "error": e }),
    }
}

async fn get_album(state: &AppState, params: AlbumParams) -> Value {
    match state
        .catalogue
        .get_album(&params.id, params.track_limit)
        .await
    {
        Ok(data) => data,
        Err(e) => json!({ "error": e }),
    }
}

async fn get_album_tracks(state: &AppState, params: PagedIdParams) -> Value {
    match state
        .catalogue
        .get_album_tracks_page(&params.id, params.offset, params.limit)
        .await
    {
        Ok(page) => track_page_json(page),
        Err(e) => track_page_error(e),
    }
}

async fn search_catalogue(state: &AppState, params: SearchParams) -> Value {
    match state.catalogue.search(&params.q).await {
        Ok(res) => serde_json::to_value(res).unwrap_or_default(),
        Err(e) => json!({
            "tracks": [], "artists": [], "albums": [], "playlists": [], "error": e
        }),
    }
}

async fn get_lyrics(state: &AppState, params: LyricsParams) -> Value {
    match state
        .catalogue
        .get_lyrics(
            &params.track_id,
            &params.title,
            &params.artist,
            params.duration,
        )
        .await
    {
        Ok(res) => serde_json::to_value(res).unwrap_or_default(),
        Err(e) => json!({ "synced": false, "subtitles": "", "text": "", "error": e }),
    }
}

async fn auth_pkce_start(state: &AppState) -> Value {
    let catalogue = state.catalogue.clone();
    let on_complete = std::sync::Arc::new(move || {
        // Never carry another session's favourites or signed stream URLs into
        // a fresh login.
        catalogue.clear_cache();
    });
    match state.auth.start_pkce_auth(on_complete).await {
        Ok(res) => serde_json::to_value(res).unwrap_or_default(),
        Err(e) => json!({ "error": e }),
    }
}

async fn auth_pkce_complete(state: &AppState, params: AuthPkceCompleteParams) -> Value {
    match state.auth.complete_pkce_auth(&params.redirect_url).await {
        Ok(success) => {
            if success {
                state.catalogue.clear_cache();
            }
            json!({ "success": success })
        }
        Err(e) => json!({ "success": false, "error": e }),
    }
}

async fn auth_pkce_status(state: &AppState) -> Value {
    serde_json::to_value(state.auth.pkce_status().await).unwrap_or_default()
}

async fn auth_pkce_cancel(state: &AppState) -> Value {
    state.auth.cancel_pkce_auth().await;
    json!({ "ok": true })
}

async fn get_auth_profile(state: &AppState) -> Value {
    if !state.auth.is_logged_in().await {
        return json!({ "logged_in": false });
    }
    match state.catalogue.get_user_profile().await {
        Ok(profile) => {
            let email = profile.get("email").and_then(|v| v.as_str()).unwrap_or("");
            let username = profile
                .get("username")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let avatar_url = CatalogueManager::format_art_url(
                profile.get("picture").and_then(|v| v.as_str()),
                320,
            )
            .unwrap_or_default();
            // The account id anchors the web profile link
            // (https://tidal.com/user/<id>) in the widget context menu.
            let user_id = state.auth.tokens.read().await.user_id;
            json!({
                "logged_in": true,
                "id": user_id,
                "email": email,
                "username": username,
                "avatar_url": avatar_url
            })
        }
        Err(e) => json!({ "logged_in": true, "error": e }),
    }
}

async fn auth_logout(state: &AppState) -> Value {
    let _playback_guard = state.playback_command_lock.clone().lock_owned().await;
    state.cast.disconnect_for_logout().await;
    state.player.reset_for_logout();
    state.queue.clear().await;
    state.auth.logout().await;
    state.catalogue.clear_cache();
    {
        state.recent_searches.write().await.clear();
        state.recent_contexts.write().await.clear();
        *state.playback_error.write().await = None;
    }
    let state_dir = AuthManager::state_dir();
    for name in [
        "queue.json",
        "playback.json",
        "recent_searches.json",
        "recent_contexts.json",
    ] {
        let _ = tokio::fs::remove_file(state_dir.join(name)).await;
    }
    json!({ "ok": true })
}

async fn get_recent_searches(state: &AppState) -> Value {
    let searches = state.recent_searches.read().await.clone();
    json!({ "searches": searches })
}

async fn add_recent_search(state: &AppState, req: AddSearchRequest) -> Value {
    if !req.query.trim().is_empty() {
        let q = req.query.trim().to_string();
        let data = {
            let mut list = state.recent_searches.write().await;
            list.retain(|s| s.to_lowercase() != q.to_lowercase());
            list.insert(0, q);
            list.truncate(10);
            serde_json::to_vec(&*list)
        };
        if let Ok(data) = data {
            let path = AuthManager::state_dir().join("recent_searches.json");
            let tmp = path.with_extension("json.tmp");
            if tokio::fs::write(&tmp, data).await.is_ok() {
                let _ = tokio::fs::rename(&tmp, &path).await;
            }
        }
    }
    json!({ "ok": true })
}

async fn clear_recent_searches(state: &AppState) -> Value {
    {
        let mut list = state.recent_searches.write().await;
        list.clear();
    }
    let path = AuthManager::state_dir().join("recent_searches.json");
    let _ = tokio::fs::remove_file(path).await;
    json!({ "ok": true })
}

/// Routes one request to its handler. Transport-level failures (unknown
/// method, malformed params) are `Err`; handler-level failures keep the
/// existing `{ "error": ... }` result shape so the UI can show partial data.
pub async fn dispatch(state: &AppState, method: &str, params: Value) -> Result<Value, String> {
    let result = match method {
        "status" => status_json(state, true, true).await,
        "playback.action" => handle_action(state, decode(params)?).await,
        "playback.play" => handle_play(state, decode(params)?).await,
        "queue.get" => get_queue(state).await,
        "queue.append" => append_queue(state, decode(params)?).await,
        "cast.devices" => get_cast_devices(state, decode(params)?).await,
        "cast.connect" => cast_connect(state, decode(params)?).await,
        "cast.disconnect" => cast_disconnect(state).await,
        "library.mixes" => get_mixes(state).await,
        "library.playlists" => get_playlists(state).await,
        "library.albums" => get_user_albums(state).await,
        "library.artists" => get_user_artists(state).await,
        "library.playlist" => get_playlist_tracks(state, decode(params)?).await,
        "library.playlist.info" => get_playlist_info(state, decode(params)?).await,
        "library.playlist.create" => create_playlist(state, decode(params)?).await,
        "library.playlist.update" => update_playlist(state, decode(params)?).await,
        "library.playlist.delete" => delete_playlist(state, decode(params)?).await,
        "library.playlist.add" => add_playlist_tracks(state, decode(params)?).await,
        "library.playlist.remove" => remove_playlist_tracks(state, decode(params)?).await,
        "library.playlist.remove_track" => remove_playlist_track(state, decode(params)?).await,
        "library.playlist.move" => move_playlist_track(state, decode(params)?).await,
        "library.mix" => get_mix_tracks(state, decode(params)?).await,
        "library.favorites" => get_favorites(state, decode(params)?).await,
        "library.favorite" => toggle_favorite(state, decode(params)?).await,
        "library.recent" => get_recent(state).await,
        "artist" => get_artist(state, decode(params)?).await,
        "artist.image" => get_artist_image(state, decode(params)?).await,
        "artist.radio" => get_artist_radio(state, decode(params)?).await,
        "album" => get_album(state, decode(params)?).await,
        "album.tracks" => get_album_tracks(state, decode(params)?).await,
        "search" => search_catalogue(state, decode(params)?).await,
        "lyrics" => get_lyrics(state, decode(params)?).await,
        "auth.pkce.start" => auth_pkce_start(state).await,
        "auth.pkce.complete" => auth_pkce_complete(state, decode(params)?).await,
        "auth.pkce.status" => auth_pkce_status(state).await,
        "auth.pkce.cancel" => auth_pkce_cancel(state).await,
        "auth.profile" => get_auth_profile(state).await,
        "auth.logout" => auth_logout(state).await,
        "library.searches.recent" => get_recent_searches(state).await,
        "library.searches.recent.add" => add_recent_search(state, decode(params)?).await,
        "library.searches.recent.clear" => clear_recent_searches(state).await,
        other => return Err(format!("unknown method: {other}")),
    };
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::{sort_playlists_by_recent, update_recent_contexts};
    use crate::catalogue::{PlaylistItem, RecentItem};

    fn playlist(id: &str) -> PlaylistItem {
        PlaylistItem {
            id: id.into(),
            title: format!("playlist {id}"),
            description: None,
            art_url: None,
            track_count: None,
        }
    }

    fn recent(item_type: &str, id: &str) -> RecentItem {
        RecentItem {
            id: id.into(),
            title: format!("{item_type} {id}"),
            subtitle: None,
            item_type: item_type.into(),
            art_url: None,
            own: None,
        }
    }

    #[test]
    fn playlists_sort_by_recent_playlist_contexts_and_keep_the_rest() {
        let mut playlists = vec![playlist("a"), playlist("b"), playlist("c")];
        let recent = vec![
            recent("album", "b"),
            recent("playlist", "c"),
            recent("playlist", "a"),
        ];
        sort_playlists_by_recent(&mut playlists, &recent);
        assert_eq!(
            playlists
                .iter()
                .map(|playlist| playlist.id.as_str())
                .collect::<Vec<_>>(),
            vec!["c", "a", "b"]
        );
    }

    #[test]
    fn recent_contexts_move_duplicates_to_the_front_and_keep_types_distinct() {
        let mut items = vec![recent("playlist", "1"), recent("album", "1")];
        assert!(update_recent_contexts(&mut items, recent("playlist", "1")));
        assert_eq!(items[0].item_type, "playlist");
        assert_eq!(items[1].item_type, "album");
    }

    #[test]
    fn recent_contexts_reject_invalid_items_and_keep_twenty() {
        let mut items = Vec::new();
        assert!(!update_recent_contexts(&mut items, recent("playlist", "")));
        for index in 0..25 {
            assert!(update_recent_contexts(
                &mut items,
                recent("playlist", &index.to_string())
            ));
        }
        assert_eq!(items.len(), 20);
        assert_eq!(items[0].id, "24");
        assert_eq!(items[19].id, "5");
    }
}
