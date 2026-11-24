use crate::api::PlaybackError;
use crate::catalogue::CatalogueManager;
use crate::cast::CastManager;
use crate::mpv::{
    ensure_audio_client_ready, run_stream_op, FormatInfo, MpvPlayer, STREAM_LOAD_TIMEOUT,
};
use crate::queue::{QueueManager, TrackItem};
use crate::{record_playback_error, stream_fetch_error_is_retryable, wait_while_current};
use futures::StreamExt;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{Mutex, RwLock};
use tracing::{info, warn};

/// How long the wake-time stream preparation may take before mpv is treated
/// as unresponsive and replaced. A healthy IPC load returns in milliseconds;
/// the timeout only fires when mpv itself is stuck.
const STREAM_PREPARE_TIMEOUT: Duration = Duration::from_secs(10);

/// How long a wake-time refresh keeps trying to reach TIDAL. A machine often
/// finishes resuming before the network does: DHCP, WireGuard or a router
/// reboot can be minutes behind the resume signal. The old fixed six-attempt
/// window (24 s) expired inside that gap and left playback dead until the user
/// pressed Play, so the wake path now polls until this budget runs out.
const WAKE_FETCH_BUDGET: Duration = Duration::from_secs(600);

/// Attempts for a refresh that is not recovering from sleep (a long pause or
/// an automatic retry): the audio server is already up, so the network is the
/// only suspect and a short window is enough.
const REFRESH_FETCH_ATTEMPTS: u32 = 6;
const REFRESH_FETCH_DELAY: Duration = Duration::from_secs(4);

/// Backoff between wake-time fetch attempts: two quick retries for a network
/// that re-associates in seconds, then a capped half-minute poll. The schedule
/// must stay non-decreasing and end at the cap so a long outage costs one
/// request every 30 s, not a tight loop.
fn wake_fetch_delay(attempt: u32) -> Duration {
    let seconds = match attempt {
        1 | 2 => 4,
        3 | 4 => 8,
        5 | 6 => 15,
        _ => 30,
    };
    Duration::from_secs(seconds)
}

/// Whether one more wake-time attempt fits inside the budget. Kept separate so
/// the give-up point can be tested without sleeping through it.
fn wake_attempt_fits(attempt: u32, elapsed: Duration, budget: Duration) -> bool {
    elapsed + wake_fetch_delay(attempt) <= budget
}

/// Whether a refresh produced a loaded stream, or was superseded while it was
/// waiting (another track, a pause, or the machine going back to sleep). A
/// superseded refresh must not be reported as a playback failure.
enum RefreshOutcome {
    Loaded,
    Cancelled,
}

#[zbus::proxy(
    default_service = "org.freedesktop.login1",
    default_path = "/org/freedesktop/login1",
    interface = "org.freedesktop.login1.Manager"
)]
trait LoginManager {
    #[zbus(signal)]
    fn prepare_for_sleep(&self, start: bool) -> zbus::Result<()>;
}

