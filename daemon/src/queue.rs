use serde::{Deserialize, Serialize};
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc,
};
use tokio::sync::RwLock;

static SHUFFLE_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub struct ArtistCredit {
    pub id: Option<String>,
    pub name: String,
}

/// A track handed to the playback loop together with the player's pause
/// generation at request time. If the user pauses (or stops) before the stream
/// is ready, the changed generation cancels the request instead of starting
/// playback over the pause.
#[derive(Debug, Clone)]
pub struct QueuedPlay {
    pub track: TrackItem,
    pub pause_generation: u64,
    /// A cast hand-off loading the parked track back onto this machine, not a
    /// playback attempt. It must not clear the user-visible error state: the
    /// notice recorded alongside it (why playback moved) is still current.
    pub handoff: bool,
}

impl QueuedPlay {
    pub fn new(track: TrackItem, pause_generation: u64) -> Self {
        Self {
            track,
            pause_generation,
            handoff: false,
        }
    }

    pub fn for_handoff(track: TrackItem, pause_generation: u64) -> Self {
        Self {
            track,
            pause_generation,
            handoff: true,
        }
    }
}

fn default_available() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TrackItem {
    pub id: String,
    pub title: String,
    pub artist: String,
    #[serde(default)]
    pub album: String,
    #[serde(default)]
    pub artist_id: Option<String>,
    #[serde(default)]
    pub artists: Vec<ArtistCredit>,
    #[serde(default)]
    pub album_id: Option<String>,
    #[serde(default)]
    pub duration: f64,
    #[serde(default)]
    pub art_url: Option<String>,
    /// TIDAL animated cover (short silent MP4 loop), when the release has one.
    #[serde(default)]
    pub video_url: Option<String>,
    #[serde(default)]
    pub audio_quality: Option<String>,
    #[serde(default)]
    pub explicit: bool,
    /// False when TIDAL marks the track unplayable in the user's region
    /// (`allowStreaming: false` or `streamReady: false`). Lists render these
    /// rows dimmed and disabled, and the play queue skips them.
    #[serde(default = "default_available")]
    pub available: bool,
    #[serde(default)]
    pub tlid: Option<u64>,
    /// Raw position of the item in its source TIDAL playlist, filled in by
    /// the playlist fetch only. The parser drops unplayable items, so the
    /// track's position in the returned list is not the index TIDAL's
    /// item mutations address; this is. `None` everywhere else.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item_index: Option<usize>,
}

impl Default for TrackItem {
    fn default() -> Self {
        Self {
            id: String::new(),
            title: String::new(),
            artist: String::new(),
            album: String::new(),
            artist_id: None,
            artists: Vec::new(),
            album_id: None,
            duration: 0.0,
            art_url: None,
            video_url: None,
            audio_quality: None,
            explicit: false,
            available: true,
            tlid: None,
            item_index: None,
        }
    }
}

/// The static queue: the tracks that were loaded and the order they are in.
/// The current track, playhead, volume, shuffle and repeat live in
/// `playback.json`, so `queue.json` is only rewritten when the list itself
/// changes — not on every next/previous/jump.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueueSnapshot {
    pub tracks: Vec<TrackItem>,
    #[serde(default)]
    pub default_tracks: Vec<TrackItem>,
    #[serde(default = "default_context")]
    pub playing_context: String,
    #[serde(default)]
    pub context_ref: Option<serde_json::Value>,
}

fn default_context() -> String {
    "Top Tracks".to_string()
}

impl Default for QueueSnapshot {
    fn default() -> Self {
        Self {
            tracks: Vec::new(),
            default_tracks: Vec::new(),
            playing_context: default_context(),
            context_ref: None,
        }
    }
}

/// The live queue. `current_index`, `repeat_mode` and `shuffle` are runtime
/// state restored from `playback.json`; `QueueSnapshot` is what
/// `queue.json` holds.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct QueueState {
    pub tracks: Vec<TrackItem>,
    pub default_tracks: Vec<TrackItem>,
    pub current_index: usize,
    pub repeat_mode: String, // "off", "all", "track"
    pub shuffle: bool,
    pub playing_context: String,
    pub context_ref: Option<serde_json::Value>,
}

fn next_seed() -> u64 {
    let mut seed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_nanos() as u64)
        .unwrap_or(0x9e3779b97f4a7c15)
        ^ SHUFFLE_COUNTER
            .fetch_add(1, Ordering::Relaxed)
            .wrapping_mul(0x9e3779b97f4a7c15);
    if seed == 0 {
        seed = 0x2545f4914f6cdd1d;
    }
    seed
}

