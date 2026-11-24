use crate::auth::AuthManager;
use crate::mpv::FormatInfo;
use crate::queue::{ArtistCredit, TrackItem};
use futures::{stream, StreamExt};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use tracing::{error, info, warn};

const API_BASE: &str = "https://api.tidal.com/v1";
/// Playlist privacy is only served by TIDAL's v2 surface.
const API_V2_BASE: &str = "https://api.tidal.com/v2";
/// TIDAL serves animated cover artwork as short silent MP4 loops.
const VIDEO_COVER_SIZE: u32 = 640;
const FAVORITE_CACHE_TTL: Duration = Duration::from_secs(180);

/// The user's whole favourite-track list, fetched once. `/status` and every
/// transport action ask for the current track's favourite flag; a per-track
/// entry meant each newly selected track paid for another full list fetch,
/// and a skip storm fired one TIDAL request per skip while holding the
/// transport lock.
struct FavoriteTracks {
    user_id: u64,
    ids: HashSet<String>,
    fetched_at: Instant,
}

impl FavoriteTracks {
    fn is_fresh(&self, user_id: u64) -> bool {
        self.user_id == user_id && self.fetched_at.elapsed() < FAVORITE_CACHE_TTL
    }

    fn set(&mut self, track_id: &str, favorited: bool) {
        if favorited {
            self.ids.insert(track_id.to_string());
        } else {
            self.ids.remove(track_id);
        }
    }
}

fn favorite_track_id(entry: &serde_json::Value) -> Option<String> {
    let item = entry.get("item").unwrap_or(entry);
    item.get("id").and_then(|v| {
        v.as_u64()
            .map(|n| n.to_string())
            .or_else(|| v.as_str().map(str::to_string))
    })
}

/// One user's favourite albums, artists or playlists for a single kind. The
/// entity pages ask whether the page itself is favourited; caching the whole
/// list per kind means only the first page after the TTL pays for the fetch.
struct EntityFavorites {
    ids: HashSet<String>,
    fetched_at: Instant,
}

impl EntityFavorites {
    fn is_fresh(&self) -> bool {
        self.fetched_at.elapsed() < FAVORITE_CACHE_TTL
    }

    fn set(&mut self, id: &str, favorited: bool) {
        if favorited {
            self.ids.insert(id.to_string());
        } else {
            self.ids.remove(id);
        }
    }
}

fn entity_favorite_id(entry: &serde_json::Value) -> Option<String> {
    let item = entry.get("item").unwrap_or(entry);
    item.get("id").or_else(|| item.get("uuid")).and_then(|v| {
        v.as_u64()
            .map(|n| n.to_string())
            .or_else(|| v.as_str().map(str::to_string))
    })
}

/// One page of a TIDAL track list. `next_offset` is the absolute item offset
/// to request next, or `None` when the list is complete. It is deliberately
/// not `tracks.len()`: the parser drops unavailable items, while TIDAL's
/// offsets count the raw list positions.
pub struct TrackPage {
    pub tracks: Vec<TrackItem>,
    pub total: usize,
    pub next_offset: Option<usize>,
}

impl TrackPage {
    fn empty() -> Self {
        Self {
            tracks: Vec::new(),
            total: 0,
            next_offset: None,
        }
    }
}

/// One resolved playback source. `url` is the local `.mpd` file path mpv loads;
/// `manifest` carries the raw MPD XML for a Cast receiver, which fetches the
/// segments itself.
struct Stream {
    url: String,
    manifest: String,
    format: FormatInfo,
}

/// A recently resolved playback source. Kept so a Previous to a track that
/// just played skips the TIDAL round trip and lands with its format badge
/// immediately; nothing is preloaded backwards on purpose, the data is simply
/// not thrown away yet. This is deliberately much smaller than the
/// playback-info cache that was removed: entries live only in memory, are
/// bounded in count and age, and a load failure drops the entry so the next
/// attempt fetches fresh instead of retrying a dead URL.
struct RecentStream {
    url: String,
    format: FormatInfo,
    fetched: Instant,
}

/// How many recently resolved streams are kept, and for how long. The signed
/// segment URLs inside a manifest stay valid for hours, so the window is
/// conservative by design: walking further back through the queue is allowed
/// to pay the ordinary fetch.
const RECENT_STREAMS: usize = 8;
const RECENT_STREAM_MAX_AGE: Duration = Duration::from_secs(30 * 60);

#[derive(Default)]
struct RecentStreams {
    entries: Mutex<HashMap<String, RecentStream>>,
}

impl RecentStreams {
    /// The remembered stream for `track_id`, if it is fresh and its manifest is
    /// still on disk.
    fn get(&self, track_id: &str) -> Option<(String, FormatInfo)> {
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        let entry = entries.get(track_id)?;
        if entry.fetched.elapsed() > RECENT_STREAM_MAX_AGE {
            entries.remove(track_id);
            return None;
        }
        // `materialize_stream` writes the manifest at fetch time and the
        // runtime dir keeps it for the session; a `file://` URL whose manifest
        // is gone must fall back to a fresh fetch.
        if let Some(path) = entry.url.strip_prefix("file://") {
            if !std::path::Path::new(path).exists() {
                entries.remove(track_id);
                return None;
            }
        }
        Some((entry.url.clone(), entry.format.clone()))
    }

    fn store(&self, track_id: &str, url: &str, format: &FormatInfo) {
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        entries.retain(|_, entry| entry.fetched.elapsed() <= RECENT_STREAM_MAX_AGE);
        entries.remove(track_id);
        entries.insert(
            track_id.to_string(),
            RecentStream {
                url: url.to_string(),
                format: format.clone(),
                fetched: Instant::now(),
            },
        );
        while entries.len() > RECENT_STREAMS {
            let oldest = entries
                .iter()
                .min_by_key(|(_, entry)| entry.fetched)
                .map(|(id, _)| id.clone());
            match oldest {
                Some(id) => {
                    if let Some(evicted) = entries.remove(&id) {
                        if let Some(path) = evicted.url.strip_prefix("file://") {
                            let _ = std::fs::remove_file(path);
                        }
                    }
                }
                None => break,
            }
        }
    }

    fn remove(&self, track_id: &str) {
        self.entries
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(track_id);
    }

    fn clear(&self) {
        self.entries
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
    }
}