/// Spawns a background task monitoring systemd-logind sleep/wake signals.
///
/// On wake the pre-sleep stream URI is discarded instead of being prerolled:
/// TIDAL CDN tokens expire while the machine is asleep, so the old URI answers
/// with HTTP 403. A fresh stream URL for the current queue track is fetched
/// once the audio server is back, then parked at the saved position.
pub fn start_sleep_monitor(
    player: Arc<MpvPlayer>,
    queue: Arc<QueueManager>,
    catalogue: Arc<CatalogueManager>,
    playback_command_lock: Arc<Mutex<()>>,
    playback_error: Arc<RwLock<Option<PlaybackError>>>,
    cast: Arc<CastManager>,
) {
    tokio::spawn(async move {
        loop {
            let system_conn = match zbus::Connection::system().await {
                Ok(c) => c,
                Err(e) => {
                    warn!("Could not connect to system D-Bus for sleep monitoring: {e}; retrying");
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }
            };

            let proxy = match LoginManagerProxy::new(&system_conn).await {
                Ok(p) => p,
                Err(e) => {
                    warn!("Could not create LoginManager D-Bus proxy: {e}; retrying");
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }
            };

            let mut stream = match proxy.receive_prepare_for_sleep().await {
                Ok(s) => s,
                Err(e) => {
                    warn!("Could not subscribe to PrepareForSleep signal: {e}; retrying");
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }
            };

            info!("Registered sleep/wake event listener (systemd-logind PrepareForSleep)");

            while let Some(signal) = stream.next().await {
                match signal.args() {
                    Ok(args) => {
                        if args.start {
                            info!("System preparing for sleep: stopping the mpv player cleanly");
                            // End a cast session while the network still
                            // works: the receiver is left stopped and the
                            // track parked locally at its playhead, exactly
                            // like mpv, so wake finds a parked player instead
                            // of a session whose bridge died in the night.
                            cast.suspend().await;
                            // Record the pre-sleep position and bump sleep_epoch
                            // synchronously so a rapid suspend/resume cannot
                            // miss `saved_sleep_position`, then run the blocking
                            // mpv stop off the async runtime.
                            let token = player.sleep_token();
                            if let Some(had_playback) = player.begin_prepare_for_sleep(token) {
                                let player = player.clone();
                                tokio::task::spawn_blocking(move || {
                                    player.finish_prepare_for_sleep(token, had_playback);
                                });
                            }
                        } else {
                            info!("System resumed from sleep: scheduling a fresh stream");
                            player.resume_from_sleep();
                            catalogue.clear_cache();
                            if player.has_saved_sleep_position() {
                                tokio::spawn(restore_stream_after_wake(
                                    player.clone(),
                                    queue.clone(),
                                    catalogue.clone(),
                                    playback_command_lock.clone(),
                                    playback_error.clone(),
                                ));
                            }
                        }
                    }
                    Err(e) => {
                        warn!("Error reading PrepareForSleep signal args: {e}");
                    }
                }
            }

            // The signal stream can end if systemd-logind or the system bus
            // restarts. Reconnect rather than silently losing sleep handling.
            warn!("PrepareForSleep signal stream ended; resubscribing");
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    });
}

async fn restore_stream_after_wake(
    player: Arc<MpvPlayer>,
    queue: Arc<QueueManager>,
    catalogue: Arc<CatalogueManager>,
    playback_command_lock: Arc<Mutex<()>>,
    playback_error: Arc<RwLock<Option<PlaybackError>>>,
) {
    if let Err(e) = refresh_current_stream(
        &player,
        &queue,
        &catalogue,
        &playback_command_lock,
        true,
        &playback_error,
    )
    .await
    {
        warn!("Could not restore playback after wake: {e}");
    }
}

/// Waits for the audio server, re-fetches the current track's stream URL and
/// parks it at the saved position (playing if the user asked for playback
/// while the refresh was in flight). Stream refreshes are de-duplicated.
/// `after_wake` enables the WirePlumber readiness wait; ordinary refreshes
/// (long pause, auto-retry) already have a live audio server.
pub async fn refresh_current_stream(
    player: &Arc<MpvPlayer>,
    queue: &Arc<QueueManager>,
    catalogue: &Arc<CatalogueManager>,
    playback_command_lock: &Arc<Mutex<()>>,
    after_wake: bool,
    playback_error: &Arc<RwLock<Option<PlaybackError>>>,
) -> Result<(), String> {
    struct RefreshGuard(Arc<MpvPlayer>);
    impl Drop for RefreshGuard {
        fn drop(&mut self) {
            self.0.end_stream_refresh();
        }
    }

    if !player.begin_stream_refresh() {
        // Another refresh is already running; it will pick up any play
        // request recorded while it was in flight.
        return Ok(());
    }
    let _refresh_guard = RefreshGuard(Arc::clone(player));
    let result =
        do_refresh_current_stream(player, queue, catalogue, playback_command_lock, after_wake)
            .await;
    match &result {
        // A successful refresh supersedes any error the user has seen.
        Ok(RefreshOutcome::Loaded) => *playback_error.write().await = None,
        // Superseded by the user or by a new sleep. That is not a failure, and
        // the action that superseded it owns the state now.
        Ok(RefreshOutcome::Cancelled) => {}
        Err(e) => {
            player.refresh_failed();
            // Wake and automatic retries both end here. Report the failure to
            // the UI instead of only logging it, or a dead audio server looks
            // like a silent no-op.
            if let Some(track) = queue.get_current_track().await {
                // The URL may have come from the recent-stream cache; drop it
                // so the next attempt fetches fresh instead of retrying a dead
                // one.
                catalogue.invalidate_stream(&track.id);
                record_playback_error(playback_error, &track, e).await;
            }
        }
    }
    result.map(|_| ())
}

async fn do_refresh_current_stream(
    player: &Arc<MpvPlayer>,
    queue: &Arc<QueueManager>,
    catalogue: &Arc<CatalogueManager>,
    playback_command_lock: &Arc<Mutex<()>>,
    after_wake: bool,
) -> Result<RefreshOutcome, String> {
    let pause_generation = player.pause_generation();
    let sleep_epoch = player.sleep_epoch();

    // The mpv child may have died with the old PipeWire graph. After wake,
    // start a fresh process instead of trying to revive its IPC socket.
    if after_wake {
        // A wake may span hours: no URL remembered from before the sleep may
        // be served after it, so the recent-stream cache is dropped wholesale.
        catalogue.invalidate_streams();
        if !wait_for_audio_ready().await {
            return Err(crate::AUDIO_SERVER_NOT_READY.to_string());
        }
    }

    let track = queue
        .get_current_track()
        .await
        .ok_or_else(|| "no current track to refresh".to_string())?;
    let track_id = track.id.clone();

    // Reach TIDAL *before* touching the player process. Replacing mpv first
    // burned a fresh child for every failed attempt and killed a child that
    // could still serve the loaded stream; when the network is the thing that
    // is missing, mpv is not the problem.
    let Some((url, format)) = fetch_stream_url(
        player,
        queue,
        catalogue,
        &track,
        pause_generation,
        sleep_epoch,
        after_wake,
    )
    .await?
    else {
        return Ok(RefreshOutcome::Cancelled);
    };
    // A pre-sleep teardown may have landed while the last attempt was running.
    if player.sleep_epoch() != sleep_epoch {
        return Ok(RefreshOutcome::Cancelled);
    }

    let _guard = playback_command_lock.lock().await;
    // The user may have changed tracks, paused, or triggered another suspend
    // while the fresh URL was fetched. Verify before touching the player.
    let current = queue.get_current_track().await;
    if current.as_ref().map(|t| t.id.as_str()) != Some(track_id.as_str())
        || player.sleep_epoch() != sleep_epoch
        || player.pause_generation() != pause_generation
    {
        return Ok(RefreshOutcome::Cancelled);
    }

    // The URL is in hand; now give it a player that matches the current audio
    // graph. Offload blocking spawn/IPC checks off the async runtime.
    if after_wake {
        info!("Starting a fresh mpv process after wake");
        let rebuild_player = Arc::clone(player);
        tokio::task::spawn_blocking(move || rebuild_player.rebuild_pipeline_for_refresh())
            .await
            .map_err(|e| format!("could not restart mpv: {e}"))?
            .map_err(|e| format!("could not restart mpv: {e}"))?;
    } else {
        ensure_audio_client_ready(player).await?;
        let check_player = Arc::clone(player);
        let available = tokio::task::spawn_blocking(move || {
            check_player.pipeline_available(Duration::from_secs(2))
        })
        .await
        .unwrap_or(false);
        if !available {
            warn!("mpv was still busy; restarting it");
            let rebuild_player = Arc::clone(player);
            tokio::task::spawn_blocking(move || rebuild_player.rebuild_pipeline_for_refresh())
                .await
                .map_err(|e| format!("could not restart mpv: {e}"))?
                .map_err(|e| format!("could not restart mpv: {e}"))?;
        }
    }

    // Re-read after the fetch: a seek issued while we waited is newer than
    // the position captured before the TIDAL round trip.
    let resume_position = player.get_position();

    // Preparing the stream performs a blocking mpv load (the child may be
    // starting, or the audio server may be down). Bound it so a stuck child
    // cannot hold the command lock forever: on timeout mpv is replaced and the
    // next play request fetches a fresh URL onto it.
    let timeout = if after_wake {
        STREAM_PREPARE_TIMEOUT
    } else {
        STREAM_LOAD_TIMEOUT
    };
    let prepare_track = track.clone();
    run_stream_op(player, timeout, move |player| {
        player.prepare_uri(&prepare_track, &url, format.clone(), resume_position)
    })
    .await
    .map_err(|e| format!("failed to prepare refreshed stream: {e}"))?;
    info!("Refreshed stream at {:.2}s", resume_position);
    // The load announces the started track, which arms the next-track preload.
    Ok(RefreshOutcome::Loaded)
}

/// Fetches the current track's stream URL, retrying while TIDAL is unreachable.
/// Returns `Ok(None)` when the attempt was superseded (another track, a pause,
/// or a new sleep) and there is nothing left to restore.
///
/// The wake path polls for `WAKE_FETCH_BUDGET` with a capped backoff: a machine
/// that resumes before its network is back otherwise gave up inside the outage
/// and stayed silent until the user pressed Play.
async fn fetch_stream_url(
    player: &Arc<MpvPlayer>,
    queue: &Arc<QueueManager>,
    catalogue: &Arc<CatalogueManager>,
    track: &TrackItem,
    pause_generation: u64,
    sleep_epoch: u64,
    after_wake: bool,
) -> Result<Option<(String, FormatInfo)>, String> {
    let started = tokio::time::Instant::now();
    let mut attempt = 0;

    let last_error = loop {
        attempt += 1;
        match catalogue.get_stream_url(&track.id).await {
            Ok(stream) => return Ok(Some(stream)),
            Err(e) => {
                // A logged-out session or a track TIDAL no longer serves cannot
                // heal by waiting; report it instead of polling for minutes.
                if !stream_fetch_error_is_retryable(&e) {
                    break e;
                }
                if !after_wake && attempt >= REFRESH_FETCH_ATTEMPTS {
                    break e;
                }
                let delay = if after_wake {
                    wake_fetch_delay(attempt)
                } else {
                    REFRESH_FETCH_DELAY
                };
                if after_wake && !wake_attempt_fits(attempt, started.elapsed(), WAKE_FETCH_BUDGET) {
                    break e;
                }
                warn!("Stream refresh attempt {attempt} failed: {e}");
                let still_wanted = wait_while_current(
                    player.as_ref(),
                    queue.as_ref(),
                    track,
                    pause_generation,
                    delay,
                )
                .await;
                // A pre-sleep teardown means the machine is going back down;
                // the next wake starts its own refresh.
                if !still_wanted || player.sleep_epoch() != sleep_epoch {
                    return Ok(None);
                }
            }
        }
    };
    Err(format!("failed to refresh stream URL: {last_error}"))
}

/// Waits until WirePlumber/PipeWire answers consistently. Returns false if the
/// audio server never came back within the timeout.
async fn wait_for_audio_ready() -> bool {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(25);
    let mut consecutive_ok = 0;
    loop {
        match wpctl_status().await {
            None => {
                // wpctl is unavailable; give the session a fixed grace period
                // and restore anyway rather than leaving playback stuck.
                tokio::time::sleep(Duration::from_secs(2)).await;
                return true;
            }
            Some(true) => consecutive_ok += 1,
            Some(false) => consecutive_ok = 0,
        }
        if consecutive_ok >= 2 {
            return true;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

/// Some(true) = reachable, Some(false) = not reachable, None = wpctl unavailable.
async fn wpctl_status() -> Option<bool> {
    let mut cmd = tokio::process::Command::new("wpctl");
    cmd.arg("status").kill_on_drop(true);
    match tokio::time::timeout(Duration::from_millis(1000), cmd.output()).await {
        Ok(Ok(output)) => Some(output.status.success()),
        Ok(Err(e)) if e.kind() == std::io::ErrorKind::NotFound => None,
        _ => Some(false),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wake_fetch_delays_stay_ordered_and_capped() {
        let delays: Vec<Duration> = (1..=12).map(wake_fetch_delay).collect();
        assert_eq!(delays[0], Duration::from_secs(4));
        for pair in delays.windows(2) {
            assert!(
                pair[0] <= pair[1],
                "backoff shrank: {:?} then {:?}",
                pair[0],
                pair[1]
            );
        }
        assert_eq!(*delays.last().unwrap(), Duration::from_secs(30));
        // A long outage must not poll faster than the cap.
        assert_eq!(wake_fetch_delay(1_000), Duration::from_secs(30));
    }

    #[test]
    fn a_wake_refresh_keeps_polling_until_the_budget_runs_out() {
        // Replays exactly what `fetch_stream_url` does with the schedule: keep
        // asking while another attempt still fits, then give up.
        let mut elapsed = Duration::ZERO;
        let mut attempts = 0;
        while wake_attempt_fits(attempts + 1, elapsed, WAKE_FETCH_BUDGET) {
            attempts += 1;
            elapsed += wake_fetch_delay(attempts);
        }
        // The old fixed window gave up after six attempts / 24 s, which is
        // exactly the outage length that left the player silent.
        assert!(
            attempts >= 15,
            "only {attempts} wake attempts fit in {WAKE_FETCH_BUDGET:?}"
        );
        assert!(
            elapsed >= Duration::from_secs(540),
            "the wake schedule gave up after only {elapsed:?}"
        );
        // ... and it still stops rather than polling forever.
        assert!(!wake_attempt_fits(attempts + 1, elapsed, WAKE_FETCH_BUDGET));
    }

    #[test]
    fn the_last_attempt_that_does_not_fit_is_refused() {
        let budget = Duration::from_secs(60);
        assert!(wake_attempt_fits(1, Duration::from_secs(56), budget));
        assert!(!wake_attempt_fits(1, Duration::from_secs(57), budget));
    }
}