fn next_prng(state: &mut u64) -> u64 {
    let mut x = *state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    *state = x;
    x.wrapping_mul(0x2545f4914f6cdd1d)
}

fn shuffle_slice<T>(slice: &mut [T]) {
    let mut rng = next_seed();
    for i in (1..slice.len()).rev() {
        let j = (next_prng(&mut rng) as usize) % (i + 1);
        slice.swap(i, j);
    }
}

fn normalize_repeat_mode(mode: &str) -> String {
    match mode {
        "all" | "track" => mode.to_string(),
        _ => "off".to_string(),
    }
}

fn next_tlid(state: &QueueState) -> u64 {
    state
        .tracks
        .iter()
        .chain(state.default_tracks.iter())
        .filter_map(|t| t.tlid)
        .max()
        .unwrap_or(0)
        + 1
}

impl Default for QueueState {
    fn default() -> Self {
        Self {
            tracks: Vec::new(),
            default_tracks: Vec::new(),
            current_index: 0,
            repeat_mode: "off".to_string(),
            shuffle: false,
            playing_context: "Top Tracks".to_string(),
            context_ref: None,
        }
    }
}

pub struct QueueManager {
    state: Arc<RwLock<QueueState>>,
    // Set when the list itself changes; the daemon's persistence task writes
    // `queue.json` once and clears it. Kept separate from the state lock so
    // the periodic writer never contends with playback.
    dirty: AtomicBool,
    // Set when shuffle or repeat changes. Those live in `playback.json`,
    // so this asks the player-state writer to run; it does not rewrite the
    // queue file.
    settings_dirty: AtomicBool,
    // Bumped when the list, its order or its context changes. The RPC event
    // publisher watches this instead of cloning a potentially huge queue on
    // every tick; a selection move is carried by the status snapshot's
    // `current_tlid`, so it does not need a queue refetch.
    revision: AtomicU64,
}

impl QueueManager {
    pub fn new() -> Self {
        Self {
            state: Arc::new(RwLock::new(QueueState::default())),
            dirty: AtomicBool::new(false),
            settings_dirty: AtomicBool::new(false),
            revision: AtomicU64::new(0),
        }
    }

    fn mark_dirty(&self) {
        self.dirty.store(true, Ordering::SeqCst);
        self.revision.fetch_add(1, Ordering::SeqCst);
    }

    fn mark_settings_dirty(&self) {
        self.settings_dirty.store(true, Ordering::SeqCst);
    }

    /// True when the in-memory queue changed since the last persisted write.
    pub fn take_dirty(&self) -> bool {
        self.dirty.swap(false, Ordering::SeqCst)
    }

    /// True when shuffle/repeat changed since the player state was written.
    pub fn take_settings_dirty(&self) -> bool {
        self.settings_dirty.swap(false, Ordering::SeqCst)
    }

    /// Monotonic list revision. The RPC event publisher compares this instead
    /// of cloning the queue; selection moves are carried by the status
    /// snapshot's `current_tlid` and do not bump it.
    pub fn revision(&self) -> u64 {
        self.revision.load(Ordering::SeqCst)
    }

    /// Empties the queue and context metadata (used on logout so the next
    /// account never inherits the previous session's tracks).
    pub async fn clear(&self) {
        let mut state = self.state.write().await;
        state.tracks.clear();
        state.default_tracks.clear();
        state.current_index = 0;
        state.playing_context.clear();
        state.context_ref = None;
        self.mark_dirty();
    }

    /// The static list to persist in `queue.json`.
    pub async fn snapshot(&self) -> QueueSnapshot {
        let state = self.state.read().await;
        QueueSnapshot {
            tracks: state.tracks.clone(),
            default_tracks: state.default_tracks.clone(),
            playing_context: state.playing_context.clone(),
            context_ref: state.context_ref.clone(),
        }
    }