pub struct CatalogueManager {
    auth: Arc<AuthManager>,
    http: reqwest::Client,
    favorite_tracks: Mutex<Option<FavoriteTracks>>,
    /// Single-flight guard for the favourite-list fetch above, so a burst of
    /// status/action calls does not launch a TIDAL request each.
    favorite_fetch: tokio::sync::Mutex<()>,
    /// `{uid}:{kind}` -> that user's favourite albums/artists/playlists for
    /// the kind. `entity_fetch` single-flights the list fetch.
    entity_favorites: Mutex<HashMap<String, EntityFavorites>>,
    entity_fetch: tokio::sync::Mutex<()>,
    /// artist_id -> formatted fan count (None when TIDAL has no popularity to
    /// estimate from). Search rows are filled from here so repeated searches
    /// do not re-fetch the same artist details.
    fans_cache: Mutex<HashMap<String, Option<String>>>,
    /// album_id -> formatted animated cover URL. A cached `None` means the
    /// album has no animated artwork, so the album lookup is not repeated.
    video_cover_cache: Mutex<HashMap<String, Option<String>>>,
    video_cover_pending: Mutex<HashSet<String>>,
    /// artist_id -> avatar URL (None = no picture). The now-playing header
    /// asks for an avatar on every track change, so a TIDAL lookup per request
    /// would add a network round trip to each skip.
    artist_image_cache: Mutex<HashMap<String, Option<String>>>,
    /// Recently resolved playback sources, so going back to a track that just
    /// played does not pay the playback-info round trip again.
    recent_streams: RecentStreams,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SearchResponse {
    pub tracks: Vec<TrackItem>,
    pub artists: Vec<ArtistItem>,
    pub albums: Vec<AlbumItem>,
    pub playlists: Vec<PlaylistItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArtistItem {
    pub id: String,
    pub name: String,
    pub art_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fans: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AlbumItem {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub year: Option<u32>,
    pub art_url: Option<String>,
    /// TIDAL's release kind (ALBUM/EP/SINGLE), so search rows can label a
    /// single as such.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release_type: Option<String>,
    /// Live release, inferred by `parse_artist_releases` from the title or
    /// version. TIDAL carries no live classification of its own.
    #[serde(default)]
    pub live: bool,
    /// TIDAL's 0-100 popularity score, used to order the discography's
    /// Popular pill. Only the artist release feed fills it in.
    #[serde(default)]
    pub popularity: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaylistItem {
    pub id: String,
    pub title: String,
    pub description: Option<String>,
    pub art_url: Option<String>,
    pub track_count: Option<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecentItem {
    pub id: String,
    pub title: String,
    pub subtitle: Option<String>,
    #[serde(rename = "type")]
    pub item_type: String, // "playlist", "mix", "album"
    pub art_url: Option<String>,
    /// Whether the playlist was created by the signed-in user. Only playlist
    /// contexts carry it; the UI gates edit/remove actions on it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub own: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct LyricsResponse {
    pub synced: bool,
    pub subtitles: Option<String>,
    pub text: Option<String>,
}

impl CatalogueManager {
    pub fn new(auth: Arc<AuthManager>) -> Self {
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .user_agent("Mozilla/5.0 (Linux; Android 12; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/91.0.4472.114 Safari/537.36")
            .build()
            .unwrap();
        Self {
            auth,
            http,
            favorite_tracks: Mutex::new(None),
            favorite_fetch: tokio::sync::Mutex::new(()),
            entity_favorites: Mutex::new(HashMap::new()),
            entity_fetch: tokio::sync::Mutex::new(()),
            fans_cache: Mutex::new(HashMap::new()),
            video_cover_cache: Mutex::new(HashMap::new()),
            video_cover_pending: Mutex::new(HashSet::new()),
            artist_image_cache: Mutex::new(HashMap::new()),
            recent_streams: RecentStreams::default(),
        }
    }

    pub fn format_art_url(hash: Option<&str>, size: u32) -> Option<String> {
        let h = hash?;
        if h.is_empty() {
            return None;
        }
        if h.starts_with("http://") || h.starts_with("https://") {
            return Some(h.to_string());
        }
        let fixed_hash = h.replace('-', "/");
        Some(format!(
            "https://resources.tidal.com/images/{fixed_hash}/{size}x{size}.jpg"
        ))
    }

    pub fn format_playlist_art_url(hash: Option<&str>) -> Option<String> {
        let h = hash?;
        if h.is_empty() {
            return None;
        }
        if h.starts_with("http://") || h.starts_with("https://") {
            return Some(h.to_string());
        }
        let fixed_hash = h.replace('-', "/");
        Some(format!(
            "https://resources.tidal.com/images/{fixed_hash}/480x320.jpg"
        ))
    }

    pub fn format_video_url(hash: Option<&str>, size: u32) -> Option<String> {
        let h = hash?;
        if h.is_empty() {
            return None;
        }
        if h.starts_with("http://") || h.starts_with("https://") {
            return Some(h.to_string());
        }
        let fixed_hash = h.replace('-', "/");
        Some(format!(
            "https://resources.tidal.com/videos/{fixed_hash}/{size}x{size}.mp4"
        ))
    }

    /// Fills in the animated artwork URL for a track. Track listings usually
    /// carry the album's `videoCover`, but some responses only include the
    /// album id, so fall back to a cached album lookup. The lookup runs in the
    /// background; the URL shows up in a later status response.
    pub fn enrich_video_url(self: &Arc<Self>, track: &mut TrackItem) {
        if track.video_url.is_some() {
            return;
        }
        let Some(album_id) = track.album_id.as_deref().filter(|id| !id.is_empty()) else {
            return;
        };
        if let Ok(cache) = self.video_cover_cache.lock() {
            if let Some(cached) = cache.get(album_id) {
                if let Some(url) = cached {
                    track.video_url = Some(url.clone());
                }
                return;
            }
        }
        self.prime_album_video_cover(album_id);
    }

    fn prime_album_video_cover(self: &Arc<Self>, album_id: &str) {
        {
            let Ok(cache) = self.video_cover_cache.lock() else {
                return;
            };
            if cache.contains_key(album_id) {
                return;
            }
        }
        {
            let Ok(mut pending) = self.video_cover_pending.lock() else {
                return;
            };
            if !pending.insert(album_id.to_string()) {
                return;
            }
        }

        let manager = Arc::clone(self);
        let album_id = album_id.to_string();
        tokio::spawn(async move {
            let resolved = match manager.authed_get(&format!("/albums/{album_id}")).await {
                Ok(val) => Some(CatalogueManager::format_video_url(
                    val.get("videoCover").and_then(|v| v.as_str()),
                    VIDEO_COVER_SIZE,
                )),
                // Permanent regional/missing album errors (404/403) will keep
                // failing on every status poll unless cached as no-cover; leave
                // transient failures uncached so a later poll can retry.
                Err(ref err) if is_permanent_album_error(err) => Some(None),
                Err(_) => None,
            };

            if let Some(cover) = resolved {
                if let Ok(mut cache) = manager.video_cover_cache.lock() {
                    if cache.len() >= 256 {
                        if let Some(oldest) = cache.keys().next().cloned() {
                            cache.remove(&oldest);
                        }
                    }
                    cache.insert(album_id.clone(), cover);
                }
            }
            if let Ok(mut pending) = manager.video_cover_pending.lock() {
                pending.remove(&album_id);
            }
        });
    }

    async fn authed_get(&self, path: &str) -> Result<serde_json::Value, String> {
        self.authed_get_with_etag(path)
            .await
            .map(|(value, _)| value)
    }

    /// `authed_get`, but also returns the `ETag` response header. TIDAL
    /// requires `If-None-Match` with that value on every playlist mutation.
    async fn authed_get_with_etag(
        &self,
        path: &str,
    ) -> Result<(serde_json::Value, Option<String>), String> {
        let token = self.auth.get_access_token().await.ok_or("Not logged in")?;
        let country = {
            let tokens = self.auth.tokens.read().await;
            if tokens.country_code.is_empty() {
                "US".to_string()
            } else {
                tokens.country_code.clone()
            }
        };

        let url = if path.starts_with("http") {
            path.to_string()
        } else {
            let sep = if path.contains('?') { "&" } else { "?" };
            format!("{API_BASE}{path}{sep}countryCode={country}")
        };

        info!("Sending TIDAL API request: {}", url);

        let res = self
            .http
            .get(&url)
            .header("Authorization", format!("Bearer {token}"))
            .header("x-tidal-client-version", "2025.7.16")
            .send()
            .await
            .map_err(|e| {
                warn!("Request to {} failed: {}", url, e);
                format!("Request failed: {e}")
            })?;

        let status = res.status();
        info!("TIDAL API response status for {}: {}", url, status);

        if status.as_u16() == 401 {
            let body = res.text().await.unwrap_or_default();
            // TIDAL uses HTTP 401 with subStatus 4005 when a track is not
            // licensed/ready for playback in the user's region. That is not an
            // expired token, so refreshing OAuth and retrying only wastes calls.
            if is_asset_unavailable_401(&body) {
                warn!("HTTP error {status} from {url}: {body}");
                return Err(format!("HTTP error {status}: {body}"));
            }
            info!("Received 401 Unauthorized, attempting token refresh...");
            match self.auth.refresh_token().await {
                Ok(true) => {
                    let new_token = self
                        .auth
                        .get_access_token()
                        .await
                        .ok_or("Not logged in after refresh")?;
                    info!("Token refresh succeeded, retrying request: {}", url);
                    let retry = self
                        .http
                        .get(&url)
                        .header("Authorization", format!("Bearer {new_token}"))
                        .header("x-tidal-client-version", "2025.7.16")
                        .send()
                        .await
                        .map_err(|e| format!("Retry failed: {e}"))?;
                    if retry.status().is_success() {
                        let etag = retry
                            .headers()
                            .get("etag")
                            .and_then(|value| value.to_str().ok())
                            .map(str::to_string);
                        let value = retry
                            .json()
                            .await
                            .map_err(|e| format!("JSON parse error: {e}"))?;
                        return Ok((value, etag));
                    } else {
                        let retry_status = retry.status();
                        let text = retry.text().await.unwrap_or_default();
                        warn!("Retry also failed with status {retry_status}: {text}");
                        return Err(format!("HTTP error {retry_status}: {text}"));
                    }
                }
                Ok(false) => {
                    warn!("Token refresh returned false");
                }
                Err(e) => {
                    warn!("Token refresh error: {}", e);
                }
            }
            warn!("HTTP error {status} from {url}: {body}");
            return Err(format!("HTTP error {status}: {body}"));
        }

        if status.is_success() {
            let etag = res
                .headers()
                .get("etag")
                .and_then(|value| value.to_str().ok())
                .map(str::to_string);
            let value = res
                .json()
                .await
                .map_err(|e| format!("JSON parse error: {e}"))?;
            Ok((value, etag))
        } else {
            let text = res.text().await.unwrap_or_default();
            warn!("HTTP error {status} from {}: {}", url, text);
            Err(format!("HTTP error {status}: {text}"))
        }
    }

    /// Fetches one playback-info response (the TIDAL round trip) and turns it
    /// into a local stream URL and format. There is no playback-info cache:
    /// mpv does its own read-ahead, so a fresh URL per Play is cheap and always
    /// signed. The one exception is a recently played track — its resolved
    /// stream is remembered briefly so a Previous back to it skips the round
    /// trip and the format badge lands immediately.
    pub async fn get_stream_url(&self, track_id: &str) -> Result<(String, FormatInfo), String> {
        if let Some(hit) = self.recent_streams.get(track_id) {
            return Ok(hit);
        }
        let stream = self.get_stream(track_id).await?;
        self.recent_streams
            .store(track_id, &stream.url, &stream.format);
        Ok((stream.url, stream.format))
    }

    /// Drops the remembered stream for `track_id`. Called when a load fails
    /// with a remembered URL, so the next attempt fetches fresh instead of
    /// retrying the same dead one.
    pub fn invalidate_stream(&self, track_id: &str) {
        self.recent_streams.remove(track_id);
    }

    /// Drops every remembered stream. A wake may span hours, so no URL from
    /// before the sleep may be served after it.
    pub fn invalidate_streams(&self) {
        self.recent_streams.clear();
    }

    /// The raw DASH manifest for a track, for handing to a Cast receiver. A
    /// receiver runs Shaka Player and fetches TIDAL's segments itself, so this
    /// is the only thing casting has to send it.
    pub async fn get_cast_manifest(
        &self,
        track_id: &str,
    ) -> Result<(String, FormatInfo), String> {
        let stream = self.get_stream(track_id).await?;
        Ok((stream.manifest, stream.format))
    }

    async fn get_stream(&self, track_id: &str) -> Result<Stream, String> {
        let safe_id = urlencoding_simple(track_id);
        let path = format!(
            "/tracks/{safe_id}/playbackinfopostpaywall?audioquality=HI_RES_LOSSLESS&playbackmode=STREAM&assetpresentation=FULL"
        );
        let response = self.authed_get(&path).await?;
        Self::materialize_stream(track_id, &response)
    }

    /// Decodes a playback-info response into a local stream URL and format.
    fn materialize_stream(track_id: &str, val: &serde_json::Value) -> Result<Stream, String> {
        let manifest_mime = val
            .get("manifestMimeType")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let manifest_base64 = val.get("manifest").and_then(|v| v.as_str()).unwrap_or("");

        let bit_depth = val
            .get("bitDepth")
            .and_then(|v| v.as_u64())
            .map(|n| n as u32)
            .unwrap_or(16);
        let sample_rate = val
            .get("sampleRate")
            .and_then(|v| v.as_u64())
            .map(|n| n as u32)
            .unwrap_or(44100);
        let audio_quality = val
            .get("audioQuality")
            .and_then(|v| v.as_str())
            .unwrap_or("LOSSLESS");

        let decoded_bytes = if !manifest_base64.is_empty() {
            base64_decode(manifest_base64).unwrap_or_default()
        } else {
            Vec::new()
        };
        let manifest_str = String::from_utf8(decoded_bytes).unwrap_or_default();

        if !(manifest_mime.contains("dash") || manifest_str.contains("<MPD")) {
            return Err(format!(
                "TIDAL returned {manifest_mime} ({audio_quality}) instead of a DASH manifest — sign out and sign in again"
            ));
        }

        // mpv loads the DASH manifest from the user's private runtime dir;
        // sanitize track_id so untrusted characters cannot escape manifests/.
        let safe_file_id: String = track_id
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
            .collect();
        if safe_file_id.is_empty() {
            return Err("Invalid track id for DASH manifest".to_string());
        }
        let manifest_dir = dirs::runtime_dir()
            .map(|dir| dir.join("scorchedegg.tidalplayer/manifests"))
            .unwrap_or_else(|| AuthManager::state_dir().join("manifests"));
        std::fs::create_dir_all(&manifest_dir)
            .map_err(|e| format!("Failed to create manifest directory: {e}"))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(
                &manifest_dir,
                std::fs::Permissions::from_mode(0o700),
            );
        }
        let mpd_path = manifest_dir.join(format!("manifest-{safe_file_id}.mpd"));
        std::fs::write(&mpd_path, &manifest_str)
            .map_err(|e| format!("Failed to write MPD manifest file: {e}"))?;
        let stream_url = format!("file://{}", mpd_path.display());

        let is_hires = bit_depth > 16 || sample_rate > 48000;
        let quality_str = if is_hires {
            "HI_RES_LOSSLESS"
        } else {
            audio_quality
        };
        let sr_khz = (sample_rate as f64) / 1000.0;
        let khz_str = if !sample_rate.is_multiple_of(1000) {
            format!("{sr_khz:.1}")
        } else {
            format!("{}", sample_rate / 1000)
        };
        let badge = format!("{bit_depth}-bit / {khz_str} kHz FLAC");

        let format = FormatInfo {
            bit_depth,
            sample_rate,
            quality: quality_str.to_string(),
            badge,
        };

        Ok(Stream {
            url: stream_url,
            manifest: manifest_str,
            format,
        })
    }

    pub async fn authed_post_form(
        &self,
        path: &str,
        params: &[(&str, &str)],
    ) -> Result<serde_json::Value, String> {
        self.authed_post_form_with_headers(path, params, &[]).await
    }

    async fn authed_post_form_with_headers(
        &self,
        path: &str,
        params: &[(&str, &str)],
        headers: &[(&str, &str)],
    ) -> Result<serde_json::Value, String> {
        let mut token = self.auth.get_access_token().await.ok_or("Not logged in")?;
        let country = {
            let tokens = self.auth.tokens.read().await;
            if tokens.country_code.is_empty() {
                "US".to_string()
            } else {
                tokens.country_code.clone()
            }
        };
        let sep = if path.contains('?') { "&" } else { "?" };
        let url = format!("{API_BASE}{path}{sep}countryCode={country}");

        info!("Sending TIDAL API POST form request: {url}");
        let send_once = |bearer: &str| {
            let mut request = self
                .http
                .post(&url)
                .header("Authorization", format!("Bearer {bearer}"))
                .header("x-tidal-client-version", "2025.7.16")
                .form(&params);
            for (name, value) in headers {
                request = request.header(*name, *value);
            }
            request.send()
        };

        let mut res = send_once(&token)
            .await
            .map_err(|e| format!("Request failed: {e}"))?;
        if res.status().as_u16() == 401
            && matches!(self.auth.refresh_token().await, Ok(true))
        {
            token = self
                .auth
                .get_access_token()
                .await
                .ok_or("Not logged in after refresh")?;
            res = send_once(&token)
                .await
                .map_err(|e| format!("Retry failed: {e}"))?;
        }

        let status = res.status();
        info!("TIDAL API response status for {url}: {status}");

        if status.is_success() {
            let text = res.text().await.unwrap_or_default();
            if text.trim().is_empty() {
                Ok(serde_json::Value::Null)
            } else {
                serde_json::from_str(&text).map_err(|e| format!("JSON parse error: {e}"))
            }
        } else {
            let text = res.text().await.unwrap_or_default();
            error!("TIDAL API POST error for {url} ({status}): {text}");
            Err(format!("HTTP error {status}: {text}"))
        }
    }

    pub async fn authed_delete(&self, path: &str) -> Result<bool, String> {
        self.authed_delete_with_headers(path, &[]).await
    }

    async fn authed_delete_with_headers(
        &self,
        path: &str,
        headers: &[(&str, &str)],
    ) -> Result<bool, String> {
        let mut token = self.auth.get_access_token().await.ok_or("Not logged in")?;
        let country = {
            let tokens = self.auth.tokens.read().await;
            if tokens.country_code.is_empty() {
                "US".to_string()
            } else {
                tokens.country_code.clone()
            }
        };
        let sep = if path.contains('?') { "&" } else { "?" };
        let url = format!("{API_BASE}{path}{sep}countryCode={country}");

        info!("Sending TIDAL API DELETE request: {url}");
        let send_once = |bearer: &str| {
            let mut request = self
                .http
                .delete(&url)
                .header("Authorization", format!("Bearer {bearer}"))
                .header("x-tidal-client-version", "2025.7.16");
            for (name, value) in headers {
                request = request.header(*name, *value);
            }
            request.send()
        };

        let mut res = send_once(&token)
            .await
            .map_err(|e| format!("Request failed: {e}"))?;
        if res.status().as_u16() == 401
            && matches!(self.auth.refresh_token().await, Ok(true))
        {
            token = self
                .auth
                .get_access_token()
                .await
                .ok_or("Not logged in after refresh")?;
            res = send_once(&token)
                .await
                .map_err(|e| format!("Retry failed: {e}"))?;
        }

        let status = res.status();
        info!("TIDAL API response status for {url}: {status}");
        if !status.is_success() {
            let text = res.text().await.unwrap_or_default();
            error!("TIDAL API DELETE error for {url} ({status}): {text}");
        }
        Ok(status.is_success())
    }

    pub async fn get_mixes(&self) -> Result<Vec<RecentItem>, String> {
        // The Custom mixes page is the one TIDAL's web player shows behind
        // "view all": Daily Discovery, My Mix 1-8 and New Arrivals, with no
        // video mixes. The older collection page is still served for accounts
        // or regions that have no Custom mixes page, so fall back to it rather
        // than leaving the section and its page empty.
        let val = match self
            .authed_get("/pages/DAILY_MIXES/view-all?deviceType=BROWSER")
            .await
        {
            Ok(val) => val,
            Err(e) => {
                warn!("Custom mixes page unavailable ({e}); using the collection mixes page");
                self.authed_get("/pages/my_collection_my_mixes?deviceType=BROWSER")
                    .await?
            }
        };

        let mut mixes = Vec::new();
        let mut new_arrivals: Option<RecentItem> = None;
        if let Some(rows) = val.get("rows").and_then(|v| v.as_array()) {
            for row in rows {
                if let Some(modules) = row.get("modules").and_then(|v| v.as_array()) {
                    for module in modules {
                        if let Some(items) = module
                            .get("pagedList")
                            .and_then(|p| p.get("items"))
                            .and_then(|v| v.as_array())
                        {
                            for item in items {
                                let id = item
                                    .get("id")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string();
                                let title = item
                                    .get("title")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string();
                                let subtitle = item
                                    .get("subTitle")
                                    .and_then(|v| v.as_str())
                                    .map(|s| s.to_string());
                                let mix_type = item
                                    .get("mixType")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string();
                                let art_hash = item
                                    .get("images")
                                    .and_then(|imgs| {
                                        imgs.get("LARGE")
                                            .or(imgs.get("MEDIUM"))
                                            .or(imgs.get("SMALL"))
                                    })
                                    .and_then(|v| v.get("url"))
                                    .and_then(|u| u.as_str())
                                    .or_else(|| item.get("squareImage").and_then(|v| v.as_str()))
                                    .or_else(|| item.get("image").and_then(|v| v.as_str()));

                                if !id.is_empty() {
                                    let mix = RecentItem {
                                        id,
                                        title,
                                        subtitle,
                                        item_type: "mix".to_string(),
                                        art_url: Self::format_art_url(art_hash, 320),
                                        own: None,
                                    };
                                    // New Arrivals reads as the second mix on
                                    // both the Music page and the Mixes
                                    // page, right after Daily Discovery. The
                                    // type is stable, the title is localised.
                                    if mix_type == "NEW_RELEASE_MIX" {
                                        new_arrivals = Some(mix);
                                    } else {
                                        mixes.push(mix);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if let Some(mix) = new_arrivals {
            let at = mixes.len().min(1);
            mixes.insert(at, mix);
        }
        Ok(mixes)
    }

    /// The signed-in account's own profile. TIDAL's `username` is the account
    /// email for password logins; the bar settings menu shows it above Log out.
    pub async fn get_user_profile(&self) -> Result<serde_json::Value, String> {
        let uid = {
            let tokens = self.auth.tokens.read().await;
            tokens.user_id
        };
        if uid == 0 {
            return Err("Not logged in".to_string());
        }
        self.authed_get(&format!("/users/{uid}")).await
    }

    pub async fn get_user_albums(&self) -> Result<Vec<AlbumItem>, String> {
        let uid = {
            let tokens = self.auth.tokens.read().await;
            tokens.user_id
        };
        if uid == 0 {
            return Ok(Vec::new());
        }

        let mut all_albums = Vec::new();
        let mut offset = 0;
        let limit = 500;

        loop {
            let path = format!("/users/{uid}/favorites/albums?offset={offset}&limit={limit}&order=DATE&orderDirection=DESC");
            let val = self.authed_get(&path).await?;

            let mut page_albums = Vec::new();
            if let Some(items) = val.get("items").and_then(|v| v.as_array()) {
                for entry in items {
                    let item = entry.get("item").unwrap_or(entry);
                    let id = item
                        .get("id")
                        .and_then(|v| {
                            v.as_u64()
                                .map(|n| n.to_string())
                                .or_else(|| v.as_str().map(|s| s.to_string()))
                        })
                        .unwrap_or_default();
                    let title = item
                        .get("title")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    let artist = item
                        .get("artists")
                        .and_then(|a| a.as_array())
                        .and_then(|arr| arr.first())
                        .and_then(|art| art.get("name"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    let cover_hash = item.get("cover").and_then(|v| v.as_str());
                    let year = item
                        .get("releaseDate")
                        .and_then(|v| v.as_str())
                        .and_then(|s| s.get(0..4))
                        .and_then(|y| y.parse::<u32>().ok());

                    if !id.is_empty() {
                        page_albums.push(AlbumItem {
                            id,
                            title,
                            artist,
                            year,
                            art_url: Self::format_art_url(cover_hash, 320),
                            release_type: release_type(item),
                            live: false,
                            popularity: 0,
                        });
                    }
                }
            }
            let raw_count = val
                .get("items")
                .and_then(|v| v.as_array())
                .map(|a| a.len())
                .unwrap_or(0);
            if raw_count == 0 {
                break;
            }
            all_albums.extend(page_albums);
            let total = val
                .get("totalNumberOfItems")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as usize;
            offset += limit;
            if (total > 0 && offset >= total) || (total == 0 && raw_count < limit) {
                break;
            }
        }

        Ok(all_albums)
    }

    pub async fn get_user_artists(&self) -> Result<Vec<ArtistItem>, String> {
        let uid = {
            let tokens = self.auth.tokens.read().await;
            tokens.user_id
        };
        if uid == 0 {
            return Ok(Vec::new());
        }

        let mut all_artists = Vec::new();
        let mut offset = 0;
        let limit = 500;

        loop {
            let path = format!("/users/{uid}/favorites/artists?offset={offset}&limit={limit}&order=DATE&orderDirection=DESC");
            let val = self.authed_get(&path).await?;

            let mut page_artists = Vec::new();
            if let Some(items) = val.get("items").and_then(|v| v.as_array()) {
                for entry in items {
                    let item = entry.get("item").unwrap_or(entry);
                    let id = item
                        .get("id")
                        .and_then(|v| {
                            v.as_u64()
                                .map(|n| n.to_string())
                                .or_else(|| v.as_str().map(|s| s.to_string()))
                        })
                        .unwrap_or_default();
                    let name = item
                        .get("name")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    let pic = item
                        .get("picture")
                        .and_then(|v| v.as_str())
                        .or_else(|| {
                            item.get("selectedAlbumCoverFallback")
                                .and_then(|v| v.as_str())
                        })
                        .or_else(|| item.get("squareImage").and_then(|v| v.as_str()))
                        .or_else(|| item.get("image").and_then(|v| v.as_str()));

                    if !id.is_empty() {
                        page_artists.push(ArtistItem {
                            id,
                            name,
                            art_url: Self::format_art_url(pic, 320),
                            fans: None,
                        });
                    }
                }
            }
            let raw_count = val
                .get("items")
                .and_then(|v| v.as_array())
                .map(|a| a.len())
                .unwrap_or(0);
            if raw_count == 0 {
                break;
            }
            all_artists.extend(page_artists);
            let total = val
                .get("totalNumberOfItems")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as usize;
            offset += limit;
            if (total > 0 && offset >= total) || (total == 0 && raw_count < limit) {
                break;
            }
        }

        Ok(all_artists)
    }

    pub async fn toggle_favorite_track(&self, track_id: &str) -> Result<bool, String> {
        let uid = {
            let tokens = self.auth.tokens.read().await;
            tokens.user_id
        };
        if uid == 0 {
            return Err("Not logged in".to_string());
        }

        let is_fav = self.is_track_favorited(track_id).await;
        if is_fav {
            let safe_id = urlencoding_simple(track_id);
            let path = format!("/users/{uid}/favorites/tracks/{safe_id}");
            match self.authed_delete(&path).await? {
                true => {
                    self.cache_track_favorite(uid, track_id, false);
                    info!("Successfully removed track {track_id} from favorites");
                    Ok(false)
                }
                false => Err("TIDAL rejected removing the track from favorites".to_string()),
            }
        } else {
            let path = format!("/users/{uid}/favorites/tracks");
            self.authed_post_form(&path, &[("trackId", track_id)])
                .await?;
            self.cache_track_favorite(uid, track_id, true);
            info!("Successfully added track {track_id} to favorites");
            Ok(true)
        }
    }

    pub fn clear_cache(&self) {
        if let Ok(mut cache) = self.favorite_tracks.lock() {
            *cache = None;
        }
        if let Ok(mut cache) = self.entity_favorites.lock() {
            cache.clear();
        }
        if let Ok(mut cache) = self.fans_cache.lock() {
            cache.clear();
        }
        if let Ok(mut cache) = self.video_cover_cache.lock() {
            cache.clear();
        }
        if let Ok(mut cache) = self.video_cover_pending.lock() {
            cache.clear();
        }
        if let Ok(mut cache) = self.artist_image_cache.lock() {
            cache.clear();
        }
        self.recent_streams.clear();
        let manifest_dir = dirs::runtime_dir()
            .map(|dir| dir.join("scorchedegg.tidalplayer/manifests"))
            .unwrap_or_else(|| AuthManager::state_dir().join("manifests"));
        if let Ok(entries) = std::fs::read_dir(&manifest_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) == Some("mpd") {
                    let _ = std::fs::remove_file(path);
                }
            }
        }
    }

    fn cache_track_favorite(&self, user_id: u64, track_id: &str, favorited: bool) {
        if let Ok(mut cache) = self.favorite_tracks.lock() {
            if let Some(entry) = cache.as_mut() {
                if entry.user_id == user_id {
                    entry.set(track_id, favorited);
                }
            }
        }
    }

    fn cached_track_favorite(&self, user_id: u64, track_id: &str) -> Option<bool> {
        let cache = self.favorite_tracks.lock().ok()?;
        let entry = cache.as_ref()?;
        if !entry.is_fresh(user_id) {
            return None;
        }
        Some(entry.ids.contains(track_id))
    }

    /// The favourite flag only if the cache already knows it. The event
    /// publisher uses this so a cold cache cannot delay a status event (and
    /// with it, the format badge) on a TIDAL request.
    pub async fn favorite_cached(&self, track_id: &str) -> Option<bool> {
        let uid = {
            let tokens = self.auth.tokens.read().await;
            tokens.user_id
        };
        if uid == 0 {
            return Some(false);
        }
        self.cached_track_favorite(uid, track_id)
    }

    pub async fn is_track_favorited(&self, track_id: &str) -> bool {
        let uid = {
            let tokens = self.auth.tokens.read().await;
            tokens.user_id
        };
        if uid == 0 {
            return false;
        }
        if let Some(favorited) = self.cached_track_favorite(uid, track_id) {
            return favorited;
        }

        // A skip burst asks about a run of different tracks at once. Fetch
        // the list once: waiters re-check the cache after the winner stores
        // it instead of each starting another TIDAL request.
        let _fetch = self.favorite_fetch.lock().await;
        if let Some(favorited) = self.cached_track_favorite(uid, track_id) {
            return favorited;
        }

        let mut ids = HashSet::new();
        let mut offset = 0usize;
        const PAGE: usize = 500;
        loop {
            let path = format!("/users/{uid}/favorites/tracks?offset={offset}&limit={PAGE}");
            let Ok(val) = self.authed_get(&path).await else {
                if offset == 0 {
                    return false;
                }
                break;
            };
            let Some(items) = val.get("items").and_then(|v| v.as_array()) else {
                if offset == 0 {
                    return false;
                }
                break;
            };
            let raw_count = items.len();
            ids.extend(items.iter().filter_map(favorite_track_id));
            let total = val
                .get("totalNumberOfItems")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as usize;
            offset += PAGE;
            if raw_count == 0
                || (total > 0 && offset >= total)
                || (total == 0 && raw_count < PAGE)
            {
                break;
            }
        }
        if let Ok(mut cache) = self.favorite_tracks.lock() {
            *cache = Some(FavoriteTracks {
                user_id: uid,
                ids,
                fetched_at: Instant::now(),
            });
        }
        self.cached_track_favorite(uid, track_id).unwrap_or(false)
    }

    /// Album/artist/playlist favourite state. `kind` is TIDAL's plural path
    /// segment (`albums`/`artists`/`playlists`); playlists are keyed by
    /// `uuid`, the others by `id`. Same one-list-fetch-and-cache shape as
    /// `is_track_favorited`.
    pub async fn is_entity_favorited(&self, kind: &str, id: &str) -> bool {
        let uid = {
            let tokens = self.auth.tokens.read().await;
            tokens.user_id
        };
        if uid == 0 || id.is_empty() {
            return false;
        }
        if let Some(favorited) = self.cached_entity_favorite(uid, kind, id) {
            return favorited;
        }

        let _fetch = self.entity_fetch.lock().await;
        if let Some(favorited) = self.cached_entity_favorite(uid, kind, id) {
            return favorited;
        }

        let mut ids = HashSet::new();
        let mut offset = 0usize;
        const PAGE: usize = 500;
        loop {
            let path = format!("/users/{uid}/favorites/{kind}?offset={offset}&limit={PAGE}");
            let Ok(val) = self.authed_get(&path).await else {
                if offset == 0 {
                    return false;
                }
                break;
            };
            let Some(items) = val.get("items").and_then(|v| v.as_array()) else {
                if offset == 0 {
                    return false;
                }
                break;
            };
            let raw_count = items.len();
            ids.extend(items.iter().filter_map(entity_favorite_id));
            let total = val
                .get("totalNumberOfItems")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as usize;
            offset += PAGE;
            if raw_count == 0
                || (total > 0 && offset >= total)
                || (total == 0 && raw_count < PAGE)
            {
                break;
            }
        }
        if let Ok(mut cache) = self.entity_favorites.lock() {
            cache.insert(
                format!("{uid}:{kind}"),
                EntityFavorites {
                    ids,
                    fetched_at: Instant::now(),
                },
            );
        }
        self.cached_entity_favorite(uid, kind, id).unwrap_or(false)
    }

    fn cached_entity_favorite(&self, uid: u64, kind: &str, id: &str) -> Option<bool> {
        let cache = self.entity_favorites.lock().ok()?;
        let entry = cache.get(&format!("{uid}:{kind}"))?;
        if !entry.is_fresh() {
            return None;
        }
        Some(entry.ids.contains(id))
    }

    fn cache_entity_favorite(&self, uid: u64, kind: &str, id: &str, favorited: bool) {
        if let Ok(mut cache) = self.entity_favorites.lock() {
            if let Some(entry) = cache.get_mut(&format!("{uid}:{kind}")) {
                entry.set(id, favorited);
            }
        }
    }

    async fn toggle_entity_favorite(&self, kind: &str, id: &str) -> Result<bool, String> {
        let uid = {
            let tokens = self.auth.tokens.read().await;
            tokens.user_id
        };
        if uid == 0 {
            return Err("Not logged in".to_string());
        }
        if id.is_empty() {
            return Err("Missing id".to_string());
        }

        // Each entity kind uses its own form field; playlists are addressed by
        // their uuid on both the add and delete endpoints.
        let (field, path_kind) = match kind {
            "albums" => ("albumId", "albums"),
            "artists" => ("artistId", "artists"),
            "playlists" => ("uuid", "playlists"),
            _ => return Err(format!("Unsupported favourite kind: {kind}")),
        };

        if self.is_entity_favorited(kind, id).await {
            match self
                .authed_delete(&format!("/users/{uid}/favorites/{path_kind}/{id}"))
                .await
            {
                Ok(true) => {
                    self.cache_entity_favorite(uid, kind, id, false);
                    info!("Removed {kind} {id} from favorites");
                    Ok(false)
                }
                Ok(false) => Err("TIDAL rejected the request".to_string()),
                Err(e) => Err(e),
            }
        } else {
            self.authed_post_form(
                &format!("/users/{uid}/favorites/{path_kind}"),
                &[(field, id)],
            )
            .await?;
            self.cache_entity_favorite(uid, kind, id, true);
            info!("Added {kind} {id} to favorites");
            Ok(true)
        }
    }

    pub async fn toggle_favorite_album(&self, album_id: &str) -> Result<bool, String> {
        self.toggle_entity_favorite("albums", album_id).await
    }

    pub async fn toggle_favorite_artist(&self, artist_id: &str) -> Result<bool, String> {
        self.toggle_entity_favorite("artists", artist_id).await
    }

    pub async fn toggle_favorite_playlist(&self, playlist_id: &str) -> Result<bool, String> {
        self.toggle_entity_favorite("playlists", playlist_id).await
    }

    /// Artist radio (`/artists/{id}/radio`), played like a mix context.
    pub async fn get_artist_radio(&self, artist_id: &str) -> Result<Vec<TrackItem>, String> {
        let path = format!("/artists/{artist_id}/radio?limit=100");
        let val = self.authed_get(&path).await?;
        Ok(Self::parse_track_items(&val).unwrap_or_default())
    }

    pub async fn get_playlists(&self) -> Result<Vec<PlaylistItem>, String> {
        let uid = {
            let tokens = self.auth.tokens.read().await;
            tokens.user_id
        };
        if uid == 0 {
            return Ok(Vec::new());
        }

        let mut all_playlists = Vec::new();
        let mut seen = HashSet::new();
        let mut first_error = None;
        let limit = 500;

        // Saved public playlists live under favorites, not the user's own
        // playlist feed. Merge both so an "Add"ed playlist appears in the
        // collection list. Favorites also contains some own playlists, so
        // de-duplicate by uuid.
        for base in [
            format!("/users/{uid}/favorites/playlists"),
            format!("/users/{uid}/playlists"),
        ] {
            let mut offset = 0;
            loop {
                let path = format!("{base}?offset={offset}&limit={limit}");
                let val = match self.authed_get(&path).await {
                    Ok(val) => val,
                    Err(e) => {
                        first_error.get_or_insert(e);
                        break;
                    }
                };
                let raw_count = val
                    .get("items")
                    .and_then(|v| v.as_array())
                    .map(|a| a.len())
                    .unwrap_or(0);
                if raw_count == 0 {
                    break;
                }
                if let Some(items) = val.get("items").and_then(|v| v.as_array()) {
                    for entry in items {
                        let item = entry.get("item").unwrap_or(entry);
                        if let Some(playlist) = parse_playlist_item(item) {
                            if seen.insert(playlist.id.clone()) {
                                all_playlists.push(playlist);
                            }
                        }
                    }
                }
                let total = val
                    .get("totalNumberOfItems")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(0) as usize;
                offset += limit;
                if (total > 0 && offset >= total) || (total == 0 && raw_count < limit) {
                    break;
                }
            }
        }

        if all_playlists.is_empty() {
            if let Some(error) = first_error {
                return Err(error);
            }
        }
        Ok(all_playlists)
    }

    /// One page of a playlist. `limit == 0` means "all remaining tracks";
    /// `offset` is an absolute item offset. TIDAL caps playlist items at 100
    /// per request (500 answers 400).
    pub async fn get_playlist_tracks_page(
        &self,
        playlist_id: &str,
        offset: usize,
        limit: usize,
    ) -> Result<TrackPage, String> {
        const PAGE: usize = 100;
        let first_size = if limit > 0 { limit.min(PAGE) } else { PAGE };
        let first = self
            .authed_get(&format!(
                "/playlists/{playlist_id}/items?offset={offset}&limit={first_size}"
            ))
            .await?;
        let raw_count = first
            .get("items")
            .and_then(|v| v.as_array())
            .map(|a| a.len())
            .unwrap_or(0);
        if raw_count == 0 {
            return Ok(TrackPage::empty());
        }
        let total = first
            .get("totalNumberOfItems")
            .and_then(|v| v.as_u64())
            .unwrap_or(0) as usize;
        let mut tracks = Self::parse_track_items_from(&first, Some(offset))?;

        if limit > 0 {
            let next = offset + first_size;
            return Ok(TrackPage {
                tracks,
                total,
                next_offset: if total > next { Some(next) } else { None },
            });
        }

        // limit == 0: fetch the tail. Pages are independent, so fetch them
        // with a small concurrency bound and sort them back into order.
        let mut next = offset + first_size;
        if total > next {
            let offsets = (next..total).step_by(PAGE).collect::<Vec<_>>();
            let mut rest = stream::iter(offsets)
                .map(|page_offset| async move {
                    let val = self
                        .authed_get(&format!(
                            "/playlists/{playlist_id}/items?offset={page_offset}&limit={PAGE}"
                        ))
                        .await;
                    (page_offset, val)
                })
                .buffer_unordered(4)
                .collect::<Vec<_>>()
                .await;
            rest.sort_by_key(|(page_offset, _)| *page_offset);
            for (page_offset, page) in rest {
                let val = page?;
                tracks.extend(Self::parse_track_items_from(&val, Some(page_offset))?);
            }
        } else if total == 0 {
            // Older responses may omit the total; walk until a short page.
            loop {
                let val = self
                    .authed_get(&format!(
                        "/playlists/{playlist_id}/items?offset={next}&limit={PAGE}"
                    ))
                    .await?;
                let count = val
                    .get("items")
                    .and_then(|v| v.as_array())
                    .map(|a| a.len())
                    .unwrap_or(0);
                if count == 0 {
                    break;
                }
                tracks.extend(Self::parse_track_items_from(&val, Some(next))?);
                next += PAGE;
                if count < PAGE {
                    break;
                }
            }
        }

        Ok(TrackPage {
            tracks,
            total,
            next_offset: None,
        })
    }

    /// Metadata for one playlist, including whether the signed-in user created
    /// it. Only their own playlists can be edited.
    pub async fn get_playlist_info(&self, playlist_id: &str) -> Result<serde_json::Value, String> {
        let uid = {
            let tokens = self.auth.tokens.read().await;
            tokens.user_id
        };
        let val = self
            .authed_get(&format!("/playlists/{playlist_id}"))
            .await?;
        let creator_id = val
            .get("creator")
            .and_then(|creator| creator.get("id"))
            .and_then(|id| id.as_u64());
        let image = val
            .get("image")
            .and_then(|value| value.as_str())
            .or_else(|| val.get("squareImage").and_then(|value| value.as_str()));
        let own = uid != 0 && creator_id == Some(uid);
        // An own playlist is in the collection by definition; TIDAL does not
        // list it under favorites, so asking would always answer false.
        let favorite = if own {
            true
        } else {
            self.is_entity_favorited("playlists", playlist_id).await
        };

        Ok(serde_json::json!({
            "id": val.get("uuid").and_then(|value| value.as_str()).unwrap_or(playlist_id),
            "title": val.get("title").and_then(|value| value.as_str()).unwrap_or(""),
            "description": val.get("description").and_then(|value| value.as_str()).unwrap_or(""),
            "track_count": val.get("numberOfTracks").and_then(|value| value.as_u64()).unwrap_or(0),
            "duration": val.get("duration").and_then(|value| value.as_u64()).unwrap_or(0),
            "art_url": Self::format_playlist_art_url(image),
            "own": own,
            "favorite": favorite,
            "public": val.get("publicPlaylist").and_then(|value| value.as_bool()).unwrap_or(false),
        }))
    }

    pub async fn create_playlist(
        &self,
        title: &str,
        description: &str,
    ) -> Result<serde_json::Value, String> {
        let uid = {
            let tokens = self.auth.tokens.read().await;
            tokens.user_id
        };
        if uid == 0 {
            return Err("Not logged in".to_string());
        }

        let val = self
            .authed_post_form(
                &format!("/users/{uid}/playlists"),
                &[("title", title), ("description", description)],
            )
            .await?;
        let id = val
            .get("uuid")
            .and_then(|value| value.as_str())
            .ok_or("TIDAL did not return the new playlist id")?;

        Ok(serde_json::json!({
            "id": id,
            "title": val.get("title").and_then(|value| value.as_str()).unwrap_or(title),
            "description": val.get("description").and_then(|value| value.as_str()).unwrap_or(description),
            "art_url": Self::format_playlist_art_url(val.get("image").and_then(|value| value.as_str())),
            "own": true,
        }))
    }

    pub async fn update_playlist(
        &self,
        playlist_id: &str,
        title: &str,
        description: &str,
    ) -> Result<bool, String> {
        self.authed_post_form(
            &format!("/playlists/{playlist_id}"),
            &[("title", title), ("description", description)],
        )
        .await
        .map(|_| true)
    }

    /// Flips a playlist between private and public. TIDAL's v2 surface exposes
    /// one endpoint per direction (`set-public`/`set-private`) and answers
    /// with an empty 200 body.
    pub async fn set_playlist_public(
        &self,
        playlist_id: &str,
        public: bool,
    ) -> Result<bool, String> {
        let mut token = self.auth.get_access_token().await.ok_or("Not logged in")?;
        let country = {
            let tokens = self.auth.tokens.read().await;
            if tokens.country_code.is_empty() {
                "US".to_string()
            } else {
                tokens.country_code.clone()
            }
        };
        let endpoint = if public { "set-public" } else { "set-private" };
        let safe_id = urlencoding_simple(playlist_id);
        let url = format!("{API_V2_BASE}/playlists/{safe_id}/{endpoint}?countryCode={country}");

        info!("Sending TIDAL API PUT request: {url}");
        let send_once = |bearer: &str| {
            self.http
                .put(&url)
                .header("Authorization", format!("Bearer {bearer}"))
                .header("x-tidal-client-version", "2025.7.16")
                .send()
        };
        let mut res = send_once(&token)
            .await
            .map_err(|e| format!("Request failed: {e}"))?;
        if res.status().as_u16() == 401
            && matches!(self.auth.refresh_token().await, Ok(true))
        {
            token = self
                .auth
                .get_access_token()
                .await
                .ok_or("Not logged in after refresh")?;
            res = send_once(&token)
                .await
                .map_err(|e| format!("Retry failed: {e}"))?;
        }

        let status = res.status();
        info!("TIDAL API response status for {url}: {status}");
        if status.is_success() {
            Ok(true)
        } else {
            let text = res.text().await.unwrap_or_default();
            error!("TIDAL API PUT error for {url} ({status}): {text}");
            Err(format!("HTTP error {status}: {text}"))
        }
    }

    pub async fn delete_playlist(&self, playlist_id: &str) -> Result<bool, String> {
        let safe_id = urlencoding_simple(playlist_id);
        self.authed_delete(&format!("/playlists/{safe_id}")).await
    }

    /// Current `ETag` and track count for a playlist. TIDAL rejects item
    /// mutations with 412 unless `If-None-Match` carries the live ETag, and
    /// appends use the track count as `toIndex`.
    async fn playlist_etag_and_count(&self, playlist_id: &str) -> Result<(String, usize), String> {
        let safe_id = urlencoding_simple(playlist_id);
        let (val, etag) = self
            .authed_get_with_etag(&format!("/playlists/{safe_id}"))
            .await?;
        let count = val
            .get("numberOfTracks")
            .and_then(|value| value.as_u64())
            .unwrap_or(0) as usize;
        let etag = etag.ok_or("TIDAL did not return an ETag for the playlist")?;
        Ok((etag, count))
    }

    /// Appends tracks to a playlist in batches of 100. Returns how many items
    /// TIDAL accepted (duplicates are skipped).
    pub async fn add_tracks_to_playlist(
        &self,
        playlist_id: &str,
        track_ids: &[String],
    ) -> Result<usize, String> {
        if track_ids.is_empty() {
            return Ok(0);
        }
        let safe_id = urlencoding_simple(playlist_id);
        let mut total_added = 0usize;
        for chunk in track_ids.chunks(100) {
            let (etag, count) = self.playlist_etag_and_count(playlist_id).await?;
            let ids = chunk.join(",");
            let to_index = count.to_string();
            let val = self
                .authed_post_form_with_headers(
                    &format!("/playlists/{safe_id}/items?limit=100"),
                    &[
                        ("onArtifactNotFound", "SKIP"),
                        ("trackIds", &ids),
                        ("toIndex", &to_index),
                        ("onDupes", "SKIP"),
                    ],
                    &[("If-None-Match", &etag)],
                )
                .await?;
            total_added += val
                .get("addedItemIds")
                .and_then(|value| value.as_array())
                .map(|items| items.len())
                .unwrap_or(0);
        }
        Ok(total_added)
    }

    pub async fn remove_playlist_items(
        &self,
        playlist_id: &str,
        indices: &[usize],
    ) -> Result<bool, String> {
        if indices.is_empty() {
            return Ok(true);
        }
        let (etag, _) = self.playlist_etag_and_count(playlist_id).await?;
        self.remove_playlist_items_with_etag(playlist_id, indices, &etag)
            .await
    }

    async fn remove_playlist_items_with_etag(
        &self,
        playlist_id: &str,
        indices: &[usize],
        etag: &str,
    ) -> Result<bool, String> {
        let safe_id = urlencoding_simple(playlist_id);
        let joined = indices
            .iter()
            .map(|index| index.to_string())
            .collect::<Vec<_>>()
            .join(",");
        self.authed_delete_with_headers(
            &format!("/playlists/{safe_id}/items/{joined}"),
            &[("If-None-Match", etag)],
        )
        .await
    }

    /// Removes the first playlist item carrying `track_id`, resolving its
    /// raw index from the live list first: a queue snapshotted before a
    /// reorder cannot know the item's current index, and an index out of
    /// date would remove the wrong row. Captures the playlist's ETag before
    /// scanning so a concurrent mutation fails with 412 rather than deleting
    /// the wrong row. `Ok(false)` when the track is not in the playlist at all.
    pub async fn remove_playlist_item_by_track(
        &self,
        playlist_id: &str,
        track_id: &str,
    ) -> Result<bool, String> {
        const PAGE: usize = 100;
        let safe_id = urlencoding_simple(playlist_id);
        let (etag, _) = self.playlist_etag_and_count(playlist_id).await?;
        let mut offset = 0usize;
        loop {
            let val = self
                .authed_get(&format!(
                    "/playlists/{safe_id}/items?offset={offset}&limit={PAGE}"
                ))
                .await?;
            let items = val
                .get("items")
                .and_then(|v| v.as_array())
                .ok_or("TIDAL did not return playlist items")?;
            for (position, item) in items.iter().enumerate() {
                let track_obj = item.get("item").unwrap_or(item);
                let id = track_obj.get("id").and_then(|v| {
                    v.as_u64()
                        .map(|n| n.to_string())
                        .or_else(|| v.as_str().map(str::to_string))
                });
                if id.as_deref() == Some(track_id) {
                    return self
                        .remove_playlist_items_with_etag(playlist_id, &[offset + position], &etag)
                        .await;
                }
            }
            if items.len() < PAGE {
                return Ok(false);
            }
            offset += PAGE;
        }
    }

    pub async fn move_playlist_item(
        &self,
        playlist_id: &str,
        from: usize,
        to: usize,
    ) -> Result<bool, String> {
        let (etag, count) = self.playlist_etag_and_count(playlist_id).await?;
        if count == 0 || from >= count {
            return Err(format!("playlist item index {from} is out of range"));
        }
        let target = to.min(count.saturating_sub(1));
        if from == target {
            return Ok(true);
        }
        let safe_id = urlencoding_simple(playlist_id);
        let target_string = target.to_string();
        self.authed_post_form_with_headers(
            &format!("/playlists/{safe_id}/items/{from}"),
            &[("toIndex", &target_string)],
            &[("If-None-Match", &etag)],
        )
        .await
        .map(|_| true)
    }

    pub async fn get_mix_tracks(&self, mix_id: &str) -> Result<Vec<TrackItem>, String> {
        if !mix_id.is_empty() && mix_id.chars().all(|c| c.is_ascii_digit()) {
            let path = format!("/tracks/{mix_id}/radio?limit=100");
            if let Ok(val) = self.authed_get(&path).await {
                if let Ok(tracks) = Self::parse_track_items(&val) {
                    if !tracks.is_empty() {
                        return Ok(tracks);
                    }
                }
            }
        }
        let path = format!("/mixes/{mix_id}/items?limit=100");
        match self.authed_get(&path).await {
            Ok(val) => Self::parse_track_items(&val),
            Err(e) => {
                let radio_path = format!("/tracks/{mix_id}/radio?limit=100");
                if let Ok(val) = self.authed_get(&radio_path).await {
                    if let Ok(tracks) = Self::parse_track_items(&val) {
                        if !tracks.is_empty() {
                            return Ok(tracks);
                        }
                    }
                }
                Err(e)
            }
        }
    }

    /// One page of favourite tracks. `limit == 0` means "all remaining
    /// tracks"; `offset` is an absolute item offset.
    pub async fn get_favorites_page(&self, limit: u32, offset: u32) -> Result<TrackPage, String> {
        let uid = {
            let tokens = self.auth.tokens.read().await;
            tokens.user_id
        };
        if uid == 0 {
            return Ok(TrackPage::empty());
        }

        // TIDAL serves up to 500 favourite tracks per page.
        const FAVORITES_PAGE: u32 = 500;
        let mut offset = offset as usize;

        // A limit means exactly one page: the UI shows it immediately and
        // asks for the cursor's tail separately. Never backfill by fetching
        // another page here, or the first paint pays for two round trips.
        if limit > 0 {
            let page_limit = limit.min(FAVORITES_PAGE) as usize;
            let path = format!(
                "/users/{uid}/favorites/tracks?offset={offset}&limit={page_limit}&order=DATE&orderDirection=DESC"
            );
            let val = self.authed_get(&path).await?;
            let mut seen = HashSet::new();
            let mut tracks = Vec::new();
            for track in Self::parse_track_items(&val)? {
                if seen.insert(track.id.clone()) {
                    tracks.push(track);
                }
            }
            let total = val
                .get("totalNumberOfItems")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as usize;
            offset += page_limit;
            return Ok(TrackPage {
                tracks,
                total,
                next_offset: if total > offset { Some(offset) } else { None },
            });
        }

        // limit == 0: fetch every remaining page.
        let mut all_tracks = Vec::new();
        let mut seen = HashSet::new();
        let mut total = 0usize;
        loop {
            let path = format!(
                "/users/{uid}/favorites/tracks?offset={offset}&limit={FAVORITES_PAGE}&order=DATE&orderDirection=DESC"
            );
            let val = self.authed_get(&path).await?;
            let raw_count = val
                .get("items")
                .and_then(|v| v.as_array())
                .map(|a| a.len())
                .unwrap_or(0);
            if raw_count == 0 {
                break;
            }
            // TIDAL's favourites offsets can overlap between page requests
            // when tracks are unavailable; favourites never legitimately
            // contain duplicates, so drop repeats.
            for track in Self::parse_track_items(&val)? {
                if seen.insert(track.id.clone()) {
                    all_tracks.push(track);
                }
            }
            total = val
                .get("totalNumberOfItems")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as usize;
            offset += FAVORITES_PAGE as usize;
            if (total > 0 && offset >= total) || (total == 0 && raw_count < FAVORITES_PAGE as usize)
            {
                break;
            }
        }

        Ok(TrackPage {
            tracks: all_tracks,
            total,
            next_offset: None,
        })
    }

    async fn fetch_artist_fans(&self, artist_id: &str) -> Option<String> {
        let val = self
            .authed_get(&format!("/artists/{artist_id}"))
            .await
            .ok()?;
        val.get("fans").and_then(format_fans).or_else(|| {
            val.get("popularity")
                .and_then(|v| v.as_u64())
                .and_then(fans_from_popularity)
        })
    }

    /// The artist's full release feed. `filter=ALL` includes singles, EPs and
    /// albums; TIDAL returns up to 500 per page.
    async fn fetch_artist_releases(&self, artist_id: &str) -> Vec<serde_json::Value> {
        const PAGE: usize = 500;
        let mut release_items = Vec::new();
        let mut offset = 0;
        loop {
            let path =
                format!("/artists/{artist_id}/albums?filter=ALL&offset={offset}&limit={PAGE}");
            let Ok(val) = self.authed_get(&path).await else {
                break;
            };
            let items = val
                .get("items")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default();
            if items.is_empty() {
                break;
            }
            let raw_count = items.len();
            release_items.extend(items);
            let total = val
                .get("totalNumberOfItems")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as usize;
            offset += PAGE;
            if (total > 0 && offset >= total) || (total == 0 && raw_count < PAGE) {
                break;
            }
        }
        release_items
    }

    pub async fn get_artist(&self, artist_id: &str) -> Result<serde_json::Value, String> {
        // The artist card, top tracks, release feed, bio and follow state are
        // independent; join them so the page pays roughly one round trip
        // instead of five sequential ones.
        let artist_path = format!("/artists/{artist_id}");
        let top_tracks_path = format!("/artists/{artist_id}/toptracks?limit=100");
        let bio_path = format!("/artists/{artist_id}/bio");
        let (artist_res, top_tracks_res, release_items, bio_res, favorite) = tokio::join!(
            self.authed_get(&artist_path),
            self.authed_get(&top_tracks_path),
            self.fetch_artist_releases(artist_id),
            self.authed_get(&bio_path),
            self.is_entity_favorited("artists", artist_id),
        );
        let artist_val = artist_res?;
        let top_tracks_val = top_tracks_res.unwrap_or_default();
        let bio_res = bio_res.ok();

        let name = artist_val
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let fans = artist_val
            .get("fans")
            .and_then(format_fans)
            .or_else(|| {
                artist_val
                    .get("popularity")
                    .and_then(|v| v.as_u64())
                    .and_then(fans_from_popularity)
            })
            .unwrap_or_default();

        let bio_text = bio_res
            .as_ref()
            .and_then(|v| {
                v.get("text")
                    .or_else(|| v.get("summary"))
                    .or_else(|| v.get("bio"))
            })
            .and_then(|v| v.as_str());

        let description = bio_text
            .map(clean_bio_text)
            .filter(|s| !s.is_empty())
            .or_else(|| {
                artist_val
                    .get("description")
                    .or_else(|| artist_val.get("bio"))
                    .and_then(|v| v.as_str())
                    .map(clean_bio_text)
                    .filter(|s| !s.is_empty())
            })
            .unwrap_or_default();

        let top_tracks = Self::parse_track_items(&top_tracks_val).unwrap_or_default();

        let releases = parse_artist_releases(&release_items, &name);

        let art_hash = artist_val
            .get("picture")
            .and_then(|v| v.as_str())
            .or_else(|| {
                artist_val
                    .get("selectedAlbumCoverFallback")
                    .and_then(|v| v.as_str())
            })
            .or_else(|| artist_val.get("squareImage").and_then(|v| v.as_str()))
            .or_else(|| artist_val.get("image").and_then(|v| v.as_str()));
        let mut art_url = Self::format_art_url(art_hash, 750);
        if art_url.is_none() {
            if let Some(first_top) = top_tracks.first() {
                if first_top.art_url.is_some() {
                    art_url = first_top.art_url.clone();
                }
            } else if let Some(first_alb) = releases.first() {
                if first_alb.art_url.is_some() {
                    art_url = first_alb.art_url.clone();
                }
            }
        }

        if let Ok(mut cache) = self.fans_cache.lock() {
            if cache.len() >= 512 {
                if let Some(evict) = cache.keys().next().cloned() {
                    cache.remove(&evict);
                }
            }
            cache.insert(
                artist_id.to_string(),
                if fans.is_empty() { None } else { Some(fans.clone()) },
            );
        }
        if let Ok(mut cache) = self.artist_image_cache.lock() {
            if cache.len() >= 512 {
                if let Some(evict) = cache.keys().next().cloned() {
                    cache.remove(&evict);
                }
            }
            cache.insert(
                artist_id.to_string(),
                Self::format_art_url(art_hash, 320).or_else(|| art_url.clone()),
            );
        }

        Ok(serde_json::json!({
            "id": artist_id,
            "name": name,
            "art_url": art_url,
            "fans": fans,
            "description": description,
            "favorite": favorite,
            "top_tracks": top_tracks,
            "releases": releases
        }))
    }

    pub async fn get_artist_image_url(&self, artist_id: &str) -> Result<Option<String>, String> {
        if let Ok(cache) = self.artist_image_cache.lock() {
            if let Some(cached) = cache.get(artist_id) {
                return Ok(cached.clone());
            }
        }
        let art_url = self.fetch_artist_image_url(artist_id).await?;
        if let Ok(mut cache) = self.artist_image_cache.lock() {
            if cache.len() >= 512 {
                if let Some(evict) = cache.keys().next().cloned() {
                    cache.remove(&evict);
                }
            }
            cache.insert(artist_id.to_string(), art_url.clone());
        }
        Ok(art_url)
    }

    async fn fetch_artist_image_url(&self, artist_id: &str) -> Result<Option<String>, String> {
        let artist = self.authed_get(&format!("/artists/{artist_id}")).await?;
        let picture = artist
            .get("picture")
            .and_then(|value| value.as_str())
            .or_else(|| {
                artist
                    .get("selectedAlbumCoverFallback")
                    .and_then(|value| value.as_str())
            })
            .or_else(|| artist.get("squareImage").and_then(|value| value.as_str()))
            .or_else(|| artist.get("image").and_then(|value| value.as_str()));

        if let Some(pic) = picture {
            return Ok(Self::format_art_url(Some(pic), 320));
        }

        // Fallback: check artist's top tracks for an album cover
        if let Ok(top_val) = self
            .authed_get(&format!("/artists/{artist_id}/toptracks?limit=1"))
            .await
        {
            if let Some(items) = top_val.get("items").and_then(|v| v.as_array()) {
                if let Some(first_track) = items.first() {
                    if let Some(cover) = first_track
                        .get("album")
                        .and_then(|a| a.get("cover"))
                        .and_then(|c| c.as_str())
                    {
                        return Ok(Self::format_art_url(Some(cover), 320));
                    }
                }
            }
        }

        Ok(None)
    }

    /// One page of album tracks. TIDAL returns up to 500 tracks per page.
    /// `limit == 0` means "all remaining tracks".
    pub async fn get_album_tracks_page(
        &self,
        album_id: &str,
        offset: usize,
        limit: usize,
    ) -> Result<TrackPage, String> {
        const PAGE: usize = 500;
        let mut offset = offset;
        let mut total = 0usize;

        // A limit means exactly one page; the tail endpoint passes limit == 0.
        if limit > 0 {
            let page_limit = limit.min(PAGE);
            let path = format!("/albums/{album_id}/tracks?offset={offset}&limit={page_limit}");
            let tracks_val = self.authed_get(&path).await?;
            let tracks = Self::parse_track_items(&tracks_val)?;
            total = tracks_val
                .get("totalNumberOfItems")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as usize;
            offset += page_limit;
            return Ok(TrackPage {
                tracks,
                total,
                next_offset: if total > offset { Some(offset) } else { None },
            });
        }

        let mut all_tracks = Vec::new();
        loop {
            let path = format!("/albums/{album_id}/tracks?offset={offset}&limit={PAGE}");
            let tracks_val = self.authed_get(&path).await?;
            let raw_count = tracks_val
                .get("items")
                .and_then(|v| v.as_array())
                .map(|a| a.len())
                .unwrap_or(0);
            if raw_count == 0 {
                break;
            }
            all_tracks.extend(Self::parse_track_items(&tracks_val)?);
            total = tracks_val
                .get("totalNumberOfItems")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as usize;
            offset += PAGE;
            if (total > 0 && offset >= total) || (total == 0 && raw_count < PAGE) {
                break;
            }
        }
        Ok(TrackPage {
            tracks: all_tracks,
            total,
            next_offset: None,
        })
    }

    pub async fn get_album(
        &self,
        album_id: &str,
        track_limit: u32,
    ) -> Result<serde_json::Value, String> {
        // Album metadata, its first track page and the favourite flag are
        // independent; fetch them together instead of paying three sequential
        // TIDAL round trips (the favourite set cache makes the third cheap
        // after the first entity page).
        let album_path = format!("/albums/{album_id}");
        let (album_res, tracks_res, favorite) = tokio::join!(
            self.authed_get(&album_path),
            self.get_album_tracks_page(album_id, 0, track_limit as usize),
            self.is_entity_favorited("albums", album_id),
        );
        let tracks_page = tracks_res.unwrap_or_else(|_| TrackPage::empty());
        let album_val = album_res?;

        let title = album_val
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        let artist = album_val
            .get("artist")
            .and_then(|a| a.get("name"))
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        // Album-level credits, so the QML header can link each artist page.
        // Some releases only carry the single `artist` object, so fall back to
        // it when `artists` is absent.
        let mut artists = Self::parse_artist_credits(album_val.get("artists"));
        if artists.is_empty() {
            if let Some(credit) = Self::parse_artist_credit(album_val.get("artist")) {
                artists.push(credit);
            }
        }
        let artist_id = artists.first().and_then(|credit| credit.id.clone());
        let cover_hash = album_val.get("cover").and_then(|v| v.as_str());
        let release_date = album_val
            .get("releaseDate")
            .and_then(|v| v.as_str())
            .map(str::to_string);
        let copyright = album_val
            .get("copyright")
            .and_then(|v| v.as_str())
            .map(str::to_string);
        let number_of_volumes = album_val
            .get("numberOfVolumes")
            .and_then(|v| v.as_u64())
            .unwrap_or(1);
        let duration = album_val
            .get("duration")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);

        Ok(serde_json::json!({
            "id": album_id,
            "title": title,
            "artist": artist,
            "artist_id": artist_id,
            "artists": artists,
            "release_type": release_type(&album_val),
            "art_url": Self::format_art_url(cover_hash, 640),
            "release_date": release_date,
            "copyright": copyright,
            "number_of_volumes": number_of_volumes,
            "duration": duration,
            "favorite": favorite,
            "track_total": tracks_page.total,
            "next_track_offset": tracks_page.next_offset,
            "tracks": tracks_page.tracks
        }))
    }

    pub async fn search(&self, query: &str) -> Result<SearchResponse, String> {
        let encoded = urlencoding_simple(query);
        let path =
            format!("/search?query={encoded}&limit=20&types=TRACKS,ARTISTS,ALBUMS,PLAYLISTS");
        let val = self.authed_get(&path).await?;

        let mut tracks = Vec::new();
        if let Some(t_items) = val
            .get("tracks")
            .and_then(|t| t.get("items"))
            .and_then(|i| i.as_array())
        {
            for item in t_items {
                if let Some(t) = Self::parse_single_track(item) {
                    tracks.push(t);
                }
            }
        }

        let mut artists = Vec::new();
        if let Some(a_items) = val
            .get("artists")
            .and_then(|a| a.get("items"))
            .and_then(|i| i.as_array())
        {
            for item in a_items {
                let id = item
                    .get("id")
                    .and_then(|v| {
                        v.as_u64()
                            .map(|n| n.to_string())
                            .or_else(|| v.as_str().map(|s| s.to_string()))
                    })
                    .unwrap_or_default();
                let name = item
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
                let pic = item.get("picture").and_then(|v| v.as_str());
                let fans = item.get("fans").and_then(format_fans).or_else(|| {
                    item.get("popularity")
                        .and_then(|v| v.as_u64())
                        .and_then(fans_from_popularity)
                });
                if !id.is_empty() {
                    artists.push(ArtistItem {
                        id,
                        name,
                        art_url: Self::format_art_url(pic, 320),
                        fans,
                    });
                }
            }
        }

        // Search items carry no fan counts and their popularity can disagree
        // with the artist page, so fill fans from the artist detail (cached)
        // for the rows the UI can show. A slow detail call is dropped rather
        // than holding up the whole response.
        if !artists.is_empty() {
            let count = artists.len().min(10);
            let ids: Vec<String> = artists.iter().take(count).map(|a| a.id.clone()).collect();
            let mut resolved: Vec<Option<Option<String>>> = vec![None; count];
            let mut missing = Vec::new();
            {
                let cache = self.fans_cache.lock().unwrap_or_else(|e| e.into_inner());
                for (i, id) in ids.iter().enumerate() {
                    if let Some(fans) = cache.get(id) {
                        resolved[i] = Some(fans.clone());
                    } else {
                        missing.push(i);
                    }
                }
            }
            if !missing.is_empty() {
                let fetched = futures::future::join_all(missing.iter().map(|&i| {
                    let id = ids[i].clone();
                    async move {
                        let fans = tokio::time::timeout(
                            Duration::from_secs(2),
                            self.fetch_artist_fans(&id),
                        )
                        .await
                        .ok();
                        (i, fans)
                    }
                }))
                .await;
                let mut cache = self.fans_cache.lock().unwrap_or_else(|e| e.into_inner());
                for (i, fans) in fetched {
                    if let Some(fans) = fans {
                        if cache.len() >= 512 {
                            if let Some(evict) = cache.keys().next().cloned() {
                                cache.remove(&evict);
                            }
                        }
                        cache.insert(ids[i].clone(), fans.clone());
                        resolved[i] = Some(fans);
                    }
                }
            }
            for (i, fans) in resolved.into_iter().enumerate() {
                if let Some(fans) = fans {
                    artists[i].fans = fans;
                }
            }
        }

        let mut albums = Vec::new();
        if let Some(alb_items) = val
            .get("albums")
            .and_then(|a| a.get("items"))
            .and_then(|i| i.as_array())
        {
            for item in alb_items {
                let id = item
                    .get("id")
                    .and_then(|v| {
                        v.as_u64()
                            .map(|n| n.to_string())
                            .or_else(|| v.as_str().map(|s| s.to_string()))
                    })
                    .unwrap_or_default();
                let title = item
                    .get("title")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
                let artist = item
                    .get("artist")
                    .and_then(|a| a.get("name"))
                    .and_then(|v| v.as_str())
                    .or_else(|| {
                        item.get("artists")
                            .and_then(|a| a.as_array())
                            .and_then(|a| a.first())
                            .and_then(|a| a.get("name"))
                            .and_then(|v| v.as_str())
                    })
                    .unwrap_or_default()
                    .to_string();
                let cover = item.get("cover").and_then(|v| v.as_str());
                let year = item
                    .get("releaseDate")
                    .and_then(|v| v.as_str())
                    .and_then(|s| s.get(0..4))
                    .and_then(|y| y.parse::<u32>().ok());
                if !id.is_empty() {
                    albums.push(AlbumItem {
                        id,
                        title,
                        artist,
                        year,
                        art_url: Self::format_art_url(cover, 320),
                        release_type: release_type(item),
                        live: false,
                        popularity: 0,
                    });
                }
            }
        }

        let mut playlists = Vec::new();
        if let Some(pl_items) = val
            .get("playlists")
            .and_then(|p| p.get("items"))
            .and_then(|i| i.as_array())
        {
            for item in pl_items {
                let id = item
                    .get("uuid")
                    .or(item.get("id"))
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
                let title = item
                    .get("title")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
                let cover = item
                    .get("image")
                    .or(item.get("squareImage"))
                    .and_then(|v| v.as_str());
                let track_count = item
                    .get("numberOfTracks")
                    .and_then(|v| v.as_u64())
                    .map(|n| n as usize);
                if !id.is_empty() {
                    playlists.push(PlaylistItem {
                        id,
                        title,
                        description: None,
                        art_url: Self::format_playlist_art_url(cover),
                        track_count,
                    });
                }
            }
        }

        Ok(SearchResponse {
            tracks,
            artists,
            albums,
            playlists,
        })
    }

    pub async fn get_lyrics(
        &self,
        track_id: &str,
        title: &str,
        artist: &str,
        duration: f64,
    ) -> Result<LyricsResponse, String> {
        // 1. Try TIDAL API
        if !track_id.is_empty() {
            if let Ok(val) = self.authed_get(&format!("/tracks/{track_id}/lyrics")).await {
                let subtitles = val.get("subtitles").and_then(|v| v.as_str());
                let text = val.get("lyrics").and_then(|v| v.as_str());
                if subtitles.is_some() || text.is_some() {
                    return Ok(LyricsResponse {
                        synced: subtitles.is_some(),
                        subtitles: subtitles.map(|s| s.to_string()),
                        text: text.map(|s| s.to_string()),
                    });
                }
            }
        }

        // 2. Fallback to LRCLIB
        if !title.is_empty() && !artist.is_empty() {
            let dur_param = if duration.is_finite() && duration > 0.0 {
                format!("&duration={}", duration.round() as u64)
            } else {
                String::new()
            };
            let lrclib_url = format!(
                "https://lrclib.net/api/get?track_name={}&artist_name={}{}",
                urlencoding_simple(title),
                urlencoding_simple(artist),
                dur_param
            );

            if let Ok(res) = self.http.get(&lrclib_url).send().await {
                if res.status().is_success() {
                    if let Ok(val) = res.json::<serde_json::Value>().await {
                        let synced_lyrics = val.get("syncedLyrics").and_then(|v| v.as_str());
                        let plain_lyrics = val.get("plainLyrics").and_then(|v| v.as_str());
                        if synced_lyrics.is_some() || plain_lyrics.is_some() {
                            return Ok(LyricsResponse {
                                synced: synced_lyrics.is_some(),
                                subtitles: synced_lyrics.map(|s| s.to_string()),
                                text: plain_lyrics.map(|s| s.to_string()),
                            });
                        }
                    }
                }
            }
        }

        Ok(LyricsResponse::default())
    }

    fn parse_track_items(val: &serde_json::Value) -> Result<Vec<TrackItem>, String> {
        Self::parse_track_items_from(val, None)
    }

    /// `parse_track_items` with `item_index` filled in as `base_index` plus
    /// each item's raw position in the response. The parser drops unplayable
    /// items, so the position in the returned list is not the index TIDAL's
    /// item mutations address; the raw position is. Every page of a playlist
    /// fetch passes its absolute item offset as the base.
    fn parse_track_items_from(
        val: &serde_json::Value,
        base_index: Option<usize>,
    ) -> Result<Vec<TrackItem>, String> {
        let mut tracks = Vec::new();
        if let Some(items) = val.get("items").and_then(|v| v.as_array()) {
            for (position, item) in items.iter().enumerate() {
                let track_obj = item.get("item").unwrap_or(item);
                if let Some(mut t) = Self::parse_single_track(track_obj) {
                    if let Some(base) = base_index {
                        t.item_index = Some(base + position);
                    }
                    tracks.push(t);
                }
            }
        }
        Ok(tracks)
    }

    /// One `{id, name}` credit object; `None` when the name is blank.
    fn parse_artist_credit(value: Option<&serde_json::Value>) -> Option<ArtistCredit> {
        let artist = value?;
        let name = artist.get("name")?.as_str()?.trim();
        if name.is_empty() {
            return None;
        }
        let id = artist.get("id").and_then(|v| {
            v.as_u64()
                .map(|n| n.to_string())
                .or_else(|| v.as_str().map(str::to_string))
        });
        Some(ArtistCredit {
            id,
            name: name.to_string(),
        })
    }

    fn parse_artist_credits(value: Option<&serde_json::Value>) -> Vec<ArtistCredit> {
        value
            .and_then(serde_json::Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(|artist| Self::parse_artist_credit(Some(artist)))
                    .collect()
            })
            .unwrap_or_default()
    }

    fn parse_single_track(val: &serde_json::Value) -> Option<TrackItem> {
        let id = val.get("id").and_then(|v| {
            v.as_u64()
                .map(|n| n.to_string())
                .or_else(|| v.as_str().map(|s| s.to_string()))
        })?;
        let title = val.get("title").and_then(|v| v.as_str())?.to_string();

        let artists: Vec<ArtistCredit> = Self::parse_artist_credits(val.get("artists"));

        let artist = if artists.is_empty() {
            val.get("artist")
                .and_then(|a| a.get("name"))
                .and_then(|v| v.as_str())
                .unwrap_or("Unknown Artist")
                .to_string()
        } else {
            artists
                .iter()
                .map(|artist| artist.name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        };

        let artist_id = val
            .get("artist")
            .and_then(|a| a.get("id"))
            .and_then(|v| {
                v.as_u64()
                    .map(|n| n.to_string())
                    .or_else(|| v.as_str().map(|s| s.to_string()))
            })
            .or_else(|| {
                val.get("artists")
                    .and_then(|arr| arr.as_array())
                    .and_then(|a| a.first())
                    .and_then(|a| a.get("id"))
                    .and_then(|v| {
                        v.as_u64()
                            .map(|n| n.to_string())
                            .or_else(|| v.as_str().map(|s| s.to_string()))
                    })
            });

        let album_id = val.get("album").and_then(|a| a.get("id")).and_then(|v| {
            v.as_u64()
                .map(|n| n.to_string())
                .or_else(|| v.as_str().map(|s| s.to_string()))
        });

        let album = val
            .get("album")
            .and_then(|a| a.get("title"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let cover = val
            .get("album")
            .and_then(|a| a.get("cover"))
            .and_then(|v| v.as_str());
        let video_cover = val
            .get("album")
            .and_then(|a| a.get("videoCover"))
            .and_then(|v| v.as_str());
        let duration = val
            .get("duration")
            .and_then(|v| v.as_f64().or_else(|| v.as_u64().map(|n| n as f64)))
            .unwrap_or(0.0);
        let audio_quality = val
            .get("audioQuality")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        let explicit = val
            .get("explicit")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let allow_streaming = val
            .get("allowStreaming")
            .and_then(|v| v.as_bool())
            .unwrap_or(true);
        let stream_ready = val
            .get("streamReady")
            .and_then(|v| v.as_bool())
            .unwrap_or(true);
        let available = allow_streaming && stream_ready;

        Some(TrackItem {
            id,
            title,
            artist,
            album,
            artist_id,
            artists,
            album_id,
            duration,
            art_url: Self::format_art_url(cover, 640),
            video_url: Self::format_video_url(video_cover, VIDEO_COVER_SIZE),
            audio_quality,
            explicit,
            available,
            tlid: None,
            item_index: None,
        })
    }
}

/// True for permanent album-lookup errors that should be cached as "no video
/// cover" so status polling does not hammer TIDAL on every tick.
fn is_permanent_album_error(err: &str) -> bool {
    err.contains("HTTP error 404") || err.contains("HTTP error 403")
}

/// True when a TIDAL HTTP 401 response means the requested asset cannot be
/// streamed (e.g. region-locked or removed, `subStatus: 4005`) rather than an
/// expired OAuth token.
fn is_asset_unavailable_401(body: &str) -> bool {
    if let Ok(val) = serde_json::from_str::<serde_json::Value>(body) {
        if val.get("subStatus").and_then(|v| v.as_u64()) == Some(4005) {
            return true;
        }
    }
    body.contains("Asset is not ready for playback")
}

fn clean_bio_text(raw: &str) -> String {
    let mut cleaned = String::with_capacity(raw.len());
    let mut in_bracket = false;
    let mut in_tag = false;
    let mut tag = String::new();
    for c in raw.chars() {
        if c == '[' {
            in_bracket = true;
        } else if c == ']' {
            in_bracket = false;
        } else if c == '<' {
            in_tag = true;
            tag.clear();
        } else if c == '>' {
            // TIDAL writes paragraph breaks as <br/> in the bio HTML; keep
            // them, drop every other tag.
            if in_tag
                && tag
                    .trim()
                    .trim_end_matches('/')
                    .trim()
                    .eq_ignore_ascii_case("br")
            {
                cleaned.push_str("\n\n");
            }
            in_tag = false;
            tag.clear();
        } else if in_bracket {
            // wimpLink markup, dropped
        } else if in_tag {
            tag.push(c);
        } else {
            cleaned.push(c);
        }
    }
    // Collapse whitespace inside each line, join wrapped lines with a space,
    // and keep blank-line runs as paragraph breaks so the bio sheet renders
    // real paragraphs instead of one wall of text.
    let mut result = String::with_capacity(cleaned.len());
    let mut paragraph_open = false;
    let mut pending_break = false;
    for line in cleaned.split('\n') {
        let mut line_text = String::new();
        for word in line.split_whitespace() {
            if !line_text.is_empty() {
                line_text.push(' ');
            }
            line_text.push_str(word);
        }
        if line_text.is_empty() {
            pending_break = paragraph_open;
            continue;
        }
        if paragraph_open {
            if pending_break {
                result.push_str("\n\n");
            } else {
                result.push(' ');
            }
        }
        result.push_str(&line_text);
        paragraph_open = true;
        pending_break = false;
    }
    result
}

/// TIDAL search results expose popularity, not fan counts. The artist page
/// estimates fans from popularity when the detail response is missing them,
/// and search rows reuse the same estimate.
fn fans_from_popularity(popularity: u64) -> Option<String> {
    if popularity == 0 {
        return None;
    }
    let estimated = if popularity <= 75 {
        ((popularity as f64 / 75.0).powf(2.8) * 154_100.0).round() as u64
    } else {
        let t = (popularity - 75) as f64 / 25.0;
        (154_100.0 * (t * 4.9).exp()).round() as u64
    };
    format_fans(&serde_json::json!(estimated.max(10)))
}

fn parse_playlist_item(item: &serde_json::Value) -> Option<PlaylistItem> {
    let id = item
        .get("uuid")
        .or_else(|| item.get("id"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if id.is_empty() {
        return None;
    }
    let art_hash = item
        .get("image")
        .or_else(|| item.get("squareImage"))
        .and_then(|v| v.as_str());
    Some(PlaylistItem {
        id,
        title: item
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        description: item
            .get("description")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()),
        art_url: CatalogueManager::format_playlist_art_url(art_hash),
        track_count: item
            .get("numberOfTracks")
            .and_then(|v| v.as_u64())
            .map(|n| n as usize),
    })
}

/// One artist's `filter=ALL` release feed as the discography shows it: newest
/// first, with albums, EPs and singles in the same list. TIDAL frequently
/// returns the same release several times (stereo and Dolby Atmos versions,
/// regional duplicates) with identical visible metadata, so titles are
/// de-duplicated by normalised title + year + release kind.
fn parse_artist_releases(items: &[serde_json::Value], artist_name: &str) -> Vec<AlbumItem> {
    let mut releases = Vec::new();
    let mut seen = HashSet::new();

    for item in items {
        let id = item
            .get("id")
            .and_then(|v| {
                v.as_u64()
                    .map(|n| n.to_string())
                    .or_else(|| v.as_str().map(|s| s.to_string()))
            })
            .unwrap_or_default();
        let title = item
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        if id.is_empty() || title.trim().is_empty() {
            continue;
        }

        let cover_hash = item.get("cover").and_then(|v| v.as_str());
        let year = item
            .get("releaseDate")
            .and_then(|v| v.as_str())
            .and_then(|s| s.get(0..4))
            .and_then(|y| y.parse::<u32>().ok());
        let release_type = release_type(item);
        let key = format!(
            "{}|{}|{}",
            title.trim().to_lowercase(),
            year.map(|y| y.to_string()).unwrap_or_default(),
            release_type.clone().unwrap_or_default()
        );
        if !seen.insert(key) {
            continue;
        }

        let live = is_live_release(&title, item.get("version").and_then(|v| v.as_str()));
        releases.push(AlbumItem {
            id,
            title,
            artist: artist_name.to_string(),
            year,
            art_url: CatalogueManager::format_art_url(cover_hash, 320),
            release_type,
            live,
            popularity: item
                .get("popularity")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as u32,
        });
    }

    releases
}

/// TIDAL has no live-release classification: `type` is only ALBUM/EP/SINGLE,
/// and v2's `albumType` agrees. A live set is recognisable only from the title
/// or its `version` tag, so match the unambiguous shapes and leave titles that
/// merely contain the word ("You Live Inside My Heart", "I Live at Night",
/// "Live Through This") in the studio buckets. Position matters: a title that
/// opens with "Live at/from/in/on", carries a "- Live" / ": Live" separator or
/// a parenthesised "Live" is a live set, while the same words mid-sentence are
/// a studio song.
///
/// A bare trailing " Live" is deliberately *not* matched. It is the one shape
/// that also appears on ordinary studio releases ("K.Flay on Audiotree Live"
/// was an EP, "Rumours Live" a reissue title nobody tagged), so albums like
/// *Alchemy: Dire Straits Live* are missed rather than a studio album being
/// filed as live.
fn is_live_release(title: &str, version: Option<&str>) -> bool {
    if version.is_some_and(contains_live_word) {
        return true;
    }

    let lower = title.trim().to_lowercase();
    if lower.is_empty() {
        return false;
    }
    if lower.trim_end_matches(['!', '.', ' ']) == "live" {
        return true;
    }

    const LEAD_INS: [&str; 4] = ["live at ", "live from ", "live in ", "live on "];
    if LEAD_INS.iter().any(|lead| lower.starts_with(lead)) {
        return true;
    }

    let padded = format!(" {lower} ");
    const SEPARATORS: [&str; 4] = [" - live ", ": live ", " live 19", " live 20"];
    SEPARATORS.iter().any(|needle| padded.contains(needle))
        || lower.contains("unplugged")
        || has_live_segment(&lower)
}

/// A parenthesised or bracketed segment that opens with "live": "(Live)",
/// "(Live at Wembley 1985)", "[Live]". Deliberately not a bare word match, so
/// "The Day We Live" does not qualify.
fn has_live_segment(lower: &str) -> bool {
    for (open, close) in [('(', ')'), ('[', ']')] {
        let mut rest = lower;
        while let Some(pos) = rest.find(open) {
            let after = &rest[pos + open.len_utf8()..];
            let segment = after.split(close).next().unwrap_or(after).trim_start();
            if segment == "live" || segment.starts_with("live ") || segment.starts_with("live,") {
                return true;
            }
            rest = after;
        }
    }
    false
}

/// Whole-word marker match for a release's `version` tag, which only ever
/// qualifies a title ("San Antonio Live In 85").
fn contains_live_word(text: &str) -> bool {
    text.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .any(|word| word == "live" || word == "unplugged")
}

/// TIDAL tags releases as ALBUM/EP/SINGLE; search rows show singles as such.
fn release_type(value: &serde_json::Value) -> Option<String> {
    value
        .get("type")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_uppercase())
        .filter(|s| !s.is_empty())
}

fn format_fans(value: &serde_json::Value) -> Option<String> {
    if let Some(count) = value.as_u64() {
        let (scaled, suffix) = if count >= 1_000_000 {
            (count as f64 / 1_000_000.0, "M")
        } else if count >= 1_000 {
            (count as f64 / 1_000.0, "K")
        } else {
            return Some(format!("{count} fans"));
        };
        let rounded = (scaled * 10.0).round() / 10.0;
        let amount = if rounded.fract() == 0.0 {
            format!("{rounded:.0}")
        } else {
            format!("{rounded:.1}")
        };
        return Some(format!("{amount}{suffix} fans"));
    }

    value.as_str().map(|fans| {
        let fans = fans.trim();
        if fans.ends_with("fans") {
            fans.to_string()
        } else if let Ok(count) = fans.parse::<u64>() {
            format_fans(&serde_json::json!(count)).unwrap_or_else(|| format!("{fans} fans"))
        } else {
            format!("{fans} fans")
        }
    })
}

fn base64_decode(input: &str) -> Result<Vec<u8>, String> {
    // Simple base64 decode without extra crate
    let mut out = Vec::new();
    let mut buf = 0u32;
    let mut bits = 0;
    for &b in input.as_bytes() {
        let v = match b {
            b'A'..=b'Z' => b - b'A',
            b'a'..=b'z' => b - b'a' + 26,
            b'0'..=b'9' => b - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            b'=' | b'\r' | b'\n' => continue,
            _ => continue,
        };
        buf = (buf << 6) | (v as u32);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
        }
    }
    Ok(out)
}

fn urlencoding_simple(s: &str) -> String {
    let mut res = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.' || b == b'~' {
            res.push(b as char);
        } else {
            res.push_str(&format!("%{:02X}", b));
        }
    }
    res
}

#[cfg(test)]
mod tests {
    use super::{
        clean_bio_text, entity_favorite_id, fans_from_popularity, favorite_track_id, format_fans,
        is_asset_unavailable_401, is_live_release, is_permanent_album_error,
        parse_artist_releases, CatalogueManager, EntityFavorites, FavoriteTracks, RecentStream,
        RecentStreams, FAVORITE_CACHE_TTL, RECENT_STREAMS, RECENT_STREAM_MAX_AGE,
    };
    use std::time::Instant;

    fn base64_encode(input: &[u8]) -> String {
        const ALPHABET: &[u8; 64] =
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::with_capacity(input.len() * 4 / 3 + 4);
        for chunk in input.chunks(3) {
            let first = chunk[0] as u32;
            let second = chunk.get(1).copied().unwrap_or(0) as u32;
            let third = chunk.get(2).copied().unwrap_or(0) as u32;
            let bits = (first << 16) | (second << 8) | third;
            out.push(ALPHABET[((bits >> 18) & 63) as usize] as char);
            out.push(ALPHABET[((bits >> 12) & 63) as usize] as char);
            out.push(if chunk.len() > 1 {
                ALPHABET[((bits >> 6) & 63) as usize] as char
            } else {
                '='
            });
            out.push(if chunk.len() > 2 {
                ALPHABET[(bits & 63) as usize] as char
            } else {
                '='
            });
        }
        out
    }

    #[test]
    fn materialize_stream_builds_a_local_dash_manifest() {
        let manifest = concat!(
            r#"<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static">"#,
            r#"<Period><AdaptationSet><Representation>"#,
            r#"<BaseURL>https://example/seg?Signature=x</BaseURL>"#,
            r#"</Representation></AdaptationSet></Period></MPD>"#
        );
        let response = serde_json::json!({
            "manifestMimeType": "application/dash+xml",
            "manifest": base64_encode(manifest.as_bytes()),
            "bitDepth": 24,
            "sampleRate": 48000,
            "audioQuality": "HI_RES_LOSSLESS",
        });

        let stream =
            CatalogueManager::materialize_stream("unit-test-track", &response).unwrap();

        assert!(stream.url.starts_with("file://"));
        assert!(stream.url.ends_with("manifest-unit-test-track.mpd"));
        assert!(stream.manifest.contains("<MPD"));
        assert_eq!(stream.format.bit_depth, 24);
        assert_eq!(stream.format.sample_rate, 48_000);
        assert_eq!(stream.format.badge, "24-bit / 48 kHz FLAC");
        let _ = std::fs::remove_file(stream.url.trim_start_matches("file://"));
    }

    #[test]
    fn materialize_stream_rejects_non_dash_manifests() {
        let response = serde_json::json!({
            "manifestMimeType": "application/vnd.tidal.bts",
            "manifest": base64_encode(
                serde_json::json!({
                    "mimeType": "audio/mp4",
                    "urls": ["https://example/seg?id=1"]
                })
                .to_string()
                .as_bytes()
            ),
            "audioQuality": "HIGH",
        });

        let err = CatalogueManager::materialize_stream("unit-test-non-dash", &response)
            .err()
            .expect("non-DASH manifests must be rejected");
        assert!(err.contains("DASH"));
    }

    #[test]
    fn entity_favorites_cache_updates_and_expires() {
        let mut favorites = EntityFavorites {
            ids: ["albums-1".to_string()].into_iter().collect(),
            fetched_at: Instant::now(),
        };
        assert!(favorites.is_fresh());
        assert!(favorites.ids.contains("albums-1"));

        favorites.set("albums-1", false);
        favorites.set("albums-2", true);
        assert!(!favorites.ids.contains("albums-1"));
        assert!(favorites.ids.contains("albums-2"));

        favorites.fetched_at = Instant::now() - FAVORITE_CACHE_TTL;
        assert!(!favorites.is_fresh());
    }

    #[test]
    fn entity_favorite_id_reads_ids_and_uuids() {
        assert_eq!(
            entity_favorite_id(&serde_json::json!({"item": {"id": 42}})).as_deref(),
            Some("42")
        );
        assert_eq!(
            entity_favorite_id(&serde_json::json!({"uuid": "abc"})).as_deref(),
            Some("abc")
        );
        assert_eq!(entity_favorite_id(&serde_json::json!({"item": {}})), None);
    }

    #[test]
    fn favorite_tracks_cache_is_per_user_and_expires() {
        let mut favorites = FavoriteTracks {
            user_id: 7,
            ids: ["1".to_string(), "2".to_string()].into_iter().collect(),
            fetched_at: Instant::now(),
        };
        assert!(favorites.is_fresh(7));
        assert!(!favorites.is_fresh(8));
        assert!(favorites.ids.contains("1"));

        favorites.set("1", false);
        favorites.set("3", true);
        assert!(!favorites.ids.contains("1"));
        assert!(favorites.ids.contains("3"));

        favorites.fetched_at = Instant::now() - FAVORITE_CACHE_TTL;
        assert!(!favorites.is_fresh(7));
    }

    #[test]
    fn favorite_track_id_reads_wrapped_and_plain_ids() {
        assert_eq!(
            favorite_track_id(&serde_json::json!({"item": {"id": 42}})).as_deref(),
            Some("42")
        );
        assert_eq!(
            favorite_track_id(&serde_json::json!({"id": "abc"})).as_deref(),
            Some("abc")
        );
        assert_eq!(favorite_track_id(&serde_json::json!({"item": {}})), None);
    }

    #[test]
    fn format_video_url_builds_mp4_urls_and_passes_through_absolute_ones() {
        assert_eq!(
            CatalogueManager::format_video_url(
                Some("5069f6a9-ff96-4a6f-a1fb-0d9c4413d9c4"),
                640
            )
            .as_deref(),
            Some("https://resources.tidal.com/videos/5069f6a9/ff96/4a6f/a1fb/0d9c4413d9c4/640x640.mp4")
        );
        assert_eq!(CatalogueManager::format_video_url(None, 640), None);
        assert_eq!(CatalogueManager::format_video_url(Some(""), 640), None);
        assert_eq!(
            CatalogueManager::format_video_url(Some("https://example.com/cover.mp4"), 640)
                .as_deref(),
            Some("https://example.com/cover.mp4")
        );
    }

    #[test]
    fn format_fans_compacts_counts_and_preserves_formatted_values() {
        assert_eq!(
            format_fans(&serde_json::json!(154_100)).as_deref(),
            Some("154.1K fans")
        );
        assert_eq!(
            format_fans(&serde_json::json!(2_000_000)).as_deref(),
            Some("2M fans")
        );
        assert_eq!(
            format_fans(&serde_json::json!("154.1K fans")).as_deref(),
            Some("154.1K fans")
        );
    }

    #[test]
    fn fans_from_popularity_estimates_and_rejects_zero() {
        assert_eq!(fans_from_popularity(0), None);
        assert_eq!(fans_from_popularity(80).as_deref(), Some("410.6K fans"));
    }

    #[test]
    fn artist_releases_stay_in_feed_order_and_flag_live_sets() {
        let items = vec![
            serde_json::json!({"id": 1, "title": "Album", "type": "ALBUM", "releaseDate": "2024-01-01", "cover": "a"}),
            serde_json::json!({"id": 2, "title": "album", "type": "ALBUM", "releaseDate": "2024-02-01", "cover": "b"}),
            serde_json::json!({"id": 3, "title": "Single", "type": "SINGLE", "releaseDate": "2024-01-01"}),
            serde_json::json!({"id": 4, "title": "Single", "type": "SINGLE", "releaseDate": "2024-01-01"}),
            serde_json::json!({"id": 5, "title": "EP", "type": "EP", "releaseDate": "2023-01-01"}),
            serde_json::json!({"id": 6, "title": "Live at the BBC", "type": "ALBUM", "releaseDate": "2022-01-01"}),
            serde_json::json!({"id": 7, "title": "Song (Live)", "type": "SINGLE", "releaseDate": "2025-01-01"}),
        ];
        let releases = parse_artist_releases(&items, "AURORA");
        assert_eq!(
            releases.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(),
            ["1", "3", "5", "6", "7"]
        );
        assert_eq!(releases[2].release_type.as_deref(), Some("EP"));
        assert_eq!(releases[3].year, Some(2022));
        assert!(releases[3].live);
        assert!(releases[4].live);
        assert!(releases[..3].iter().all(|release| !release.live));
        assert!(releases.iter().all(|release| release.artist == "AURORA"));
    }

    #[test]
    fn live_release_detection_skips_studio_titles_that_use_the_word() {
        assert!(is_live_release("Live at the BBC", None));
        assert!(is_live_release("Live From The Record Plant", None));
        assert!(is_live_release("Live 1978 - 1992", None));
        assert!(is_live_release("Fleetwood Mac: Live 1975", None));
        assert!(is_live_release("The Seed (Live from the Royal Albert Hall)", None));
        assert!(is_live_release("Cure For Me [Live]", None));
        assert!(is_live_release("MTV Unplugged in New York", None));
        assert!(is_live_release("Studio", Some("San Antonio Live In 85")));
        assert!(is_live_release("The Song - Live at Wembley", None));

        // A bare trailing " Live" is not enough: these are studio releases.
        assert!(!is_live_release("K.Flay on Audiotree Live", None));
        assert!(!is_live_release("Rumours Live", None));
        assert!(!is_live_release("Alchemy: Dire Straits Live", None));
        assert!(!is_live_release("You Live Inside My Heart", None));
        assert!(!is_live_release("I Live at Night", None));
        assert!(!is_live_release("Live Through This", None));
        assert!(!is_live_release("Live and Let Die", None));
        assert!(!is_live_release("Where We Live", None));
        assert!(!is_live_release("Alive", None));
    }

    #[test]
    fn clean_bio_text_strips_wimp_links_and_tags() {
        let raw = "Mixing frosty electronic textures, singer/songwriter [wimpLink artistId=\"55225\"]AURORA[/wimpLink] works in a...\n\nAnother paragraph.";
        assert_eq!(
            clean_bio_text(raw),
            "Mixing frosty electronic textures, singer/songwriter AURORA works in a...\n\nAnother paragraph."
        );
    }

    #[test]
    fn clean_bio_text_joins_wrapped_lines_but_keeps_paragraphs() {
        let raw =
            "First line of a paragraph\ncontinues here\n\nSecond paragraph\n\n\nThird paragraph";
        assert_eq!(
            clean_bio_text(raw),
            "First line of a paragraph continues here\n\nSecond paragraph\n\nThird paragraph"
        );
    }

    #[test]
    fn clean_bio_text_turns_br_tags_into_paragraph_breaks() {
        let raw = "First paragraph<br/>Second paragraph<br />Third";
        assert_eq!(
            clean_bio_text(raw),
            "First paragraph\n\nSecond paragraph\n\nThird"
        );
    }

    #[test]
    fn parse_artist_credits_keeps_ids_and_drops_blank_names() {
        let value = serde_json::json!([
            { "id": 42, "name": " AURORA " },
            { "name": "" },
            { "id": "99", "name": "Bring Me The Horizon" },
            { "id": 7 }
        ]);
        let credits = CatalogueManager::parse_artist_credits(Some(&value));
        assert_eq!(credits.len(), 2);
        assert_eq!(credits[0].id.as_deref(), Some("42"));
        assert_eq!(credits[0].name, "AURORA");
        assert_eq!(credits[1].id.as_deref(), Some("99"));
        assert!(CatalogueManager::parse_artist_credits(None).is_empty());
    }

    #[test]
    fn parse_artist_credit_reads_a_single_object() {
        let value = serde_json::json!({ "id": 7, "name": "Kavinsky" });
        let credit = CatalogueManager::parse_artist_credit(Some(&value)).unwrap();
        assert_eq!(credit.id.as_deref(), Some("7"));
        assert_eq!(credit.name, "Kavinsky");
        assert!(CatalogueManager::parse_artist_credit(None).is_none());
    }

    #[test]
    fn a_recently_stored_stream_is_reused_and_can_be_dropped() {
        let streams = RecentStreams::default();
        streams.store("track-1", "https://cdn.example/stream.mpd", &Default::default());
        let hit = streams.get("track-1").expect("the stored stream was not reused");
        assert_eq!(hit.0, "https://cdn.example/stream.mpd");
        // An unknown track is never served from the cache.
        assert!(streams.get("track-2").is_none());
        streams.remove("track-1");
        assert!(streams.get("track-1").is_none());
        // A wake drops everything at once.
        streams.store("track-3", "https://cdn.example/3.mpd", &Default::default());
        streams.store("track-4", "https://cdn.example/4.mpd", &Default::default());
        streams.clear();
        assert!(streams.get("track-3").is_none());
        assert!(streams.get("track-4").is_none());
    }

    #[test]
    fn an_old_stream_is_not_reused() {
        let streams = RecentStreams::default();
        streams.entries.lock().unwrap().insert(
            "track-1".to_string(),
            RecentStream {
                url: "https://cdn.example/stream.mpd".to_string(),
                format: Default::default(),
                fetched: Instant::now()
                    .checked_sub(RECENT_STREAM_MAX_AGE + std::time::Duration::from_secs(60))
                    .expect("a point in time exists before now"),
            },
        );
        assert!(streams.get("track-1").is_none());
        // The stale entry is dropped, not just ignored.
        assert!(streams.entries.lock().unwrap().is_empty());
    }

    #[test]
    fn a_stream_whose_manifest_is_gone_is_not_reused() {
        let streams = RecentStreams::default();
        streams.store(
            "track-1",
            "file:///definitely/not/here.mpd",
            &Default::default(),
        );
        assert!(streams.get("track-1").is_none());
    }

    #[test]
    fn storing_streams_keeps_only_the_most_recent_ones() {
        let streams = RecentStreams::default();
        let mut entries = streams.entries.lock().unwrap();
        for i in 0..RECENT_STREAMS {
            entries.insert(
                format!("old-{i}"),
                RecentStream {
                    url: format!("https://cdn.example/{i}.mpd"),
                    format: Default::default(),
                    fetched: Instant::now()
                        .checked_sub(std::time::Duration::from_secs(60 * (i as u64 + 1)))
                        .expect("a point in time exists before now"),
                },
            );
        }
        drop(entries);
        streams.store("new", "https://cdn.example/new.mpd", &Default::default());
        let entries = streams.entries.lock().unwrap();
        assert_eq!(entries.len(), RECENT_STREAMS);
        assert!(entries.contains_key("new"));
        // `old-{RECENT_STREAMS-1}` was stored furthest in the past.
        assert!(
            !entries.contains_key(&format!("old-{}", RECENT_STREAMS - 1)),
            "the oldest entry was kept"
        );
        assert!(entries.contains_key("old-0"));
    }

    #[test]
    fn permanent_album_errors_are_distinguished_from_transient_ones() {
        assert!(is_permanent_album_error(
            r#"HTTP error 404 Not Found: {"status":404,"subStatus":2001,"userMessage":"Album [212455154] not found"}"#
        ));
        assert!(is_permanent_album_error("HTTP error 403 Forbidden: nope"));
        assert!(!is_permanent_album_error("HTTP error 429 Too Many Requests"));
        assert!(!is_permanent_album_error("HTTP error 503 Service Unavailable"));
        assert!(!is_permanent_album_error("Request failed: timed out"));
    }

    #[test]
    fn asset_unavailable_401_is_not_treated_as_expired_token() {
        assert!(is_asset_unavailable_401(
            r#"{"status":401,"subStatus":4005,"userMessage":"Asset is not ready for playback"}"#
        ));
        assert!(!is_asset_unavailable_401(
            r#"{"status":401,"subStatus":11003,"userMessage":"Token expired"}"#
        ));
        assert!(!is_asset_unavailable_401("Unauthorized"));
    }

    #[test]
    fn parse_single_track_marks_unavailable_tracks_from_streaming_flags() {
        let playable = CatalogueManager::parse_single_track(&serde_json::json!({
            "id": 1,
            "title": "Playable",
            "allowStreaming": true,
            "streamReady": true
        }))
        .unwrap();
        assert!(playable.available);

        let omitted = CatalogueManager::parse_single_track(&serde_json::json!({
            "id": 2,
            "title": "Omitted"
        }))
        .unwrap();
        assert!(omitted.available);

        let not_ready = CatalogueManager::parse_single_track(&serde_json::json!({
            "id": 212455156,
            "title": "Everything Matters",
            "allowStreaming": false,
            "streamReady": false
        }))
        .unwrap();
        assert!(!not_ready.available);

        let allow_only = CatalogueManager::parse_single_track(&serde_json::json!({
            "id": 3,
            "title": "Half",
            "allowStreaming": true,
            "streamReady": false
        }))
        .unwrap();
        assert!(!allow_only.available);
    }
}