    /// Replaces the queue from a persisted snapshot after startup. The caller
    /// then selects the track named by `playback.json`; the stream stays
    /// stopped until Play. Settings are restored without replaying the
    /// shuffle toggle, so the persisted order is kept exactly.
    pub async fn restore(
        &self,
        snapshot: QueueSnapshot,
        shuffle: bool,
        repeat_mode: &str,
    ) -> Option<TrackItem> {
        // Settings are restored even when the queue file is gone: the caller
        // may still rebuild the queue around a persisted player track.
        let state = QueueState {
            default_tracks: if snapshot.default_tracks.is_empty() {
                snapshot.tracks.clone()
            } else {
                snapshot.default_tracks
            },
            tracks: snapshot.tracks,
            current_index: 0,
            repeat_mode: normalize_repeat_mode(repeat_mode),
            shuffle,
            playing_context: snapshot.playing_context,
            context_ref: snapshot.context_ref,
        };
        let current = state.tracks.first().cloned();
        *self.state.write().await = state;
        self.dirty.store(false, Ordering::SeqCst);
        self.settings_dirty.store(false, Ordering::SeqCst);
        current
    }

    /// Selects the track the persisted player state named. If the queue no
    /// longer contains it — only possible when the queue was replaced or lost
    /// while the player state still named the old track — the queue is rebuilt
    /// around that one track instead of silently starting somewhere else.
    pub async fn restore_selection(&self, track: Option<&TrackItem>) -> Option<TrackItem> {
        let Some(track) = track else {
            return self.get_current_track().await;
        };
        let mut state = self.state.write().await;
        if let Some(index) = state.tracks.iter().position(|candidate| {
            if track.tlid.is_some() && candidate.tlid.is_some() {
                candidate.tlid == track.tlid
            } else {
                candidate.id == track.id
            }
        }) {
            state.current_index = index;
            return state.tracks.get(index).cloned();
        }
        state.tracks = vec![track.clone()];
        state.default_tracks = vec![track.clone()];
        state.current_index = 0;
        state.context_ref = None;
        self.mark_dirty();
        Some(track.clone())
    }

    /// Shuffle and repeat, which belong to the player state rather than the
    /// static queue file.
    pub async fn playback_settings(&self) -> (bool, String) {
        let state = self.state.read().await;
        (state.shuffle, state.repeat_mode.clone())
    }

    pub async fn set_queue(
        &self,
        tracks: Vec<TrackItem>,
        start_index: usize,
        context: Option<String>,
    ) -> Option<TrackItem> {
        // Keep only playable tracks in the queue, remapping `start_index` so
        // clicking a track after an unavailable row still starts the same song.
        // If every track in a non-empty list is unavailable, leave the current
        // queue untouched instead of clearing it.
        let had_tracks = !tracks.is_empty();
        let mut playable = Vec::with_capacity(tracks.len());
        let mut idx: Option<usize> = None;
        for (i, track) in tracks.into_iter().enumerate() {
            if !track.available {
                continue;
            }
            if idx.is_none() && i >= start_index {
                idx = Some(playable.len());
            }
            playable.push(track);
        }
        if had_tracks && playable.is_empty() {
            return None;
        }
        let mut tracks = playable;

        let mut state = self.state.write().await;
        self.mark_dirty();
        let mut idx = idx.unwrap_or(0);

        // Assign synthetic tlids
        for (i, t) in tracks.iter_mut().enumerate() {
            t.tlid = Some((i + 1) as u64);
        }

        if idx >= tracks.len() {
            idx = 0;
        }

        state.default_tracks = tracks.clone();
        if let Some(ctx) = context {
            state.playing_context = ctx;
        }
        state.context_ref = None;

        if state.shuffle && tracks.len() > 1 {
            let current = tracks.remove(idx);
            let mut remaining = tracks;
            shuffle_slice(&mut remaining);
            let mut final_tracks = Vec::with_capacity(remaining.len() + 1);
            final_tracks.push(current);
            final_tracks.extend(remaining);
            state.tracks = final_tracks;
            state.current_index = 0;
        } else {
            state.tracks = tracks;
            state.current_index = idx;
        }

        state.tracks.get(state.current_index).cloned()
    }

    pub async fn set_context_ref(&self, context_ref: Option<serde_json::Value>) {
        self.state.write().await.context_ref = context_ref;
        self.mark_dirty();
    }

    pub async fn get_current_track(&self) -> Option<TrackItem> {
        let state = self.state.read().await;
        state.tracks.get(state.current_index).cloned()
    }

    /// The track `next_track` would select, without moving the queue. Used to
    /// preload the next stream into mpv's playlist while the current one plays.
    pub async fn peek_next_track(&self) -> Option<TrackItem> {
        let state = self.state.read().await;
        if state.tracks.is_empty() {
            return None;
        }
        if state.repeat_mode == "track" {
            return state.tracks.get(state.current_index).cloned();
        }
        let next_idx = state.current_index + 1;
        if next_idx < state.tracks.len() {
            state.tracks.get(next_idx).cloned()
        } else if state.repeat_mode == "all" {
            state.tracks.first().cloned()
        } else {
            None
        }
    }

    pub async fn next_track(&self) -> Option<TrackItem> {
        let mut state = self.state.write().await;
        if state.tracks.is_empty() {
            return None;
        }

        if state.repeat_mode == "track" {
            return state.tracks.get(state.current_index).cloned();
        }

        let next_idx = state.current_index + 1;
        if next_idx < state.tracks.len() {
            state.current_index = next_idx;
            state.tracks.get(next_idx).cloned()
        } else if state.repeat_mode == "all" {
            state.current_index = 0;
            state.tracks.first().cloned()
        } else {
            None
        }
    }

    /// A user-pressed next. Unlike the EOS advance (`next_track`), this leaves
    /// repeat-song when it lands on a different track. At the end of the queue
    /// it is a no-op, so a repeat-song loop keeps running.
    pub async fn next_track_for_user(&self) -> Option<TrackItem> {
        let mut state = self.state.write().await;
        if state.tracks.is_empty() {
            return None;
        }

        let next_idx = state.current_index + 1;
        let target_idx = if next_idx < state.tracks.len() {
            next_idx
        } else if state.repeat_mode == "all" {
            0
        } else {
            return None;
        };

        if state.repeat_mode == "track" {
            state.repeat_mode = "off".to_string();
            self.mark_settings_dirty();
        }
        state.current_index = target_idx;
        state.tracks.get(target_idx).cloned()
    }

    /// A user-pressed previous (there is no automatic backward advance). Leaves
    /// repeat-song only when it moves to a different track: at the head of the
    /// queue it restarts the current track instead, keeping the loop setting.
    pub async fn prev_track_for_user(&self) -> Option<TrackItem> {
        let mut state = self.state.write().await;
        if state.tracks.is_empty() {
            return None;
        }

        if state.current_index > 0 {
            state.current_index -= 1;
            if state.repeat_mode == "track" {
                state.repeat_mode = "off".to_string();
                self.mark_settings_dirty();
            }
            state.tracks.get(state.current_index).cloned()
        } else if state.repeat_mode == "all" {
            let last_idx = state.tracks.len() - 1;
            state.current_index = last_idx;
            state.tracks.get(last_idx).cloned()
        } else {
            state.tracks.first().cloned()
        }
    }

    pub async fn jump_to(&self, index: usize) -> Option<TrackItem> {
        let mut state = self.state.write().await;
        if index < state.tracks.len() {
            state.current_index = index;
            state.tracks.get(index).cloned()
        } else {
            None
        }
    }

    pub async fn append(&self, mut new_tracks: Vec<TrackItem>) {
        new_tracks.retain(|t| t.available);
        if new_tracks.is_empty() {
            return;
        }
        let mut state = self.state.write().await;
        let start_tlid = next_tlid(&state);
        for (i, t) in new_tracks.iter_mut().enumerate() {
            t.tlid = Some(start_tlid + i as u64);
        }
        state.default_tracks.extend(new_tracks.clone());
        state.tracks.extend(new_tracks);
        self.mark_dirty();
    }

    pub async fn play_next(&self, mut track: TrackItem) {
        if !track.available {
            return;
        }
        let mut state = self.state.write().await;
        let insert_idx = if state.tracks.is_empty() {
            0
        } else {
            (state.current_index + 1).min(state.tracks.len())
        };
        track.tlid = Some(next_tlid(&state));
        state.tracks.insert(insert_idx, track.clone());

        let default_idx = if let Some(current) = state.tracks.get(state.current_index) {
            state
                .default_tracks
                .iter()
                .position(|t| {
                    if current.tlid.is_some() && t.tlid.is_some() {
                        t.tlid == current.tlid
                    } else {
                        t.id == current.id
                    }
                })
                .map(|p| p + 1)
                .unwrap_or(state.default_tracks.len())
        } else {
            state.default_tracks.len()
        };
        state.default_tracks.insert(default_idx, track);
        self.mark_dirty();
    }

    pub async fn set_repeat(&self, mode: &str) {
        let mut state = self.state.write().await;
        state.repeat_mode = normalize_repeat_mode(mode);
        self.mark_settings_dirty();
    }

    pub async fn set_shuffle(&self, enabled: bool) {
        let mut state = self.state.write().await;
        if state.shuffle == enabled {
            return;
        }
        state.shuffle = enabled;
        self.mark_settings_dirty();
        // Toggling shuffle reorders the live list, so the static queue changed
        // too (the persisted order has to match the flag on restart).
        self.mark_dirty();

        if state.tracks.is_empty() {
            return;
        }

        if enabled {
            // Shuffle toggled ON:
            // "whenever shuffle is toggle on, all the songs in the currently queue are shuffled once."
            let current_opt = state.tracks.get(state.current_index).cloned();
            if let Some(current) = current_opt {
                let mut remaining: Vec<TrackItem> = if !state.default_tracks.is_empty() {
                    state.default_tracks.clone()
                } else {
                    state.tracks.clone()
                };
                if let Some(pos) = remaining.iter().position(|t| {
                    if current.tlid.is_some() && t.tlid.is_some() {
                        t.tlid == current.tlid
                    } else {
                        t.id == current.id
                    }
                }) {
                    remaining.remove(pos);
                }
                shuffle_slice(&mut remaining);

                let mut shuffled = Vec::with_capacity(remaining.len() + 1);
                shuffled.push(current);
                shuffled.extend(remaining);
                state.tracks = shuffled;
                state.current_index = 0;
            } else {
                shuffle_slice(&mut state.tracks);
                state.current_index = 0;
            }
        } else {
            // Shuffle toggled OFF:
            // "And if shuffle is toggles off then they go back to their initial default ordering."
            if !state.default_tracks.is_empty() {
                let current_opt = state.tracks.get(state.current_index).cloned();
                state.tracks = state.default_tracks.clone();
                if let Some(current) = current_opt {
                    let new_idx = state
                        .tracks
                        .iter()
                        .position(|t| {
                            if current.tlid.is_some() && t.tlid.is_some() {
                                t.tlid == current.tlid
                            } else {
                                t.id == current.id
                            }
                        })
                        .unwrap_or(0);
                    state.current_index = new_idx;
                } else if state.current_index >= state.tracks.len() {
                    state.current_index = 0;
                }
            }
        }
    }

    pub async fn get_state(&self) -> QueueState {
        self.state.read().await.clone()
    }

    /// Lightweight snapshot for the 100 ms MPRIS property watcher so it never
    /// deep-clones the entire queue on every tick.
    pub async fn mpris_snapshot(&self) -> (Option<TrackItem>, String, bool, bool, bool) {
        let state = self.state.read().await;
        let current = state.tracks.get(state.current_index).cloned();
        let can_next = !state.tracks.is_empty()
            && (state.repeat_mode == "all" || state.current_index + 1 < state.tracks.len());
        let can_prev =
            !state.tracks.is_empty() && (state.current_index > 0 || state.repeat_mode == "all");
        (
            current,
            state.repeat_mode.clone(),
            state.shuffle,
            can_next,
            can_prev,
        )
    }

    /// Returns whether a distinct next track can be played.
    /// Respects repeat modes and queue length.
    pub async fn can_go_next(&self) -> bool {
        let state = self.state.read().await;
        if state.tracks.is_empty() {
            return false;
        }
        if state.repeat_mode == "all" {
            return true;
        }
        state.current_index + 1 < state.tracks.len()
    }

    /// Returns whether a previous track action would navigate to a different track.
    pub async fn can_go_previous(&self) -> bool {
        let state = self.state.read().await;
        if state.tracks.is_empty() {
            return false;
        }
        if state.current_index > 0 {
            return true;
        }
        state.repeat_mode == "all"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_queue_navigation_and_repeat() {
        let q = QueueManager::new();
        let t1 = TrackItem {
            id: "1".into(),
            title: "Track 1".into(),
            artist: "Artist".into(),
            ..Default::default()
        };
        let t2 = TrackItem {
            id: "2".into(),
            title: "Track 2".into(),
            artist: "Artist".into(),
            ..Default::default()
        };

        let first = q
            .set_queue(vec![t1.clone(), t2.clone()], 0, Some("Test".into()))
            .await;
        assert_eq!(first.unwrap().title, "Track 1");

        let cur = q.get_current_track().await;
        assert_eq!(cur.unwrap().title, "Track 1");

        let next = q.next_track().await;
        assert_eq!(next.unwrap().title, "Track 2");

        // End of queue with repeat off
        let end = q.next_track().await;
        assert!(end.is_none());

        // Repeat all
        q.set_repeat("all").await;
        let looped = q.next_track().await;
        assert_eq!(looped.unwrap().title, "Track 1");

        // Repeat track
        q.set_repeat("track").await;
        let same = q.next_track().await;
        assert_eq!(same.unwrap().title, "Track 1");
    }

    fn numbered_tracks(count: usize) -> Vec<TrackItem> {
        (0..count)
            .map(|index| TrackItem {
                id: format!("track_{index}"),
                title: format!("Track {index}"),
                artist: "Artist".into(),
                ..Default::default()
            })
            .collect()
    }

    #[tokio::test]
    async fn user_next_skips_forward_and_leaves_repeat_track() {
        let q = QueueManager::new();
        q.set_queue(numbered_tracks(3), 0, None).await;
        q.set_repeat("track").await;

        // End of stream still repeats the current track.
        let eos = q.next_track().await.unwrap();
        assert_eq!(eos.id, "track_0");
        assert_eq!(q.get_state().await.repeat_mode, "track");

        // A user skip moves to the next row and clears repeat-song.
        let next = q.next_track_for_user().await.unwrap();
        assert_eq!(next.id, "track_1");
        assert_eq!(q.get_state().await.repeat_mode, "off");
    }

    #[tokio::test]
    async fn user_next_at_the_queue_end_is_a_noop_and_keeps_repeat_track() {
        let q = QueueManager::new();
        q.set_queue(numbered_tracks(2), 1, None).await;
        q.set_repeat("track").await;

        assert!(q.next_track_for_user().await.is_none());
        let state = q.get_state().await;
        assert_eq!(state.current_index, 1);
        assert_eq!(state.repeat_mode, "track");
    }

    #[tokio::test]
    async fn user_next_wraps_at_the_end_under_repeat_all() {
        let q = QueueManager::new();
        q.set_queue(numbered_tracks(3), 2, None).await;
        q.set_repeat("all").await;

        let next = q.next_track_for_user().await.unwrap();
        assert_eq!(next.id, "track_0");
        assert_eq!(q.get_state().await.current_index, 0);
        assert_eq!(q.get_state().await.repeat_mode, "all");
    }

    #[tokio::test]
    async fn user_previous_moves_back_and_leaves_repeat_track() {
        let q = QueueManager::new();
        q.set_queue(numbered_tracks(3), 1, None).await;
        q.set_repeat("track").await;

        let previous = q.prev_track_for_user().await.unwrap();
        assert_eq!(previous.id, "track_0");
        assert_eq!(q.get_state().await.repeat_mode, "off");
    }

    #[tokio::test]
    async fn user_previous_at_the_head_restarts_and_keeps_repeat_track() {
        let q = QueueManager::new();
        q.set_queue(numbered_tracks(2), 0, None).await;
        q.set_repeat("track").await;

        let previous = q.prev_track_for_user().await.unwrap();
        assert_eq!(previous.id, "track_0");
        assert_eq!(q.get_state().await.current_index, 0);
        assert_eq!(q.get_state().await.repeat_mode, "track");
    }

    #[tokio::test]
    async fn shuffle_never_immediately_repeats_current_track() {
        let q = QueueManager::new();
        let tracks = (0..8)
            .map(|index| TrackItem {
                id: index.to_string(),
                title: format!("Track {index}"),
                artist: "Artist".into(),
                ..Default::default()
            })
            .collect();
        q.set_queue(tracks, 0, None).await;
        q.set_shuffle(true).await;
        q.set_repeat("all").await;

        for _ in 0..20 {
            let current = q.get_current_track().await.unwrap();
            let next = q.next_track().await.unwrap();
            assert_ne!(next.id, current.id);
        }
    }

    #[tokio::test]
    async fn shuffle_previous_returns_the_last_played_track() {
        let q = QueueManager::new();
        let tracks = (0..8)
            .map(|index| TrackItem {
                id: index.to_string(),
                title: format!("Track {index}"),
                artist: "Artist".into(),
                ..Default::default()
            })
            .collect();
        q.set_queue(tracks, 0, None).await;
        q.set_shuffle(true).await;

        let first = q.get_current_track().await.unwrap();
        q.next_track().await.unwrap();
        let previous = q.prev_track_for_user().await.unwrap();
        assert_eq!(previous.id, first.id);
    }

    #[tokio::test]
    async fn queue_snapshot_round_trips_and_restores_across_restarts() {
        let q = QueueManager::new();
        let tracks: Vec<TrackItem> = (0..5)
            .map(|i| TrackItem {
                id: format!("track_{i}"),
                title: format!("Track {i}"),
                artist: "Artist".into(),
                ..Default::default()
            })
            .collect();
        q.set_queue(tracks, 3, Some("Album".into())).await;
        q.set_repeat("all").await;
        q.set_shuffle(true).await;
        q.jump_to(1).await;
        let snapshot = q.snapshot().await;
        let current = q.get_current_track().await.unwrap();

        // This is exactly what queue.json holds between boots: the list and
        // its order, with none of the playback state.
        let json = serde_json::to_string(&snapshot).unwrap();
        let raw: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert!(raw.get("current_index").is_none());
        assert!(raw.get("repeat_mode").is_none());
        assert!(raw.get("shuffle").is_none());
        let decoded: QueueSnapshot = serde_json::from_str(&json).unwrap();

        let restored = QueueManager::new();
        restored.restore(decoded, true, "all").await.unwrap();
        let current_after = restored.restore_selection(Some(&current)).await.unwrap();
        let state = restored.get_state().await;

        assert_eq!(current_after.tlid, current.tlid);
        assert_eq!(state.tracks, snapshot.tracks);
        assert_eq!(
            state.current_index,
            state
                .tracks
                .iter()
                .position(|track| track.tlid == current.tlid)
                .unwrap()
        );
        assert_eq!(state.repeat_mode, "all");
        assert!(state.shuffle);
        assert_eq!(state.playing_context, "Album");
        // Restoring is not a mutation: neither persistence task writes the
        // same files straight back.
        assert!(!restored.take_dirty());
        assert!(!restored.take_settings_dirty());
    }

    #[tokio::test]
    async fn restore_applies_settings_without_a_queue_file() {
        let q = QueueManager::new();
        assert!(q
            .restore(QueueSnapshot::default(), true, "track")
            .await
            .is_none());
        let (shuffle, repeat_mode) = q.playback_settings().await;
        assert!(shuffle);
        assert_eq!(repeat_mode, "track");
        assert!(!q.take_dirty());
        assert!(!q.take_settings_dirty());
    }

    #[tokio::test]
    async fn restore_selection_rebuilds_the_queue_when_the_track_is_gone() {
        let q = QueueManager::new();
        let tracks: Vec<TrackItem> = (0..2)
            .map(|i| TrackItem {
                id: format!("track_{i}"),
                title: format!("Track {i}"),
                artist: "Artist".into(),
                ..Default::default()
            })
            .collect();
        q.set_queue(tracks, 0, Some("Album".into())).await;
        let _ = q.take_dirty();

        let lost = TrackItem {
            id: "elsewhere".into(),
            title: "Elsewhere".into(),
            artist: "Artist".into(),
            ..Default::default()
        };
        let selected = q.restore_selection(Some(&lost)).await.unwrap();
        let state = q.get_state().await;

        assert_eq!(selected.id, "elsewhere");
        assert_eq!(state.tracks.len(), 1);
        assert_eq!(state.tracks[0].id, "elsewhere");
        assert_eq!(state.current_index, 0);
        // The rebuilt queue must be persisted.
        assert!(q.take_dirty());
    }

    #[tokio::test]
    async fn restore_selection_finds_the_track_by_tlid() {
        let q = QueueManager::new();
        let tracks: Vec<TrackItem> = (0..3)
            .map(|i| TrackItem {
                id: format!("track_{i}"),
                title: format!("Track {i}"),
                artist: "Artist".into(),
                ..Default::default()
            })
            .collect();
        q.set_queue(tracks, 0, None).await;
        let _ = q.take_dirty();

        let second = q.get_state().await.tracks[1].clone();
        let selected = q.restore_selection(Some(&second)).await.unwrap();
        assert_eq!(selected.tlid, second.tlid);
        assert_eq!(q.get_state().await.current_index, 1);
        // Selecting has no effect on what is persisted in queue.json.
        assert!(!q.take_dirty());
    }

    #[tokio::test]
    async fn navigation_does_not_rewrite_the_static_queue() {
        let q = QueueManager::new();
        let tracks: Vec<TrackItem> = (0..3)
            .map(|i| TrackItem {
                id: format!("track_{i}"),
                title: format!("Track {i}"),
                artist: "Artist".into(),
                ..Default::default()
            })
            .collect();

        assert!(!q.take_dirty());
        q.set_queue(tracks, 0, None).await;
        assert!(q.take_dirty());
        assert!(!q.take_dirty());

        q.next_track().await;
        q.jump_to(2).await;
        assert!(!q.take_dirty());
        assert!(!q.take_settings_dirty());

        // Repeat and shuffle belong to playback.json: repeat only dirties
        // the settings; shuffle also reorders the list.
        q.set_repeat("all").await;
        assert!(!q.take_dirty());
        assert!(q.take_settings_dirty());

        q.set_shuffle(true).await;
        assert!(q.take_dirty());
        assert!(q.take_settings_dirty());

        // A user skip that leaves repeat-song changes the setting too.
        q.set_repeat("track").await;
        let _ = q.take_settings_dirty();
        q.jump_to(0).await;
        q.next_track_for_user().await;
        assert!(!q.take_dirty());
        assert!(q.take_settings_dirty());
    }

    #[tokio::test]
    async fn test_shuffle_toggle_and_unshuffle() {
        let q = QueueManager::new();
        let tracks: Vec<TrackItem> = (0..5)
            .map(|i| TrackItem {
                id: format!("track_{i}"),
                title: format!("Track {i}"),
                artist: "Artist".into(),
                tlid: Some((i + 1) as u64),
                ..Default::default()
            })
            .collect();

        // Start playing track 2 (3rd track)
        q.set_queue(tracks.clone(), 2, Some("Album".into())).await;
        let cur = q.get_current_track().await.unwrap();
        assert_eq!(cur.id, "track_2");

        // Toggle shuffle ON
        q.set_shuffle(true).await;
        let cur_shuffled = q.get_current_track().await.unwrap();
        // Current track remains track 2
        assert_eq!(cur_shuffled.id, "track_2");
        let state = q.get_state().await;
        assert_eq!(state.current_index, 0);
        assert_eq!(state.tracks.len(), 5);
        assert_eq!(state.tracks[0].id, "track_2");

        // Advance to next track in shuffled queue
        let next_track = q.next_track().await.unwrap();
        assert_ne!(next_track.id, "track_2");

        // Toggle shuffle OFF
        q.set_shuffle(false).await;
        let cur_unshuffled = q.get_current_track().await.unwrap();
        assert_eq!(cur_unshuffled.id, next_track.id);
        let state_unshuffled = q.get_state().await;
        // Reverts back to initial default ordering
        assert_eq!(state_unshuffled.tracks, tracks);
        assert_eq!(
            state_unshuffled.tracks[state_unshuffled.current_index].id,
            next_track.id
        );
    }

    #[tokio::test]
    async fn set_queue_skips_unavailable_tracks_and_remaps_start_index() {
        let q = QueueManager::new();
        let mut tracks = numbered_tracks(4);
        tracks[0].available = false;
        tracks[2].available = false;

        // Clicking track_3 (index 3) lands on track_3 at filtered index 1.
        let started = q.set_queue(tracks.clone(), 3, Some("Tracks".into())).await.unwrap();
        assert_eq!(started.id, "track_3");
        let state = q.get_state().await;
        assert_eq!(state.tracks.len(), 2);
        assert_eq!(state.tracks[0].id, "track_1");
        assert_eq!(state.tracks[1].id, "track_3");
        assert_eq!(state.current_index, 1);

        // Requesting an unavailable index lands on the next playable track.
        let fallback = q.set_queue(tracks, 0, None).await.unwrap();
        assert_eq!(fallback.id, "track_1");
        assert_eq!(q.get_state().await.current_index, 0);

        // An all-unavailable list leaves the existing queue untouched.
        let mut dead = numbered_tracks(2);
        for t in &mut dead {
            t.available = false;
        }
        assert!(q.set_queue(dead, 0, None).await.is_none());
        assert_eq!(q.get_current_track().await.unwrap().id, "track_1");
    }

    #[test]
    fn track_item_available_defaults_to_true_when_missing_in_json() {
        let legacy: TrackItem = serde_json::from_str(
            r#"{"id":"1","title":"Song","artist":"Artist"}"#,
        )
        .unwrap();
        assert!(legacy.available);
        assert!(TrackItem::default().available);
    }
}
