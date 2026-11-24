import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import "lib/Format.js" as Format

// Service.qml: Reactive client bridge between Quickshell UI and the TIDAL player daemon.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: ""
  readonly property string pluginId: "scorchedegg.tidalplayer"

  property bool alive: true
  Component.onDestruction: {
    root.alive = false
    positionTimer.stop()
    castPositionTimer.stop()
    castSpinTimer.stop()
    castTrackHoldTimer.stop()
    warmArtTimer.stop()
    warmArtistTimer.stop()
    playbackSyncTimer.stop()
    daemonStartTimeout.stop()
    daemonStartupTimer.stop()
  }

  readonly property string pluginDir: {
    if (manifest && manifest.__sourceDir) return String(manifest.__sourceDir)
    var cfg = String(Quickshell.env("XDG_CONFIG_HOME") || "")
    if (cfg === "") cfg = String(Quickshell.env("HOME") || "") + "/.config"
    return cfg + "/omarchy/plugins/scorchedegg.tidalplayer"
  }

  // The daemon's private RPC channel. Every catalogue call and every transport
  // command goes through this one socket; there is no HTTP API and no poll.
  DaemonLink {
    id: daemon

    onStatusEvent: function(data) {
      if (!root.alive) return
      // An event is newer than any status request already in flight.
      root.statusRequestGeneration++
      root.applyStatus(data, true, root.playbackRevision, false)
    }
    onQueueChanged: {
      if (root.alive) root.refreshQueue()
    }
    onResync: {
      if (!root.alive) return
      root.refreshStatus()
      root.refreshQueue()
    }
    onConnectedChanged: {
      if (!root.alive) return
      if (daemon.connected) {
        daemonStartTimeout.stop()
        root.daemonStarting = false
        root.daemonStartManual = false
        root.daemonStartError = ""
        // Honour a play pressed while the daemon was away before the refresh
        // snapshots can race the optimistic transport.
        if (root.resumeWhenConnected) {
          root.resumeWhenConnected = false
          root.play()
        }
        root.refreshStatus()
        root.refreshQueue()
        root.refreshCastDevices(false)
        root.loadRecentSearches()
      } else {
        root.statusLoaded = false
      }
    }
  }

  // ---- MPRIS Discovery & Binding --------------------------------------------
  readonly property var players: Mpris.players ? Mpris.players.values : []

  readonly property var player: {
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p) continue
      if (String(p.dbusName || "") === "org.mpris.MediaPlayer2.tidalplayer") return p
      if (String(p.identity || "") === "TIDAL Player") return p
    }
    return null
  }

  // ---- PipeWire Stream Discovery & Binding ----------------------------------
  readonly property var pwNodes: Pipewire.nodes ? Pipewire.nodes.values : []

  readonly property var tidalStreamNode: {
    for (var i = 0; i < pwNodes.length; i++) {
      var n = pwNodes[i]
      if (!n || !n.isStream) continue
      var name = String(n.name || "")
      var desc = String(n.description || "")
      if (name === "TIDAL Player" || desc === "TIDAL Player") {
        return n
      }
      if (n.ready && n.properties) {
        var appName = String(n.properties["application.name"] || "")
        var iconName = String(n.properties["application.icon-name"] || "")
        if (appName === "TIDAL Player" || iconName === "scorchedegg.tidalplayer") {
          return n
        }
      }
    }
    return null
  }

  PwObjectTracker {
    objects: root.tidalStreamNode ? [root.tidalStreamNode] : []
  }

  property var apiTrack: null
  property var optimisticTrack: null
  property string apiState: "Stopped"
  property string pendingTransport: ""
  property double pendingTransportUntil: 0
  property double playbackSyncBlockedUntil: 0
  property int playbackRevision: 0
  // Queue actions (next/previous/jump) advance queueIndex optimistically.
  // While any are in flight, a /queue snapshot is older than the local
  // selection and must not move it back.
  property int pendingQueueActions: 0
  property double lastPlaybackErrorId: 0

  readonly property bool daemonRunning: daemon.connected
  // connected -> reconnecting (grace period) -> down. A setup attempt that is
  // still running after the grace period is "starting", never "down": a first
  // install must not open on the offline page while its service is being
  // installed. Only a finished/failed start can surface the offline page.
  // `daemonStartManual` records a start the user asked for from that offline
  // page: the panel then keeps the page and disables its button instead of
  // swapping to the starting page.
  readonly property string daemonState: daemon.connected ? "connected"
    : (daemon.settledDown ? (root.daemonStarting ? "starting" : "down") : "reconnecting")
  property bool daemonStarting: false
  property bool daemonStartManual: false
  property string daemonStartError: ""
  // A play pressed while the daemon is away is honoured once the socket is
  // back, so the user does not have to press it again after a restart.
  property bool resumeWhenConnected: false
  readonly property bool connected: player !== null || (apiTrack !== null)
  readonly property var displayTrack: optimisticTrack || apiTrack
  readonly property bool playing: pendingTransport !== ""
    ? pendingTransport === "Playing"
    : (player ? player.isPlaying === true : (apiState === "Playing"))

  // Confirmed transport, preferring MPRIS and falling back to the REST state.
  function confirmedTransport() {
    return root.player ? (root.player.isPlaying === true) : (root.apiState === "Playing")
  }

  // Pin the expected transport after a local action and only hand control back
  // to the confirmed source once it agrees (or the grace period runs out).
  // This keeps the play/pause UI from flapping while MPRIS and the daemon
  // settle after the action.
  function beginTransport(state) {
    root.pendingTransport = state
    root.pendingTransportUntil = Date.now() + 2600
  }

  function resolvePendingTransport() {
    if (root.pendingTransport === "") return
    var now = Date.now()
    if (root.confirmedTransport() === (root.pendingTransport === "Playing")) {
      // Hold the pin through the sync-block window so short-lived MPRIS
      // contradictions right after the action cannot flash the icon.
      if (now >= root.playbackSyncBlockedUntil) root.pendingTransport = ""
    } else if (now >= root.pendingTransportUntil) {
      root.pendingTransport = ""
    }
  }
  readonly property string title: displayTrack ? (displayTrack.title || "") : ((player && player.trackTitle) ? player.trackTitle : "")
  readonly property string artist: displayTrack ? (displayTrack.artist || "") : ((player && player.trackArtist) ? player.trackArtist : "")
  readonly property string album: displayTrack ? (displayTrack.album || "") : ((player && player.trackAlbum) ? player.trackAlbum : "")
  readonly property string artUrl: displayTrack ? (displayTrack.art_url || "") : ((player && player.trackArtUrl) ? player.trackArtUrl : "")
  readonly property string videoUrl: displayTrack ? (displayTrack.video_url || "") : ""
  readonly property string artistId: displayTrack && displayTrack.artist_id ? String(displayTrack.artist_id) : ""
  readonly property var currentArtists: {
    if (displayTrack && displayTrack.artists && Array.isArray(displayTrack.artists) && displayTrack.artists.length > 0) {
      return displayTrack.artists
    }
    if (root.artistId || root.artist) {
      return [{ id: root.artistId || "", name: root.artist || "Artist" }]
    }
    return []
  }
  readonly property string albumId: displayTrack && displayTrack.album_id ? String(displayTrack.album_id) : ""
  property real apiDuration: 0
  readonly property real length: optimisticTrack
    ? Number(optimisticTrack.duration || 0)
    : ((player && player.lengthSupported && player.length > 0) ? player.length : (apiTrack && apiTrack.duration > 0 ? apiTrack.duration : apiDuration))

  // Continuous smooth playhead timeline tracking using wall-clock anchor
  property real position: 0
  property real anchorPos: 0
  property real anchorAt: 0
  property int activeScrubbers: 0
  readonly property bool isScrubbing: activeScrubbers > 0
  // Bumped by every seek the ui asks for, so the lyrics face can recentre on
  // the action itself instead of inferring it from the playhead.
  property int seekRevision: 0
  // Bumped when the daemon answers a seek (a stream reload included), which is
  // the first hard evidence that the deck is back at the new position. A seek
  // is optimistic locally — the playhead anchors to the target at once — so
  // this is what tells a view the audio is about to run again.
  property int seekSettledRevision: 0

  function anchorPosition(seconds) {
    root.anchorPos = Math.max(0, seconds)
    root.anchorAt = Date.now()
    root.position = root.anchorPos
  }

  function syncPosition() {
    if (!root.alive || root.isScrubbing) return
    if (player && player.positionSupported && !root.castActive) {
      root.anchorPosition(player.position)
    }
  }

  Connections {
    target: root.player
    function onPositionChanged() {
      if (!root.alive || !root.player || !root.player.positionSupported) return
      if (root.isScrubbing) return
      // While casting, MPRIS position is a local extrapolation of a sample
      // taken before the device stopped or started; the daemon's status
      // snapshot is the only authoritative cast playhead (see castPositionTimer).
      if (root.castActive) return
      var diff = Math.abs(root.player.position - root.position)
      if (Date.now() >= root.playbackSyncBlockedUntil && diff > 1.5) {
        root.anchorPosition(root.player.position)
      }
    }
    function onIsPlayingChanged() {
      if (!root.alive) return
      root.resolvePendingTransport()
      if (Date.now() >= root.playbackSyncBlockedUntil) {
        root.apiState = (root.player && root.player.isPlaying) ? "Playing" : "Paused"
        if (root.player && root.player.positionSupported && !root.castActive) {
          root.anchorPosition(root.player.position)
        } else {
          root.anchorPosition(root.position)
        }
        root.refreshStatus()
      }
    }
    function onPlaybackStateChanged() {
      if (!root.alive || root.isScrubbing) return
      root.resolvePendingTransport()
      if (Date.now() >= root.playbackSyncBlockedUntil) {
        root.apiState = (root.player && root.player.isPlaying) ? "Playing" : "Paused"
        if (root.player && root.player.positionSupported && !root.castActive) {
          root.anchorPosition(root.player.position)
        } else {
          root.anchorPosition(root.position)
        }
        root.refreshStatus()
      }
    }
    function onTrackTitleChanged() {
      if (!root.alive) return
      if (Date.now() >= root.playbackSyncBlockedUntil) {
        root.anchorPosition(0)
        root.refreshStatus()
        root.refreshQueue()
      }
    }
  }

  Timer {
    id: castSpinTimer
    interval: root.castSpinMinimumMs
    onTriggered: {
      if (!root.alive) return
      root.castLoading = false
    }
  }

  Timer {
    id: positionTimer
    interval: 100
    running: root.alive && root.playing && !root.isScrubbing && !root.castPlayheadHeld
    repeat: true
    onTriggered: {
      if (!root.alive) return
      var elapsed = (Date.now() - root.anchorAt) / 1000.0
      var next = root.anchorPos + elapsed
      root.position = root.length > 0 ? Math.min(next, root.length) : next
    }
  }

  // The cast playhead belongs to the device, and MPRIS only re-samples
  // Position on state changes, so a receiver that holds its clock (opening a
  // manifest, seeking, resuming) would leave the local extrapolation ahead.
  // Pull the daemon's own snapshot while the device plays: it carries the
  // position and the `cast.pending` hold, so the bar follows the audio.
  Timer {
    id: castPositionTimer
    interval: 1000
    running: root.alive && root.castActive && root.playing && !root.castPlayheadHeld && !root.isScrubbing
    repeat: true
    onTriggered: {
      if (!root.alive) return
      root.refreshStatus()
    }
  }

  // A track handed to the device is held until the daemon reports that the
  // receiver has it. The timer is the escape hatch for a hand-off that never
  // lands (a rejected LOAD): the status then says Stopped and Play reloads.
  Timer {
    id: castTrackHoldTimer
    interval: 15000
    repeat: false
    onTriggered: {
      if (!root.alive) return
      root.castTrackPending = false
    }
  }

  // ---- Extended State from REST API -----------------------------------------
  property string formatBadge: ""
  property bool isHiRes: false
  property string repeatMode: "off"
  property double repeatSyncBlockedUntil: 0
  property bool shuffleEnabled: false
  property double shuffleSyncBlockedUntil: 0
  property real volume: 1.0
  // Local mpv carries headroom to 150 %; a cast receiver's SET_VOLUME stops at
  // 100 %, so every control and the toast draw against the active output.
  readonly property real maxVolume: root.castActive ? 1.0 : 1.5
  // The level to return to when the footer's speaker button unmutes. Kept on
  // the transport, not in the view, so every volume surface shares it.
  property real lastAudibleVolume: 1.0
  readonly property bool muted: root.volume <= 0.001

  // Keep the unmute level in step with every writer of the level: the footer
  // bar, the bar widget's wheel, the keyboard, MPRIS, a cast snapshot or a
  // PipeWire node change.
  onVolumeChanged: {
    if (root.volume > 0.001) root.lastAudibleVolume = root.volume
  }

  // A footer-bar drag is a preview: the level follows the pointer with no RPC
  // per pixel, and the node's own (still catching up) readings are ignored so
  // they cannot pull the knob back while the pointer is held. The drag
  // commits one level to the daemon on release.
  property bool volumeScrubbing: false
  property double volumeSyncBlockedUntil: 0

  Connections {
    target: (root.tidalStreamNode && root.tidalStreamNode.audio) ? root.tidalStreamNode.audio : null
    function onVolumeChanged() {
      if (!root.tidalStreamNode || !root.tidalStreamNode.audio) return
      // Our own preview write (and the tail of one) is newer than anything the
      // node reports, so it cannot pull the slider back under the pointer.
      if (root.volumeScrubbing || Date.now() < root.volumeSyncBlockedUntil) return
      // While casting the device owns the level; the local node is the stopped
      // mpv stream and its level says nothing about what is audible.
      if (root.castActive) return
      var v = root.tidalStreamNode.audio.volume
      if (Math.abs(root.volume - v) > 0.005) {
        root.volume = v
      }
    }
  }

  onTidalStreamNodeChanged: {
    if (root.castActive || root.volumeScrubbing) return
    if (root.tidalStreamNode && root.tidalStreamNode.audio && root.tidalStreamNode.audio.volume > 0) {
      root.volume = root.tidalStreamNode.audio.volume
    }
  }

  property bool loggedIn: false
  // True once any status snapshot has been applied; the login face waits for
  // this so a fresh panel cannot mistake the default loggedIn=false for a
  // real logged-out session.
  property bool statusLoaded: false
  property string accountEmail: ""
  property string accountAvatarUrl: ""
  property string accountUserId: ""
  property bool accountProfileLoading: false
  property int accountProfileGeneration: 0
  property double accountProfileRetryAt: 0
  // PKCE login state mirrored from daemon status events so copying the
  // redirect URL in the browser can pop the panel open immediately.
  property bool authPending: false
  property bool authExchanging: false
  property string authError: ""
  property var currentTrackId: null
  property string playingContext: "Top Tracks"
  property var recentSearches: []
  property var queueTracks: []
  property int queueIndex: 0
  // Casting. The daemon owns the session; these mirror the compact state from
  // its status snapshots plus the last discovered device list.
  property var castDevices: []
  property bool castActive: false
  property string castDeviceId: ""
  property string castDeviceName: ""
  // What the active device can output (`tv`, `speaker`, `speaker_group`,
  // `unknown`; empty when nothing is casting). The header's Cast button wears
  // this class instead of one generic glyph, so a TV and a Nest Mini are
  // distinguishable at a glance.
  property string castDeviceKind: ""
  property bool castLoading: false
  property bool castBusy: false
  // The device a connect is in flight for. Separate from `castActive`: clicking
  // a device is not yet casting, and the sheet needs to say so.
  property string castConnectingId: ""
  // The device whose last connect attempt failed. The sheet paints a red
  // "Failed" badge on that row until the next attempt or the sheet closes;
  // failures are shown in the panel, never as a system notification.
  property string castFailedId: ""
  // The device cast to last, remembered by the daemon. The sheet floats it to
  // the top while nothing is casting.
  property string castLastUsedId: ""
  // The receiver accepted the URL but never connected: an inbound firewall
  // rule is missing. The sheet offers the one-time command to fix it.
  property bool castStreamBlocked: false
  // The device's playhead is frozen while the receiver opens a manifest,
  // seeks or resumes; `castPending` is the daemon reporting that hold. A track
  // handed to the device is also held locally from the moment the queue moves,
  // because the daemon cannot report its own hold until the hand-off starts.
  // The bar must not run ahead of audio the device has not begun.
  property bool castPending: false
  property bool castTrackPending: false
  readonly property bool castPlayheadHeld: root.castActive && (root.castPending || root.castTrackPending)
  // The hold ended: restart the wall clock from what is on screen, then pull
  // the device's own position (the first sample that proved it was running).
  onCastPlayheadHeldChanged: {
    if (!root.alive || root.castPlayheadHeld) return
    if (root.playing) root.anchorPosition(root.position)
    root.refreshStatus()
  }
  property int castRequestGeneration: 0
  // A cached scan answers in a few tens of milliseconds, so the spinner could
  // come and go before the eye registers it and the click reads as dead. Any
  // request that drives the spinner is held for at least this long.
  readonly property int castSpinMinimumMs: 1000
  property double castSpinStartedAt: 0
  // The current track plus the next four, wrapping. Drives both the cover
  // warmers and the artist-art prefetch below.
  readonly property var upcomingTracks: {
    var tracks = root.queueTracks
    if (!tracks || tracks.length === 0) return []
    var list = []
    var depth = Math.min(4, tracks.length - 1)
    for (var i = 0; i <= depth; i++) {
      var t = tracks[(root.queueIndex + i) % tracks.length]
      if (t && list.indexOf(t) === -1) list.push(t)
    }
    return list
  }

  onUpcomingTracksChanged: root.prefetchArtistArt()

  // Warm Qt's image cache for the next few covers so a skip renders the new
  // artwork immediately instead of starting its download in view.
  readonly property var preloadArtUrls: {
    var upcoming = root.upcomingTracks
    var urls = []
    for (var i = 1; i < upcoming.length; i++) {
      var url = String(upcoming[i].art_url || "")
      if (url && urls.indexOf(url) === -1) urls.push(url)
    }
    return urls
  }

  // The lists the hidden warmers actually bind to. They trail the queue for a
  // moment: when a skip shifts the upcoming covers, the old list still holds
  // the track that just became current. Rebuilding the warmers immediately
  // would release that pixmap before the visible image asks for it, and Qt's
  // unreferenced cache is only 2 MiB, so it would be evicted and re-decoded.
  property var warmArtUrls: []
  property var warmArtistArtUrls: []
  onPreloadArtUrlsChanged: warmArtTimer.restart()
  onPreloadArtistArtUrlsChanged: warmArtistTimer.restart()

  Timer {
    id: warmArtTimer
    interval: 200
    onTriggered: {
      if (!root.alive) return
      root.warmArtUrls = root.preloadArtUrls
    }
  }

  Timer {
    id: warmArtistTimer
    interval: 200
    onTriggered: {
      if (!root.alive) return
      root.warmArtistArtUrls = root.preloadArtistArtUrls
    }
  }

  // Resolved from the cache rather than set imperatively, so an avatar
  // fetched for an album page also lights up the now-playing header.
  readonly property string currentArtistArtUrl: {
    var list = root.currentArtists
    var primaryId = list && list.length > 0 ? String(list[0].id || root.artistId || "") : ""
    if (!primaryId || root.artistArtCache[primaryId] === undefined) return ""
    return root.artistArtCache[primaryId] || ""
  }
  property string artistArtRequestId: ""
  property var artistArtCache: ({})
  property bool queueLoaded: false
  property int queueRequestGeneration: 0
  property var recentItems: []
  property int recentRequestGeneration: 0
  property int statusRequestGeneration: 0

  property var inFlightArtistArt: ({})

  onCurrentArtistsChanged: root.fetchCurrentArtistArt()
  onArtistIdChanged: root.fetchCurrentArtistArt()

  // Fetch one artist avatar into artistArtCache. Callers bind through the
  // cache (`svc.artistArtCache[id]`), so any number of views can share the
  // image and re-evaluate when it lands.
  function requestArtistArt(id) {
    var key = String(id || "")
    if (!key || root.artistArtCache[key] !== undefined || root.inFlightArtistArt[key]) return
    root.inFlightArtistArt[key] = true
    rpc("artist.image", { id: key }, function(err, data) {
      delete root.inFlightArtistArt[key]
      // A lookup failure is not "no artwork": leave the key unset so the
      // next prefetch/status pass retries instead of caching an empty avatar.
      if (err || !data || data.error) return
      var next = Object.assign({}, root.artistArtCache)
      next[key] = data.art_url || ""
      root.artistArtCache = next
    })
  }

  function fetchCurrentArtistArt() {
    var list = root.currentArtists
    if (!list || list.length === 0) return
    for (var i = 0; i < list.length; i++) {
      var aId = String(list[i].id || "")
      if (aId) root.requestArtistArt(aId)
    }
  }

  function trackArtistIds(track) {
    if (!track) return []
    var list = (track.artists && track.artists.length > 0) ? track.artists : null
    if (!list && track.artist_id) list = [{ id: track.artist_id }]
    if (!list) return []
    var ids = []
    for (var i = 0; i < list.length && i < 4; i++) {
      var id = String(list[i].id || "")
      if (id) ids.push(id)
    }
    return ids
  }

  // Resolve the artwork URL for the current and upcoming tracks ahead of time
  // so the now-playing header has the new avatars before a skip lands on them.
  // requestArtistArt de-duplicates in-flight lookups and caches the answer.
  function prefetchArtistArt() {
    var upcoming = root.upcomingTracks
    for (var i = 0; i < upcoming.length; i++) {
      var ids = root.trackArtistIds(upcoming[i])
      for (var j = 0; j < ids.length; j++) root.requestArtistArt(ids[j])
    }
  }

  // Decoded avatar URLs for those tracks, at the 72 px size the now-playing
  // header draws. Re-evaluates as each lookup lands.
  readonly property var preloadArtistArtUrls: {
    var upcoming = root.upcomingTracks
    var urls = []
    for (var i = 0; i < upcoming.length; i++) {
      var ids = root.trackArtistIds(upcoming[i])
      for (var j = 0; j < ids.length; j++) {
        var url = String(root.artistArtCache[ids[j]] || "")
        if (url && urls.indexOf(url) === -1) urls.push(url)
      }
    }
    return urls
  }

  function refreshStatus() {
    if (!root.alive) return
    var requestGeneration = ++root.statusRequestGeneration
    var requestRevision = root.playbackRevision
    var requestStartedDuringBlock = Date.now() < root.playbackSyncBlockedUntil
    rpc("status", {}, function(err, data) {
      if (!root || !root.alive || requestGeneration !== root.statusRequestGeneration) return
      if (err || !data) return
      root.applyStatus(data, false, requestRevision, requestStartedDuringBlock)
    }, 10000)
  }

  function queueIndexForTlid(tlid) {
    if (tlid === null || tlid === undefined) return -1
    for (var i = 0; i < root.queueTracks.length; i++) {
      if (root.queueTracks[i] && String(root.queueTracks[i].tlid) === String(tlid)) return i
    }
    return -1
  }

  // A status snapshot that arrives as a pushed event crosses the DaemonLink
  // `var` signal, which converts its nested arrays to QVariantList containers:
  // `Array.isArray` rejects those, and storing the wrapper in a `var` property
  // keeps them that way. Every consumer of the current track (header circles,
  // credits lines, queue summary) tests `artists` for a real JS array, so an
  // event-only snapshot used to strip every artist but the first. Rebuild the
  // track as a plain JS object at this single boundary; RPC replies already
  // arrive as plain objects and pass through untouched.
  function plainTrack(track) {
    if (!track || Array.isArray(track.artists)) return track
    var out = {}
    for (var key in track) out[key] = track[key]
    out.artists = root.plainList(track.artists || [])
    return out
  }

  function plainList(value) {
    if (!value || Array.isArray(value)) return value
    var out = []
    for (var i = 0; i < value.length; i++) out.push(value[i])
    return out
  }

  // One status snapshot, whether it was pushed as an event or fetched by an
  // explicit refresh. Pushed events carry no position: MPRIS owns the playhead.
  function applyStatus(data, fromEvent, requestRevision, requestStartedDuringBlock) {
    if (!root.alive || !data) return
    var statusTrackId = data.track ? String(data.track.id || "") : ""
    var shownTrackId = root.currentTrackId ? String(root.currentTrackId) : ""
    var trackMatches = statusTrackId !== "" && (shownTrackId === "" || statusTrackId === shownTrackId)
    var syncPlayback = fromEvent
      ? Date.now() >= root.playbackSyncBlockedUntil
      : (requestRevision === root.playbackRevision
        && !requestStartedDuringBlock
        && Date.now() >= root.playbackSyncBlockedUntil)

    // The daemon only sends a format that belongs to `data.track`, so this can
    // leave the previous badge in place during a cold fetch and land as soon
    // as playback-info returns — even before the stream starts playing.
    if (data.format && data.format.badge
        && (trackMatches || (syncPlayback && root.optimisticTrack === null))) {
      root.formatBadge = data.format.badge
      root.isHiRes = data.format.badge.indexOf("24-bit") !== -1
    }
    if (data.playback_error && data.playback_error.id !== undefined
        && Number(data.playback_error.id) !== root.lastPlaybackErrorId) {
      if (root.notify(data.playback_error.message || "Playback failed")) {
        root.lastPlaybackErrorId = Number(data.playback_error.id)
      }
    }
    var now = Date.now()
    // A next/previous may clear repeat-song locally, and a repeat/shuffle click
    // sets the new mode optimistically; a snapshot in flight must not flip the
    // indicator back before the RPC settles.
    var shuffleBlocked = now < root.shuffleSyncBlockedUntil
    var shuffleChanged = data.shuffle !== undefined && !shuffleBlocked && data.shuffle !== root.shuffleEnabled
    var queueNeedsRefresh = !root.queueLoaded || shuffleChanged
    // The snapshot carries its own cast state. Read it here as well: the cast
    // block below runs after this one, and on the first status after a reload
    // `root.castActive` is still false, which used to let the local node's
    // level shadow the device's for as long as no further status arrived.
    var castInSnapshot = !!(data.cast && data.cast.active)
    if (syncPlayback && data.duration !== undefined && data.duration > 0) {
      root.apiDuration = data.duration
    }
    if (data.repeat && root.pendingQueueActions === 0
        && requestRevision === root.playbackRevision) {
      if (data.repeat === root.repeatMode || now >= root.repeatSyncBlockedUntil) {
        root.repeatMode = data.repeat
        root.repeatSyncBlockedUntil = 0
      }
    }
    if (data.shuffle !== undefined) {
      if (data.shuffle === root.shuffleEnabled || !shuffleBlocked) {
        root.shuffleEnabled = data.shuffle
        root.shuffleSyncBlockedUntil = 0
      }
    }
    if (data.volume !== undefined) {
      // While casting the device is the output and its own level is the
      // truth, so the snapshot always wins there. Locally the PipeWire
      // node is the authority and reports changes through its own signal.
      // A drag preview outranks both until it commits.
      if (!root.volumeScrubbing && Date.now() >= root.volumeSyncBlockedUntil
          && (castInSnapshot || root.castActive || !root.tidalStreamNode || !root.tidalStreamNode.audio)) {
        // Use the snapshot's own cast flag for the ceiling too: on the status
        // that ends a session `root.castActive` is still true, and clamping
        // the restored local level to 100 % would lose its 150 % headroom.
        root.volume = Math.min(castInSnapshot ? 1.0 : 1.5, data.volume)
      }
    }
    // The favourite belongs to the track, not to the transport: apply it as
    // soon as a snapshot describes the track that is on screen, even while
    // the post-skip window still suppresses play/pause state.
    var favoriteSettled = syncPlayback || trackMatches
    if (data.favorite !== undefined && !root.favoritePending && favoriteSettled) {
      root.favorite = data.favorite
    }
    var wasLoggedIn = root.loggedIn
    var wasAuthPending = root.authPending
    var wasAuthExchanging = root.authExchanging
    var prevAuthError = root.authError
    if (data.logged_in !== undefined) root.loggedIn = !!data.logged_in
    if (data.user && data.user.logged_in !== undefined) root.loggedIn = !!data.user.logged_in
    var flow = data.auth_flow || null
    root.authPending = !root.loggedIn && !!(flow && flow.pending)
    root.authExchanging = !root.loggedIn && !!(flow && flow.exchanging)
    root.authError = (!root.loggedIn && flow && flow.error) ? String(flow.error) : ""
    root.statusLoaded = true
    if (fromEvent) {
      var caughtRedirect = !wasAuthExchanging && root.authExchanging
      var completedFromWatch = wasAuthPending && !wasLoggedIn && root.loggedIn
      var newAuthFailure = root.authError !== "" && root.authError !== prevAuthError
      if (caughtRedirect || completedFromWatch || newAuthFailure) {
        root.openMini()
      }
    }
    if (root.loggedIn) {
      if (root.accountEmail === "") root.refreshAccountProfile()
    } else if (root.accountEmail !== "" || root.accountProfileLoading) {
      root.resetAccountProfile()
    }
    // Cast state is independent of the local transport; a pending
    // connect/disconnect must not be overwritten by an older snapshot.
    if (data.cast && !root.castBusy) {
      root.castActive = !!data.cast.active
      root.castDeviceId = data.cast.device_id || ""
      root.castDeviceName = data.cast.device_name || ""
      root.castDeviceKind = root.castActive ? String(data.cast.kind || "") : ""
      root.castStreamBlocked = !!data.cast.stream_blocked
      // The daemon freezes the playhead until the receiver's own clock proves
      // the stream is running; the bar holds with it.
      root.castPending = root.castActive && !!data.cast.pending
      if (!root.castActive) {
        root.castTrackPending = false
      } else if (root.castTrackPending
                 && String(data.cast.track_id || "") === String(root.currentTrackId || "")) {
        // The receiver has the new track. From here `castPending` alone
        // decides when the playhead may run.
        root.castTrackPending = false
      }
    }
    if (syncPlayback) {
      var incomingTrackId = data.track ? String(data.track.id || "") : ""
      root.optimisticTrack = null
      if (data.state) root.apiState = data.state
      if (data.track) {
        root.apiTrack = root.plainTrack(data.track)
        if (data.track.id) root.currentTrackId = String(data.track.id)
      } else {
        root.apiTrack = null
        root.currentTrackId = null
        root.formatBadge = ""
        root.isHiRes = false
        root.apiDuration = 0
      }
      // Selection moves are carried by `current_tlid`; the track list only
      // changes on a `queue_changed` event.
      if (data.current_tlid !== undefined && root.pendingQueueActions === 0) {
        var index = root.queueIndexForTlid(data.current_tlid)
        if (index >= 0) root.queueIndex = index
      }
      if (root.artistId) root.fetchCurrentArtistArt()
    }
    if (queueNeedsRefresh) root.refreshQueue()
    // The cast playhead is the device's own clock, not part of the optimistic
    // window: once the receiver has the track on screen, a snapshot's position
    // is newer than the local guess and may sync even inside the block.
    var castPositionFresh = root.castActive && !root.castPlayheadHeld
      && data.cast && data.track
      && String(data.cast.track_id || "") !== ""
      && String(data.cast.track_id) === String(data.track.id)
      && String(data.track.id) === String(root.currentTrackId || "")
    if ((syncPlayback || castPositionFresh) && data.position !== undefined && !root.isScrubbing) {
      if (!root.playing) {
        root.position = data.position
      } else if (!root.castPlayheadHeld) {
        // A cast playhead is the device's own clock, so follow it closely: a
        // LOAD, SEEK or resume can stop or jump it, and MPRIS is still
        // extrapolating from an older sample. mpv's clock is smooth and keeps
        // the loose threshold so its jitter does not move the bar.
        var positionTolerance = root.castActive ? 0.35 : 2.0
        if (Math.abs(data.position - root.position) > positionTolerance) {
          root.anchorPosition(data.position)
        }
      }
    }
    if (root.recentSearches.length === 0) {
      root.loadRecentSearches()
    }
    root.resolvePendingTransport()
  }

  // Hidden cache warmers for upcoming artwork. `cache: true` keeps the decoded
  // 512 px cover in Qt's image cache, which is the size the now-playing art
  // requests.
  Repeater {
    model: root.warmArtUrls
    Image {
      source: modelData
      asynchronous: true
      cache: true
      visible: false
      // The cache key includes this provider option; RoundedImage draws with
      // PreserveAspectCrop, so the warmers must use it too or they share
      // nothing with the visible images.
      fillMode: Image.PreserveAspectCrop
      sourceSize.width: 512
      sourceSize.height: 512
    }
  }

  // The blurred backdrop decodes at a different size, so warm that separately.
  Repeater {
    model: root.warmArtUrls
    Image {
      source: modelData
      asynchronous: true
      cache: true
      visible: false
      // The cache key includes this provider option; RoundedImage draws with
      // PreserveAspectCrop, so the warmers must use it too or they share
      // nothing with the visible images.
      fillMode: Image.PreserveAspectCrop
      sourceSize.width: 760
      sourceSize.height: 980
    }
  }

  // The now-playing header draws 72 px avatars, which is a separate decode
  // from any other artist image the views use.
  Repeater {
    model: root.warmArtistArtUrls
    Image {
      source: modelData
      asynchronous: true
      cache: true
      visible: false
      // The cache key includes this provider option; RoundedImage draws with
      // PreserveAspectCrop, so the warmers must use it too or they share
      // nothing with the visible images.
      fillMode: Image.PreserveAspectCrop
      sourceSize.width: 72
      sourceSize.height: 72
    }
  }

  // The collapsed sub-page player draws a 40 px thumbnail from an 80 px
  // decode, and the bar warms its own sleeve size separately.
  Repeater {
    model: root.warmArtUrls
    Image {
      source: modelData
      asynchronous: true
      cache: true
      visible: false
      // The cache key includes this provider option; RoundedImage draws with
      // PreserveAspectCrop, so the warmers must use it too or they share
      // nothing with the visible images.
      fillMode: Image.PreserveAspectCrop
      sourceSize.width: 80
      sourceSize.height: 80
    }
  }

  // ---- Daemon Watchdog / Auto-start -----------------------------------------
  Process {
    id: daemonProc
    command: [root.pluginDir ? (root.pluginDir + "/bin/omarchy-tidalplayer") : "omarchy-tidalplayer", "daemon", "start"]
    onExited: function(exitCode) {
      if (!root.alive) return
      if (exitCode !== 0) {
        daemonStartTimeout.stop()
        root.daemonStarting = false
        root.daemonStartManual = false
        root.resumeWhenConnected = false
        if (!daemon.connected) {
          root.daemonStartError = "The daemon did not start. Check the service logs."
        }
      }
    }
  }

  // `daemon start` starts the existing unit, or installs it (without enabling
  // it at boot) if this is the first run. The plugin owns the daemon's
  // lifetime, so it is not enabled into the user's boot target. One start at
  // a time (`daemonStarting`): the CTA is disabled while this is in flight, and
  // a second caller such as a play press cannot take over the pending start and
  // swap the offline page away under the user.
  // `manual` is the offline page's button: that page stays up with its own
  // progress text instead of being replaced by the starting page.
  function startDaemon(manual) {
    if (!root.alive || daemon.connected || root.daemonStarting || daemonProc.running) return
    root.daemonStarting = true
    root.daemonStartManual = manual === true
    root.daemonStartError = ""
    daemon.retryNow()
    daemonProc.running = true
    daemonStartTimeout.restart()
  }

  Timer {
    id: daemonStartTimeout
    interval: 12000
    repeat: false
    onTriggered: {
      if (!root.alive || daemon.connected) return
      if (daemonProc.running) daemonProc.running = false
      root.daemonStarting = false
      root.daemonStartManual = false
      root.resumeWhenConnected = false
      root.daemonStartError = "The daemon did not answer. Check the service logs."
    }
  }

  // The socket connects immediately; only start the service if it did not
  // answer shortly after the plugin loaded.
  Timer {
    id: daemonStartupTimer
    interval: 900
    repeat: false
    onTriggered: {
      if (root.alive && !root.daemonRunning) root.startDaemon()
    }
  }

  Component.onCompleted: {
    Qt.callLater(function() {
      if (!root || !root.alive) return
      daemonStartupTimer.restart()
      // Cached list only; the sweep runs when the panel opens.
      if (daemon.connected) root.refreshCastDevices(false)
    })
  }

  // ---- Share Links -----------------------------------------------------------
  Process {
    id: wlCopyProc
  }

  // notify-send can only hand the notification daemon a local path, and QML
  // cannot export a cover it has already decoded, so the cover each share
  // button would send is kept as a file and refetched in the background when
  // that button's artwork changes. There are two buttons: the now-playing
  // footer shares the playing track, a page header shares the album, playlist
  // or artist on screen. Each owns one file, overwritten in place, so at most
  // two small files exist and nothing accumulates.
  Process {
    id: notifyProc

    stdout: StdioCollector {
      id: notifyOutput
      waitForEnd: true
      onStreamFinished: {
        if (!root || !root.alive) return
        root.shareNotificationId = notifyOutput.text.trim()
      }
    }
  }

  // Dedicated process for error/status toasts so they never overwrite
  // `shareNotificationId` or contend with share cover replacements.
  Process {
    id: errorNotifyProc
  }

  readonly property string shareBadgeIcon: root.pluginDir + "/assets/tidal-logo-badge.svg"

  function shareArtPath(slot) {
    var dir = String(Quickshell.env("XDG_RUNTIME_DIR") || "")
    if (dir === "") return ""
    return dir + "/scorchedegg.tidalplayer/share-" + slot + ".jpg"
  }

  // One fetch per slot, so warming the playing track never cancels the page it
  // is shown on. `ready` is the cover the slot's file holds;
  // `card`/`cardBody`/`cardUrl` hold the share waiting on a cover and which
  // one it needs — a share can arrive while a different track's cover is still
  // downloading, so it waits out that fetch and goes next, ahead of any warm;
  // `queued` is the newest warm asked for meanwhile.
  Process {
    id: shareArtTrackProc
    property string slot: "track"
    property string url: ""
    property string ready: ""
    property string card: ""
    property string cardBody: ""
    property string cardUrl: ""
    property string queued: ""
    onExited: function(exitCode) {
      if (!root || !root.alive) return
      root.shareArtDone(shareArtTrackProc, exitCode)
    }
  }

  Process {
    id: shareArtViewProc
    property string slot: "view"
    property string url: ""
    property string ready: ""
    property string card: ""
    property string cardBody: ""
    property string cardUrl: ""
    property string queued: ""
    onExited: function(exitCode) {
      if (!root || !root.alive) return
      root.shareArtDone(shareArtViewProc, exitCode)
    }
  }

  function shareArtProc(kind) {
    return kind === "track" ? shareArtTrackProc : shareArtViewProc
  }

  // The cover lands through a rename so a notification never reads a
  // half-written file.
  function fetchShareArt(proc, art, card, cardBody) {
    var path = root.shareArtPath(proc.slot)
    if (path === "") return
    var script = "f=$1; mkdir -p \"${f%/*}\" && curl -fsSL --connect-timeout 3 --max-time 6 \"$2\" -o \"$f.part\" && mv -f \"$f.part\" \"$f\""
    proc.url = art
    proc.card = card
    proc.cardBody = card === "" ? "" : (cardBody || "")
    proc.cardUrl = card === "" ? "" : art
    proc.command = ["sh", "-c", script, "sh", path, art]
    proc.running = true
  }

  function shareArtDone(proc, exitCode) {
    if (!root.alive) return
    var url = proc.url
    var card = proc.card
    var cardBody = proc.cardBody
    var cardUrl = proc.cardUrl
    var queued = proc.queued
    proc.url = ""
    proc.card = ""
    proc.cardBody = ""
    proc.cardUrl = ""
    if (exitCode === 0) proc.ready = url

    // The share waited on a cover this run did not carry: fetch the one it
    // needs next, ahead of any warm, and swap it into the card when it lands.
    if (card !== "" && cardUrl !== url) {
      // A share outranks the warm queued behind it: that warm is for an item
      // the user has already moved past.
      proc.queued = ""
      root.fetchShareArt(proc, cardUrl, card, cardBody)
      return
    }
    // No id yet (the first toast was still starting): post the cover as its own
    // card rather than dropping it, so a slow notify-send still ends up showing
    // the artwork.
    var path = root.shareArtPath(proc.slot)
    if (card !== "" && exitCode === 0 && path !== "")
      root.sendShareNotification(card, path, root.shareNotificationId, cardBody)

    proc.queued = ""
    if (queued !== "" && queued !== url && queued !== proc.ready) root.fetchShareArt(proc, queued, "", "")
  }

  // Keep a share button's file in step with the artwork it would send.
  function warmShareArt(kind, url) {
    if (root.shareArtPath(kind) === "") return
    var art = String(url || "")
    if (art.indexOf("https://") !== 0 && art.indexOf("http://") !== 0) return
    var proc = root.shareArtProc(kind)
    if (art === proc.ready) return
    if (proc.running) {
      if (art !== proc.url) proc.queued = art
      return
    }
    root.fetchShareArt(proc, art, "", "")
  }

  // The now-playing footer and `S` on that face share the playing track.
  onArtUrlChanged: root.warmShareArt("track", root.artUrl)

  // Notification id of the card the current share is showing, so the cover can
  // replace it. Empty until notify-send reports it.
  property string shareNotificationId: ""

  function sendShareNotification(displayName, iconPath, replaceId, bodyText) {
    var command = [
      "notify-send", "-p", "-a", "TIDAL Player", "-i", "file://" + iconPath,
      "--", "Copied " + displayName,
      bodyText || "TIDAL track links can be opened in other apps"
    ]
    // `-p` prints the id so the cover can replace this card; a replacement
    // passes that id back with `-r` instead of opening a second toast.
    if (replaceId) command.splice(2, 0, "-r", String(replaceId))
    notifyProc.command = command
    notifyProc.running = true
  }

  function copyAndNotify(url, displayName, artUrl, kind, bodyText) {
    if (typeof Quickshell !== "undefined" && Quickshell.clipboardText !== undefined) {
      Quickshell.clipboardText = url
    } else {
      wlCopyProc.command = ["wl-copy", url]
      wlCopyProc.running = true
    }

    // A new share gets its own card: clearing the id first means the cover for
    // this one cannot replace the previous share's toast.
    root.shareNotificationId = ""

    var art = String(artUrl || "")
    var proc = root.shareArtProc(kind)
    var artPath = root.shareArtPath(kind)
    var remote = artPath !== "" && (art.indexOf("https://") === 0 || art.indexOf("http://") === 0)

    // A share is the newest thing the user did: a warm queued behind the
    // current fetch is for an item they have moved past.
    proc.queued = ""

    // Warmed cover, with nothing downloading that could overwrite the file
    // between this check and the daemon reading it: the card carries the cover
    // from the start, so there is no badge and no swap to watch.
    if (remote && art === proc.ready && !proc.running) {
      root.sendShareNotification(displayName, artPath, "", bodyText)
      return
    }

    root.sendShareNotification(displayName, root.shareBadgeIcon, "", bodyText)
    if (!remote) return

    if (proc.running) {
      // Something is downloading already, and it may be another track's cover
      // after a skip. Let this card wait for that fetch, then fetch the cover it
      // needs ahead of any warm and swap it in, so a share never ends on the
      // badge just because a warm got there first.
      proc.card = displayName
      proc.cardBody = bodyText
      proc.cardUrl = art
      return
    }
    root.fetchShareArt(proc, art, displayName, bodyText)
  }

  function shareTrack(trackId) {
    var tid = trackId || root.currentTrackId
    if (!tid) return
    var url = "https://tidal.com/track/" + tid + "/u"
    var name = root.title ? ("\u201C" + root.title + "\u201D") : "track link"
    copyAndNotify(url, name, root.artUrl, "track", "TIDAL track links can be opened in other apps")
  }

  function shareAlbum(albumId, albumTitle, artUrl) {
    var aid = albumId || root.albumId
    if (!aid) return
    var url = "https://tidal.com/album/" + aid + "/u"
    var sameAlbum = String(aid) === String(root.albumId)
    var title = albumTitle || (sameAlbum ? root.album : "")
    var name = title ? ("\u201C" + title + "\u201D") : "album link"
    var art = artUrl || (sameAlbum ? root.artUrl : "")
    copyAndNotify(url, name, art, "view", "TIDAL album links can be opened in other apps")
  }

  function shareArtist(artistId, artistName, artUrl) {
    if (!artistId) return
    var url = "https://tidal.com/artist/" + artistId + "/u"
    var name = artistName ? ("\u201C" + artistName + "\u201D") : "artist link"
    copyAndNotify(url, name, artUrl || "", "view", "TIDAL artist links can be opened in other apps")
  }

  function sharePlaylist(playlistId, playlistTitle, artUrl) {
    if (!playlistId) return
    var url = "https://tidal.com/playlist/" + playlistId
    var name = playlistTitle ? ("\u201C" + playlistTitle + "\u201D") : "playlist link"
    copyAndNotify(url, name, artUrl || "", "view", "Playlist links can only be opened in TIDAL")
  }

  function blockPlaybackSync(durationMs) {
    var wait = durationMs || 1900
    root.playbackRevision++
    root.playbackSyncBlockedUntil = Date.now() + wait
    playbackSyncTimer.interval = wait
    playbackSyncTimer.restart()
  }

  function setOptimisticTrack(track) {
    if (!track) return
    root.optimisticTrack = track
    root.apiTrack = track
    root.currentTrackId = String(track.id || "")
    root.apiDuration = Number(track.duration || 0)
    root.anchorPosition(0)
    // A cast track change always re-loads the receiver. Hold the playhead at
    // the top until the daemon reports that the device has the new manifest;
    // starting a clock here would lead the audio by the whole hand-off.
    if (root.castActive) {
      root.castTrackPending = true
      castTrackHoldTimer.restart()
    }
    root.fetchCurrentArtistArt()
    root.beginTransport("Playing")
    root.blockPlaybackSync()
  }

  function play() {
    // Read daemon.connected rather than the daemonRunning binding: inside
    // DaemonLink.onConnectedChanged the binding may not have re-evaluated yet,
    // which made the resumed play re-arm itself instead of sending.
    if (!daemon.connected) {
      // Start the daemon and remember the intent; the reconnect handler sends
      // the play once the socket is up. This is what used to take two or three
      // presses: the first went into a dead socket and was dropped.
      root.resumeWhenConnected = true
      root.startDaemon()
      return true
    }
    root.anchorPosition(root.position)
    root.apiState = "Playing"
    root.beginTransport("Playing")
    root.blockPlaybackSync()
    actionRequest("play", undefined, function() {
      root.refreshStatus()
    })
    return true
  }

  function pause() {
    if (!daemon.connected) {
      root.resumeWhenConnected = false
      return true
    }
    root.anchorPosition(root.position)
    root.apiState = "Paused"
    root.beginTransport("Paused")
    root.blockPlaybackSync()
    actionRequest("pause", undefined, function() {
      root.refreshStatus()
    })
    return true
  }

  function playPause() {
    if (!daemon.connected) return root.play()
    var nextState = root.playing ? "Paused" : "Playing"
    root.anchorPosition(root.position)
    root.apiState = nextState
    root.beginTransport(nextState)
    root.blockPlaybackSync()
    actionRequest("toggle", undefined, function() {
      root.refreshStatus()
    })
    return true
  }

  function beginQueueAction() {
    root.pendingQueueActions++
  }

  // The last action to complete leaves the daemon's queue at its final
  // selection; pull both once so the UI settles on that instead of waiting
  // for the sync window and the next poll.
  function finishQueueAction() {
    root.pendingQueueActions = Math.max(0, root.pendingQueueActions - 1)
    if (root.pendingQueueActions === 0) {
      root.refreshStatus()
      root.refreshQueue()
    }
  }

  // Repeat-song loops the current track at end of stream. A user-pressed
  // next/previous leaves that mode only when it lands on a different song: at
  // the end of the queue next is a no-op, and previous at the head restarts the
  // current song, both keeping the loop setting. The daemon does the same;
  // mirror it so the indicator flips with the skip instead of after the poll.
  function next() {
    if (!daemon.connected) return false
    var nextIndex = root.queueIndex + 1
    if (nextIndex >= root.queueTracks.length && root.repeatMode === "all") nextIndex = 0
    if (root.queueTracks.length > 0 && nextIndex < root.queueTracks.length) {
      if (root.repeatMode === "track") root.repeatMode = "off"
      root.queueIndex = nextIndex
      root.setOptimisticTrack(root.queueTracks[nextIndex])
      root.apiState = "Playing"
    } else {
      root.blockPlaybackSync()
    }
    root.beginQueueAction()
    actionRequest("next", undefined, function() {
      root.finishQueueAction()
    })
    return true
  }

  function previous() {
    if (!daemon.connected) return false
    if (root.position >= 5.0) {
      root.seek(0)
      return true
    }
    var previousIndex = root.queueIndex - 1
    if (previousIndex < 0 && root.repeatMode === "all" && root.queueTracks.length > 0) {
      previousIndex = root.queueTracks.length - 1
    }
    if (previousIndex >= 0 && previousIndex < root.queueTracks.length) {
      if (root.repeatMode === "track") root.repeatMode = "off"
      root.queueIndex = previousIndex
      root.setOptimisticTrack(root.queueTracks[previousIndex])
      root.apiState = "Playing"
    } else if (root.queueTracks.length > 0) {
      root.queueIndex = 0
      root.setOptimisticTrack(root.queueTracks[0])
      root.apiState = "Playing"
    } else {
      root.blockPlaybackSync()
    }
    root.beginQueueAction()
    actionRequest("previous", undefined, function() {
      root.finishQueueAction()
    })
    return true
  }

  function jump(index) {
    if (!daemon.connected) return false
    var idx = Math.max(0, Math.min(Number(index || 0), Math.max(0, root.queueTracks.length - 1)))
    if (root.queueTracks.length > 0 && idx < root.queueTracks.length) {
      root.queueIndex = idx
      root.setOptimisticTrack(root.queueTracks[idx])
      root.apiState = "Playing"
    }
    root.beginQueueAction()
    actionRequest("jump", idx, function() {
      root.finishQueueAction()
    })
    return true
  }

  function seek(targetSeconds) {
    var secs = Math.max(0, targetSeconds)
    if (root.length > 0) secs = Math.min(secs, root.length)
    root.anchorPosition(secs)
    // Every seek the ui asks for is announced, so a view that follows the
    // playhead (the lyrics sheet) recentres on the user's action itself
    // instead of inferring a jump from a sampled position and racing the
    // transport for it. Seeks from outside (MPRIS) still show up as jumps.
    root.seekRevision++
    // A DASH seek refills in a fraction of a second; don't freeze the position
    // (and the lyrics highlight) for the full transport grace period.
    root.blockPlaybackSync(800)
    actionRequest("seek", secs, function() {
      // The daemon has the seek (a reload included); from here the deck is
      // playing again from the new position, which is what lets a view that
      // held on the target stop waiting for it.
      root.seekSettledRevision++
      root.refreshStatus()
    })
  }

  function seekBy(deltaSeconds) {
    var cur = (root.position !== undefined && !isNaN(root.position)) ? root.position : 0
    var target = Math.max(0, cur + deltaSeconds)
    if (root.length > 0) target = Math.min(target, root.length)
    root.seek(target)
  }

  function setVolume(val) {
    var clamped = Math.max(0.0, Math.min(root.maxVolume, Math.round(val * 100) / 100))
    root.volume = clamped
    // The node's reading of the write we just made arrives a beat later; let
    // it settle instead of feeding it back over the level the user set.
    root.volumeSyncBlockedUntil = Date.now() + 250
    root.applyLocalVolume(clamped)
    actionRequest("volume", clamped)
  }

  // Every notch source (the footer bar's wheel, the bar widget's wheel and the
  // -/+ keys) lands on the 5 % grid: from 17 % one step up is 20 %, one step
  // down is 15 %. A fractional wheel flush counts as one notch, and repeated
  // notches walk the boundaries one at a time.
  function stepVolume(notches) {
    var direction = notches > 0 ? 1 : (notches < 0 ? -1 : 0)
    if (direction === 0) return
    var steps = Math.max(1, Math.round(Math.abs(notches)))
    var percent = Math.round(root.volume * 100)
    for (var i = 0; i < steps; i++) {
      percent = direction > 0
        ? (Math.floor(percent / 5) + 1) * 5
        : (Math.ceil(percent / 5) - 1) * 5
    }
    percent = Math.max(0, Math.min(Math.round(root.maxVolume * 100), percent))
    root.setVolume(percent / 100)
  }

  // Writes the level to the local node without an RPC. The footer bar uses
  // this while the pointer is down; the daemon hears only the final value.
  function applyLocalVolume(clamped) {
    // While casting, the level belongs to the device; touching the stopped mpv
    // node would fight the snapshot the daemon reports.
    if (root.castActive || !root.tidalStreamNode || !root.tidalStreamNode.audio) return
    if (root.tidalStreamNode.audio.muted && clamped > 0) {
      root.tidalStreamNode.audio.muted = false
    }
    root.tidalStreamNode.audio.volume = clamped
  }

  function beginVolumeScrub() {
    root.volumeScrubbing = true
  }

  function previewVolume(val) {
    var clamped = Math.max(0.0, Math.min(root.maxVolume, Math.round(val * 100) / 100))
    root.volume = clamped
    root.applyLocalVolume(clamped)
  }

  function endVolumeScrub() {
    if (!root.volumeScrubbing) return
    root.volumeScrubbing = false
    root.setVolume(root.volume)
  }

  // Mute is a level of zero, which every output already understands: mpv's
  // PipeWire node, a cast receiver, and the status snapshot the daemon keeps
  // in playback.json. The last audible level is remembered so a second press
  // returns to it instead of a guessed 100 %.
  function toggleMute() {
    if (root.muted) {
      root.setVolume(root.lastAudibleVolume > 0.001 ? root.lastAudibleVolume : 1.0)
    } else {
      root.lastAudibleVolume = root.volume
      root.setVolume(0)
    }
  }

  function toggleRepeat() {
    if (!daemon.connected) return
    var nextMode = root.repeatMode === "off" ? "all" : (root.repeatMode === "all" ? "track" : "off")
    root.repeatMode = nextMode
    root.repeatSyncBlockedUntil = Date.now() + 1500
    actionRequest("repeat", nextMode)
  }

  function toggleShuffle() {
    if (!daemon.connected) return
    root.shuffleEnabled = !root.shuffleEnabled
    root.shuffleSyncBlockedUntil = Date.now() + 1500
    actionRequest("shuffle", root.shuffleEnabled, function() {
      root.refreshQueue()
    })
  }

  function setShuffle(enabled) {
    if (!daemon.connected) return
    var boolVal = !!enabled
    if (root.shuffleEnabled !== boolVal) {
      root.shuffleEnabled = boolVal
      root.shuffleSyncBlockedUntil = Date.now() + 1500
      actionRequest("shuffle", boolVal, function() {
        root.refreshQueue()
      })
    }
  }

  // Every daemon call goes through here. The old HTTP helpers checked `alive`
  // before invoking a caller's callback; a hot reload destroys the component
  // while a response may still be in flight, and touching it then takes the
  // whole shell down.
  function rpc(method, params, cb, timeoutMs) {
    daemon.call(method, params, function(err, data) {
      if (!root || !root.alive) return
      if (cb) cb(err, data)
    }, timeoutMs)
  }

  function actionRequest(action, val, callback) {
    var params = { action: action }
    if (val !== undefined) params.value = val
    rpc("playback.action", params, callback, 15000)
  }

  Timer {
    id: playbackSyncTimer
    interval: 1900
    repeat: false
    onTriggered: {
      if (!root.alive) return
      root.optimisticTrack = null
      root.playbackSyncBlockedUntil = 0
      root.resolvePendingTransport()
      root.refreshStatus()
    }
  }

  // ---- Catalogue & Lyrics API Methods ---------------------------------------
  function fetchMixes(cb) {
    rpc("library.mixes", {}, function(err, data) {
      if (err) cb([])
      else cb(data.mixes || [])
    })
  }

  function fetchPlaylists(cb) {
    rpc("library.playlists", {}, function(err, data) {
      if (err) cb([])
      else cb(data.playlists || [])
    })
  }

  function fetchAlbums(cb) {
    rpc("library.albums", {}, function(err, data) {
      if (err) cb([])
      else cb(data.albums || [])
    })
  }

  function fetchArtists(cb) {
    rpc("library.artists", {}, function(err, data) {
      if (err) cb([])
      else cb(data.artists || [])
    })
  }

  // Normalised paged track-list response: {tracks, total, next_offset}.
  function trackPage(data) {
    return {
      tracks: (data && data.tracks) || [],
      total: (data && data.total) || 0,
      next_offset: (data && data.next_offset !== undefined) ? data.next_offset : null
    }
  }

  function fetchPlaylistTracks(plId, offset, limit, cb) {
    rpc("library.playlist", {
      id: plId,
      offset: Number(offset || 0),
      limit: Number(limit || 0)
    }, function(err, data) {
      if (err) cb({ tracks: [], total: 0, next_offset: null })
      else cb(root.trackPage(data))
    })
  }

  function fetchMixTracks(mixId, cb) {
    rpc("library.mix", { id: mixId }, function(err, data) {
      if (err) cb([])
      else cb(data.tracks || [])
    })
  }

  function fetchArtistRadio(artistId, cb) {
    rpc("artist.radio", { id: artistId }, function(err, data) {
      if (err) cb([])
      else cb(data.tracks || [])
    })
  }

  function fetchFavorites(offset, limit, cb) {
    rpc("library.favorites", {
      offset: Number(offset || 0),
      limit: Number(limit || 0)
    }, function(err, data) {
      if (err) cb({ tracks: [], total: 0, next_offset: null })
      else cb(root.trackPage(data))
    })
  }

  function search(query, cb) {
    rpc("search", { q: String(query || "") }, function(err, data) {
      if (err) cb({ tracks: [], artists: [], albums: [], playlists: [] })
      else cb(data)
    }, 60000)
  }

  // ---- Lyrics cache ---------------------------------------------------------
  // Parsed lyrics are kept per track for the session, so turning the lyrics
  // face off and back on (or skipping away and returning) paints an answer the
  // daemon has already given instead of flashing the loading logo again.
  readonly property int lyricsCacheLimit: 64
  property var lyricsCache: ({})
  // Insertion order for eviction: the oldest key leaves first.
  property var lyricsCacheOrder: []
  // One request per track: an ask that arrives while the first is still out
  // joins it rather than sending the same round to TIDAL and LRCLIB twice.
  property var lyricsPending: ({})

  // Every playable row carries a track id, and it alone identifies the song;
  // a request that arrives without one has nothing stable to key on and is
  // simply not cached.
  function lyricsCacheKey(trackId) {
    var id = String(trackId || "")
    return id === "" ? "" : "id:" + id
  }

  function cachedLyrics(trackId) {
    var key = root.lyricsCacheKey(trackId)
    if (key === "") return null
    var entry = root.lyricsCache[key]
    return entry === undefined ? null : entry
  }

  function storeLyrics(trackId, value) {
    var key = root.lyricsCacheKey(trackId)
    if (key === "") return
    var cache = root.lyricsCache
    if (cache[key] === undefined) {
      var order = root.lyricsCacheOrder.slice()
      order.push(key)
      while (order.length > root.lyricsCacheLimit) delete cache[order.shift()]
      root.lyricsCacheOrder = order
    }
    cache[key] = value
  }

  function fetchLyrics(trackId, title, artist, duration, cb) {
    var key = root.lyricsCacheKey(trackId)
    // A cached answer is handed back synchronously, so the caller's loader
    // flag flips on and off inside one call stack and is never painted.
    var cached = root.cachedLyrics(trackId)
    if (cached) {
      if (typeof cb === "function") cb(cached)
      return
    }
    var waiting = key !== "" ? root.lyricsPending[key] : null
    if (waiting) {
      if (typeof cb === "function") waiting.push(cb)
      return
    }
    waiting = typeof cb === "function" ? [cb] : []
    if (key !== "") root.lyricsPending[key] = waiting
    rpc("lyrics", {
      track_id: String(trackId || ""),
      title: String(title || ""),
      artist: String(artist || ""),
      duration: Number(duration || 0)
    }, function(err, data) {
      if (key !== "") delete root.lyricsPending[key]
      var result
      if (err) {
        // A failed request is not an answer: show the empty face but keep it
        // out of the cache so the next toggle asks again.
        result = { synced: false, lines: [], plainText: "" }
      } else {
        var subtitles = data.subtitles || ""
        var parsedLines = Format.parseLrc(subtitles)
        result = {
          synced: data.synced && parsedLines.length > 0,
          lines: parsedLines,
          plainText: data.text || ""
        }
        root.storeLyrics(trackId, result)
      }
      for (var i = 0; i < waiting.length; i++) waiting[i](result)
    })
  }

  function fetchArtist(artistId, cb) {
    rpc("artist", { id: artistId }, function(err, data) {
      if (err) cb(null)
      else cb(data)
    })
  }

  function fetchAlbum(albumId, trackLimit, cb) {
    rpc("album", {
      id: albumId,
      track_limit: Number(trackLimit || 0)
    }, function(err, data) {
      if (err) cb(null)
      else cb(data)
    })
  }

  function fetchAlbumTracks(albumId, offset, limit, cb) {
    rpc("album.tracks", {
      id: albumId,
      offset: Number(offset || 0),
      limit: Number(limit || 0)
    }, function(err, data) {
      if (err) cb({ tracks: [], total: 0, next_offset: null })
      else cb(root.trackPage(data))
    })
  }

  function fetchRecent(cb) {
    root.refreshRecent(function(err, items) {
      if (cb) cb(items || [])
    })
  }

  function startPkceAuth(cb) {
    rpc("auth.pkce.start", {}, function(err, data) {
      if (err) {
        if (cb) cb(err, null)
      } else if (data && data.error) {
        if (cb) cb(new Error(String(data.error)), null)
      } else {
        if (cb) cb(null, data)
      }
    })
  }

  function completePkceAuth(redirectUrl, cb) {
    rpc("auth.pkce.complete", { redirect_url: String(redirectUrl || "") }, function(err, data) {
      if (err) {
        if (cb) cb(err, false)
        return
      }
      if (data && data.success) {
        root.loggedIn = true
        root.accountProfileRetryAt = 0
        root.refreshAccountProfile()
        root.refreshStatus()
        if (cb) cb(null, true)
      } else if (data && data.error) {
        if (cb) cb(new Error(String(data.error)), false)
      } else {
        if (cb) cb(null, false)
      }
    })
  }

  function pollPkceAuth(cb) {
    rpc("auth.pkce.status", {}, function(err, data) {
      if (err) {
        if (cb) cb(err, null)
        return
      }
      if (data && data.logged_in) {
        root.loggedIn = true
        root.accountProfileRetryAt = 0
        root.refreshAccountProfile()
        root.refreshStatus()
      }
      if (cb) cb(null, data)
    })
  }

  function cancelPkceAuth(cb) {
    rpc("auth.pkce.cancel", {}, function(err, data) {
      if (cb) cb(err, data)
    })
  }

  // The account email is only used by the bar settings menu, so it is fetched
  // once per session rather than carried on every status snapshot. A failed
  // lookup backs off so a TIDAL hiccup cannot turn the poll into a retry loop.
  function refreshAccountProfile() {
    if (!root.alive || !root.loggedIn || root.accountProfileLoading) return
    if (Date.now() < root.accountProfileRetryAt) return
    var generation = ++root.accountProfileGeneration
    root.accountProfileLoading = true
    rpc("auth.profile", {}, function(err, data) {
      if (!root || !root.alive || generation !== root.accountProfileGeneration) return
      root.accountProfileLoading = false
      if (err || !data || data.logged_in === false) {
        root.accountProfileRetryAt = Date.now() + 30000
        return
      }
      var email = String(data.email || data.username || "")
      if (email === "") {
        root.accountProfileRetryAt = Date.now() + 30000
        return
      }
      root.accountAvatarUrl = String(data.avatar_url || "")
      root.accountUserId = String(data.id || "")
      root.accountEmail = email
    })
  }

  function resetAccountProfile() {
    root.accountProfileGeneration++
    root.accountProfileLoading = false
    root.accountProfileRetryAt = 0
    root.accountEmail = ""
    root.accountAvatarUrl = ""
    root.accountUserId = ""
  }

  // The signed-in account's public profile on the TIDAL web player, opened in
  // the browser. No-op until the account id from `auth.profile` has landed.
  function openAccountProfile() {
    if (root.accountUserId === "") return
    Quickshell.execDetached(["xdg-open", "https://tidal.com/user/" + root.accountUserId])
  }

  function loadRecentSearches() {
    rpc("library.searches.recent", {}, function(err, data) {
      if (!err && data && data.searches) {
        root.recentSearches = data.searches
      }
    })
  }

  function addRecentSearch(query) {
    if (!query || !query.trim()) return
    var q = query.trim()
    var updated = [q]
    for (var i = 0; i < root.recentSearches.length; i++) {
      var s = typeof root.recentSearches[i] === "string" ? root.recentSearches[i] : (root.recentSearches[i].title || "")
      if (s && s.toLowerCase() !== q.toLowerCase()) {
        updated.push(s)
      }
    }
    root.recentSearches = updated.slice(0, 10)

    rpc("library.searches.recent.add", { query: q }, null, 15000)
  }

  function clearRecentSearches() {
    root.recentSearches = []
    rpc("library.searches.recent.clear", {}, null, 15000)
  }

  // ---- Playlist Management --------------------------------------------------
  // One request/response helper for catalogue mutations. The daemon keeps its
  // `{ "error": ... }` result shape, so a handler-level failure reaches the
  // caller as an Error with the payload attached.
  function rpcCall(method, params, cb, timeoutMs) {
    rpc(method, params || {}, function(err, data) {
      if (!root || !root.alive) return
      if (err) {
        if (cb) cb(err, data)
        return
      }
      if (data && data.error !== undefined) {
        if (cb) cb(new Error(String(data.error)), data)
        return
      }
      if (cb) cb(null, data)
    }, timeoutMs || 30000)
  }

  function fetchPlaylistInfo(id, cb) {
    rpc("library.playlist.info", { id: id }, function(err, data) {
      if (err || !data || data.error) cb(null)
      else cb(data)
    })
  }

  function createPlaylist(title, description, cb) {
    rpcCall("library.playlist.create", { title: title, description: description || "" }, cb)
  }

  function updatePlaylist(id, title, description, cb) {
    var payload = { id: id }
    if (title !== undefined && title !== null) payload.title = title
    if (description !== undefined && description !== null) payload.description = description
    rpcCall("library.playlist.update", payload, cb)
  }

  function setPlaylistPublic(id, isPublic, cb) {
    rpcCall("library.playlist.update", { id: id, public: isPublic === true }, cb)
  }

  function deletePlaylist(id, cb) {
    rpcCall("library.playlist.delete", { id: id }, cb)
  }

  function addTracksToPlaylist(id, trackIds, cb) {
    rpcCall("library.playlist.add", { id: id, track_ids: trackIds }, function(err, data) {
      if (!err) {
        root.playlistRevision++
        // A track re-added to its playing playlist can be removed from it
        // again; drop the song menu's "already removed" memory for it.
        for (var i = 0; i < trackIds.length; i++) {
          if (root.removedPlaylistKey === String(id) + ":" + String(trackIds[i])) {
            root.removedPlaylistKey = ""
            break
          }
        }
      }
      if (cb) cb(err, data)
    })
  }

  // Bumped when a playlist's items change, so a cached playlist page refetches
  // the next time it is shown (mirrors favoritesRevision).
  property int playlistRevision: 0

  function removePlaylistTracks(id, indices, cb) {
    rpcCall("library.playlist.remove", { id: id, indices: indices }, function(err, data) {
      if (!err) root.playlistRevision++
      if (cb) cb(err, data)
    })
  }

  function movePlaylistTrack(id, from, to, cb) {
    rpcCall("library.playlist.move", { id: id, from: from, to: to }, function(err, data) {
      if (!err) root.playlistRevision++
      if (cb) cb(err, data)
    })
  }

  // "context id : track id" of a track removed from the playlist it is playing
  // from, so the song menu stops offering that removal for the same pair.
  property string removedPlaylistKey: ""

  // Removes the playing track from the playlist it is playing from. Only for
  // contexts that are playlists the signed-in user created; the daemon
  // resolves the item's live index by track id. The song menu confirms in
  // place (a tick, no notification), so cb(true/false) reports the outcome and
  // only a failure is surfaced.
  function removeCurrentFromPlaylist(cb) {
    var ctx = root.currentContext
    if (!ctx || ctx.type !== "playlist" || ctx.own !== true || !ctx.id) {
      if (cb) cb(false)
      return
    }
    var trackId = root.currentTrackId
    if (!trackId) {
      if (cb) cb(false)
      return
    }
    var name = ctx.title || "playlist"
    rpcCall("library.playlist.remove_track", { id: String(ctx.id), track_id: String(trackId) }, function(err, data) {
      if (err || !data || data.ok === false || data.removed === false) {
        root.notify("Could not remove from \u201C" + name + "\u201D")
        if (cb) cb(false)
        return
      }
      root.removedPlaylistKey = String(ctx.id) + ":" + String(trackId)
      root.playlistRevision++
      if (cb) cb(true)
    })
  }

  function notify(message) {
    if (errorNotifyProc.running) return false
    errorNotifyProc.command = ["notify-send", "-a", "TIDAL Player", "-i", "file://" + root.shareBadgeIcon, "--", "TIDAL Player", message]
    errorNotifyProc.running = true
    return true
  }

  property var currentContext: ({ type: "", id: "", title: "", artUrl: "" })

  function playContext(tracks, startIndex, contextObj) {
    var playable = Format.playableTracks(tracks, startIndex || 0)
    if (tracks && tracks.length > 0 && playable.tracks.length === 0) return false
    if (typeof contextObj === "string") {
      root.playingContext = contextObj
      root.currentContext = { type: "custom", id: "", title: contextObj, artUrl: "" }
    } else if (contextObj) {
      root.playingContext = contextObj.title || ""
      root.currentContext = {
        type: contextObj.type || "",
        id: contextObj.id || "",
        // A context may label itself differently to the queue ("Top
        // Tracks: Artist") and to the recent list ("Artist" plus the "Top
        // Tracks" type label).
        title: contextObj.recentTitle || contextObj.title || "",
        subtitle: contextObj.subtitle || "",
        artUrl: contextObj.artUrl || contextObj.art_url || "",
        // Playlists the user created can be edited and removed from while
        // they play; the flag rides into the daemon's context_ref and back.
        own: contextObj.own === true
      }
    } else if (playable.tracks.length > 0) {
      var track = playable.tracks[Math.max(0, Math.min(playable.index, playable.tracks.length - 1))]
      root.currentContext = {
        type: "track",
        id: String(track.id || ""),
        title: track.title || "Track",
        subtitle: track.artist || "",
        artUrl: track.art_url || ""
      }
      root.playingContext = track.title || "Track"
    }
    return playQueue(playable.tracks, playable.index, root.playingContext)
  }

  function playQueue(tracks, startIndex, context) {
    if (!daemon.connected) return false
    var playable = Format.playableTracks(tracks, startIndex || 0)
    if (tracks && tracks.length > 0 && playable.tracks.length === 0) return false
    var start = playable.index
    var ctx = context === undefined || context === null ? "" : String(context)
    root.queueTracks = playable.tracks.slice()
    root.queueIndex = root.queueTracks.length > 0 ? Math.min(start, root.queueTracks.length - 1) : 0
    if (root.queueTracks.length > 0) {
      root.setOptimisticTrack(root.queueTracks[root.queueIndex])
      root.apiState = "Playing"
      if (!ctx) {
        var firstTrack = root.queueTracks[root.queueIndex]
        root.currentContext = {
          type: "track",
          id: String(firstTrack.id || ""),
          title: firstTrack.title || "Track",
          subtitle: firstTrack.artist || "",
          artUrl: firstTrack.art_url || ""
        }
        ctx = firstTrack.title || "Track"
      }
    }
    root.playingContext = ctx
    root.queueLoaded = true
    root.queueRequestGeneration++
    var playbackRequestRevision = root.playbackRevision
    var recent = root.currentContext
    var request = { tracks: root.queueTracks, index: root.queueIndex, context: ctx }
    if (recent && recent.id && recent.title && recent.type) {
      request.recent_context = {
        id: String(recent.id),
        title: String(recent.title),
        subtitle: recent.subtitle || null,
        type: String(recent.type),
        art_url: recent.artUrl || null,
        own: recent.own === true
      }
    }
    rpc("playback.play", request, function(err, data) {
      if (!root || !root.alive) return
      if (!err && data && data.ok !== false && playbackRequestRevision === root.playbackRevision) {
        root.refreshQueue()
        root.refreshRecent()
      }
    }, 30000)
    return true
  }

  function playNext(track) {
    if (!daemon.connected || !track || !Format.isTrackAvailable(track)) return
    var nextQueue = root.queueTracks.slice()
    var insertAt = nextQueue.length > 0 ? Math.min(root.queueIndex + 1, nextQueue.length) : 0
    nextQueue.splice(insertAt, 0, track)
    root.queueTracks = nextQueue
    root.queueRequestGeneration++
    actionRequest("play_next", track, function() {
      root.refreshStatus()
    })
  }

  function setQueueSnapshot(tracks, index, context) {
    root.queueTracks = (tracks || []).slice()
    root.queueIndex = Math.max(0, Math.min(Number(index || 0), Math.max(0, root.queueTracks.length - 1)))
    if (context) root.playingContext = String(context)
    root.queueLoaded = true
  }

  function refreshQueue(cb) {
    if (!root.alive) return
    var generation = ++root.queueRequestGeneration
    // A snapshot requested before a local queue action, or while one is still
    // in flight, predates the selection that action just made. Its tracks are
    // still good, but its index must not undo the optimistic skip.
    var requestRevision = root.playbackRevision
    var requestPending = root.pendingQueueActions
    rpc("queue.get", {}, function(err, data) {
      if (generation !== root.queueRequestGeneration) {
        if (cb) cb(new Error("Stale queue response"), null)
        return
      }
      if (!err && data) {
        root.queueTracks = data.tracks || []
        if (requestRevision === root.playbackRevision && requestPending === 0) {
          root.queueIndex = Math.max(0, Math.min(Number(data.index || 0), Math.max(0, root.queueTracks.length - 1)))
        } else {
          root.queueIndex = Math.max(0, Math.min(root.queueIndex, Math.max(0, root.queueTracks.length - 1)))
        }
        if (data.context) root.playingContext = String(data.context)
        if (data.context_ref && data.context_ref.id) {
          root.currentContext = {
            id: String(data.context_ref.id),
            type: String(data.context_ref.type || ""),
            title: String(data.context_ref.title || ""),
            subtitle: String(data.context_ref.subtitle || ""),
            artUrl: String(data.context_ref.artUrl || data.context_ref.art_url || ""),
            own: data.context_ref.own === true
          }
        }
        root.queueLoaded = true
      }
      if (cb) cb(err, data)
    })
  }

  function refreshRecent(cb) {
    if (!root.alive) return
    var generation = ++root.recentRequestGeneration
    rpc("library.recent", {}, function(err, data) {
      if (generation !== root.recentRequestGeneration) {
        if (cb) cb(new Error("Stale recent response"), null)
        return
      }
      if (!err && data && Array.isArray(data.items)) {
        // Plain artist contexts are legacy (artist playback now records
        // `artistTopTracks`); never show them in Recently Played.
        var newItems = data.items.filter(function(item) {
          return item && item.type !== "artist"
        })
        var changed = (newItems.length !== root.recentItems.length)
        if (!changed) {
          for (var i = 0; i < newItems.length; i++) {
            if (newItems[i].id !== root.recentItems[i].id
                || newItems[i].type !== root.recentItems[i].type
                || String(newItems[i].title || "") !== String(root.recentItems[i].title || "")
                // A context can be replayed with artwork or a label it did not
                // carry the first time (older entries were stored without them).
                || String(newItems[i].art_url || "") !== String(root.recentItems[i].art_url || "")
                || String(newItems[i].subtitle || "") !== String(root.recentItems[i].subtitle || "")) {
              changed = true
              break
            }
          }
        }
        if (changed) {
          root.recentItems = newItems
        }
      }
      if (cb) cb(err, root.recentItems)
    })
  }

  // The spinner has to survive a scan that is already answered from the
  // daemon's cache: mark when it went up, and on completion hold it for
  // whatever is left of the minimum instead of clearing it at once.
  function beginCastLoading() {
    castSpinTimer.stop()
    root.castSpinStartedAt = Date.now()
    root.castLoading = true
  }

  function endCastLoading() {
    var remaining = root.castSpinMinimumMs - (Date.now() - root.castSpinStartedAt)
    if (remaining <= 0) {
      root.castLoading = false
      return
    }
    castSpinTimer.interval = remaining
    castSpinTimer.restart()
  }

  function refreshCastDevices(refresh, cb, quiet) {
    if (!root.alive) return
    var generation = ++root.castRequestGeneration
    if (!quiet) root.beginCastLoading()
    rpc("cast.devices", { refresh: !!refresh }, function(err, data) {
      if (generation !== root.castRequestGeneration) return
      if (!quiet) root.endCastLoading()
      if (!err && data) {
        root.castDevices = data.devices || []
        root.castLastUsedId = String(data.last_used_id || "")
      }
      if (cb) cb(err, root.castDevices)
    })
  }

  // Connecting is not casting yet: the device is only "active" once the daemon
  // reports a live session. Until then the sheet shows a Connecting row rather
  // than flipping the header and claiming playback has moved.
  function connectCast(deviceId, cb) {
    if (!root.alive || !deviceId) return
    var device = null
    for (var i = 0; i < root.castDevices.length; i++) {
      if (root.castDevices[i].id === deviceId) {
        device = root.castDevices[i]
        break
      }
    }
    root.castBusy = true
    root.castConnectingId = String(deviceId)
    root.castFailedId = ""
    root.castStreamBlocked = false
    var connectingName = device && device.name ? String(device.name) : ""
    rpcCall("cast.connect", { device_id: deviceId }, function(err, data) {
      root.castBusy = false
      root.castConnectingId = ""
      if (err || (data && data.ok === false)) {
        root.castActive = false
        root.castStreamBlocked = false
        // The row carries the failure; there is no system notification.
        root.castFailedId = String(deviceId)
        root.refreshStatus()
        // The daemon's probe knows why the connect failed: re-read the list so
        // a device that has gone away is dimmed as Unavailable immediately,
        // instead of looking healthy until the next poll.
        root.refreshCastDevices(false, null, true)
        if (cb) cb(err || new Error((data && data.error) || "Could not cast"), data)
        return
      }
      root.castActive = true
      root.castFailedId = ""
      root.castStreamBlocked = false
      // The daemon records this device as the last used one; mirror it so the
      // sheet's ordering is right even before the next device-list poll.
      root.castLastUsedId = String(deviceId)
      if (data && data.device) {
        root.castDeviceId = String(data.device.id || deviceId)
        root.castDeviceName = String(data.device.name || connectingName)
        root.castDeviceKind = String(data.device.kind || "")
      } else {
        root.castDeviceId = String(deviceId)
        root.castDeviceName = connectingName
        root.castDeviceKind = device && device.kind ? String(device.kind) : ""
      }
      root.refreshStatus()
      if (cb) cb(null, data)
    })
  }

  function disconnectCast(cb) {
    if (!root.alive) return
    root.castBusy = true
    rpcCall("cast.disconnect", {}, function(err, data) {
      root.castBusy = false
      root.castConnectingId = ""
      root.castFailedId = ""
      root.castActive = false
      root.castDeviceId = ""
      root.castDeviceName = ""
      root.castDeviceKind = ""
      root.castStreamBlocked = false
      root.castTrackPending = false
      // `castLastUsedId` keeps its value: the daemon remembers that device, and
      // the sheet should now float it to the top with its "Last used" badge.
      root.refreshStatus()
      if (cb) cb(err, data)
    })
  }

  // The sheet drops a stale failure when it closes: the badge reports the
  // attempt the user just made, not a permanent state of the device.
  function clearCastFailure() {
    root.castFailedId = ""
  }

  // ---- Status Payload & Serialization ---------------------------------------
  function statusPayload() {
    return {
      connected: root.connected,
      playing: root.playing,
      title: root.title,
      artist: root.artist,
      album: root.album,
      isHiRes: root.isHiRes,
      formatBadge: root.formatBadge,
      position: root.position,
      duration: root.length,
      artUrl: root.artUrl,
      artistArtUrl: root.currentArtistArtUrl,
      artistId: root.artistId,
      playingContext: root.playingContext,
      currentContext: root.currentContext,
      queueCount: root.queueTracks.length,
      daemonConnected: root.daemonRunning,
      daemonState: root.daemonState,
      daemonStarting: root.daemonStarting,
      daemonStartError: root.daemonStartError,
      loggedIn: root.loggedIn,
      statusLoaded: root.statusLoaded,
      castDevice: root.castDeviceName
    }
  }

  // A short human-readable status for `omarchy shell tidalplayer status`.
  // Deliberately not JSON: the CLI's `status` and `rpc status` cover data
  // consumers; this is the quick look.
  function statusSummary() {
    if (!root.daemonRunning) return "Daemon:  not running"
    var state = root.castDeviceName ? "casting to " + root.castDeviceName
      : (root.playing ? "playing" : (root.title ? "paused" : "stopped"))
    var lines = [
      "State:   " + state,
      "Track:   " + (root.title ? root.artist + " \u2014 " + root.title : "nothing playing")
    ]
    if (root.album) lines.push("Album:   " + root.album)
    lines.push("Time:    " + Format.formatDuration(root.position) + " / " + Format.formatDuration(root.length))
    if (root.formatBadge) lines.push("Format:  " + root.formatBadge)
    return lines.join("\n")
  }

  // Opens the cast device sheet (`omarchy shell tidalplayer cast`).
  function openCast() {
    root.openMini()
    var widget = root.activeMiniPlayer
    if (widget && typeof widget.openSheet === "function") widget.openSheet("cast")
    return true
  }

  property bool favorite: false
  // A favourite toggle is optimistic; its action response is authoritative.
  // Ignore status favourites until all in-flight toggles settle so a snapshot
  // cannot revert the heart.
  property int favoritePendingCount: 0
  readonly property bool favoritePending: favoritePendingCount > 0
  // Bumped when a track favourite is confirmed, so the Tracks list
  // (and anything else showing favourites) can refetch.
  property int favoritesRevision: 0

  function toggleFavorite(trackId) {
    var tid = trackId || root.currentTrackId
    if (!tid) return
    var isCurrent = !trackId || String(tid) === String(root.currentTrackId || "")
    var prevFavorite = root.favorite
    if (isCurrent) {
      root.favorite = !root.favorite
      root.favoritePendingCount++
    }
    actionRequest("favorite", tid, function(err, data) {
      if (isCurrent) root.favoritePendingCount = Math.max(0, root.favoritePendingCount - 1)
      if (!err && data && data.favorite !== undefined) {
        if (String(tid) === String(root.currentTrackId || "") && root.favoritePendingCount === 0) {
          root.favorite = data.favorite
        }
      } else if (err && isCurrent && String(tid) === String(root.currentTrackId || "") && root.favoritePendingCount === 0) {
        root.favorite = prevFavorite
      }
      if (!err) root.favoritesRevision++
    })
  }

  // Album/artist/playlist favourites. Track favourites stay on
  // toggleFavorite because the status snapshot mirrors that flag.
  function toggleEntityFavorite(kind, id, cb) {
    if (!id) return
    rpcCall("library.favorite", { type: kind, id: id }, cb)
  }

  function previewSeek(seconds) {
    var secs = Math.max(0, seconds)
    if (root.length > 0) secs = Math.min(secs, root.length)
    root.position = secs
  }

  function commitSeek(seconds) {
    root.seek(seconds)
  }

  function beginScrub() {
    root.activeScrubbers++
  }

  function endScrub() {
    root.activeScrubbers = Math.max(0, root.activeScrubbers - 1)
  }

  // ---- MiniPlayer Registry & Popup Summoning --------------------------------
  property var miniPlayers: []
  property var activeMiniPlayer: null

  function registerMiniPlayer(widget) {
    var next = root.miniPlayers.slice()
    next.push(widget)
    root.miniPlayers = next
  }

  function unregisterMiniPlayer(widget) {
    var next = []
    for (var i = 0; i < root.miniPlayers.length; i++) {
      if (root.miniPlayers[i] !== widget) next.push(root.miniPlayers[i])
    }
    root.miniPlayers = next
    if (root.activeMiniPlayer === widget) root.activeMiniPlayer = null
  }

  // No instance on the focused monitor (or focus unresolved): fall back to
  // the first instance permitted on its monitor. A monitor-filtered widget is
  // not allowed off its outputs, while `hideWhenPaused` still allows IPC open.
  function fallbackMiniPlayer() {
    for (var i = 0; i < root.miniPlayers.length; i++) {
      var widget = root.miniPlayers[i]
      if (widget && widget.allowedOnMonitor !== false) return widget
    }
    return null
  }

  function toggleMini() {
    for (var i = 0; i < root.miniPlayers.length; i++) {
      try {
        var widget = root.miniPlayers[i]
        if (widget && typeof widget.toggleIfFocused === "function" && widget.toggleIfFocused()) {
          root.activeMiniPlayer = widget.popupOpen ? widget : null
          return true
        }
      } catch (e) {}
    }
    var fallbackWidget = root.fallbackMiniPlayer()
    if (fallbackWidget) {
      try {
        fallbackWidget.toggle()
        root.activeMiniPlayer = fallbackWidget.popupOpen ? fallbackWidget : null
        return true
      } catch (e) {}
    }
    return false
  }

  function openMini() {
    for (var i = 0; i < root.miniPlayers.length; i++) {
      try {
        var widget = root.miniPlayers[i]
        if (widget && typeof widget.openIfFocused === "function" && widget.openIfFocused()) {
          root.activeMiniPlayer = widget
          return true
        }
      } catch (e) {}
    }
    var fallbackWidget = root.fallbackMiniPlayer()
    if (fallbackWidget) {
      try {
        root.activeMiniPlayer = fallbackWidget
        root.activeMiniPlayer.open()
        return true
      } catch (e) {}
    }
    return false
  }

  function closeMini() {
    for (var i = 0; i < root.miniPlayers.length; i++) {
      try { root.miniPlayers[i].close() } catch (e) {}
    }
    root.activeMiniPlayer = null
    return true
  }

  function setFace(name, params) {
    root.openMini()
    var widget = root.activeMiniPlayer
    if (widget && typeof widget.setFace === "function") widget.setFace(name, params)
    return true
  }

  function pushFace(name, params) {
    root.openMini()
    var widget = root.activeMiniPlayer
    if (widget && typeof widget.pushFace === "function") widget.pushFace(name, params)
    return true
  }

  function backMini() {
    var widget = root.activeMiniPlayer
    if (widget && typeof widget.back === "function") widget.back()
    return true
  }

  function forwardMini() {
    var widget = root.activeMiniPlayer
    if (widget && typeof widget.forward === "function") widget.forward()
    return true
  }

  function trackMenuMini() {
    root.openMini()
    var widget = root.activeMiniPlayer
    if (widget && typeof widget.openTrackMenu === "function") widget.openTrackMenu()
    return true
  }

  function toggleLyricsMini() {
    root.openMini()
    var widget = root.activeMiniPlayer
    if (widget && typeof widget.toggleLyrics === "function") widget.toggleLyrics()
    return true
  }

  function logout() {
    root.loggedIn = false
    root.authPending = false
    root.authExchanging = false
    root.authError = ""
    root.resetAccountProfile()
    // Clear playback, queue, cast, and cached metadata immediately so neither
    // the bar widget nor a subsequent account inherits the previous session.
    root.apiTrack = null
    root.optimisticTrack = null
    root.apiState = "Stopped"
    root.pendingTransport = ""
    root.pendingTransportUntil = 0
    root.playbackSyncBlockedUntil = 0
    root.formatBadge = ""
    root.isHiRes = false
    root.currentTrackId = null
    root.playingContext = ""
    root.queueTracks = []
    root.queueIndex = 0
    root.warmArtUrls = []
    root.warmArtistArtUrls = []
    root.anchorPosition(0)
    root.castActive = false
    root.castDeviceId = ""
    root.castDeviceName = ""
    root.castDeviceKind = ""
    root.castConnectingId = ""
    root.castFailedId = ""
    root.castStreamBlocked = false
    root.castPending = false
    root.castTrackPending = false
    root.recentSearches = []
    root.recentItems = []
    root.artistArtCache = ({})
    root.lyricsCache = ({})
    root.lyricsCacheOrder = []
    root.lyricsPending = ({})
    // Open the panel directly onto the login face after the bar menu closes.
    Qt.callLater(function() {
      if (root && root.alive) root.openMini()
    })
    rpc("auth.logout", {}, function() {
      if (!root || !root.alive) return
      root.refreshStatus()
      root.refreshQueue()
    }, 15000)
    return true
  }

  // The shell owns uninstall (it removes the widget). scripts/uninstall.sh
  // runs in a floating terminal, which is the one place a confirmation cannot
  // be dismissed accidentally by closing a panel.
  function requestUninstall() {
    var path = root.pluginDir + "/scripts/uninstall.sh"
    var command = "'" + path.replace(/'/g, "'\\''") + "'"
    Quickshell.execDetached([
      "omarchy-launch-floating-terminal-with-presentation", command
    ])
  }

  // ---- Shell help -----------------------------------------------------------
  // Answer for `omarchy shell tidalplayer help`: every IPC command, grouped.
  // Rows are two spaces, the command, padding to the description column and
  // the description; keep the columns aligned when editing (longest command
  // is "tracks | playlists | mixes").
  function ipcHelp() {
    return [
      "TIDAL Player \u2014 shell commands",
      "",
      "Usage: omarchy shell tidalplayer <command> [args]",
      "",
      "Panel",
      "  open | close | toggle       Open, close or toggle the panel",
      "  back | forward              Step through the view history",
      "",
      "Pages",
      "  nowPlaying                  Open the now-playing page",
      "  music                       Open the Music page",
      "  queue                       Open the play queue",
      "  search <query>              Search the TIDAL catalogue",
      "  albums | artists            Open your albums / artists",
      "  tracks | playlists | mixes  Open tracks / playlists / mixes",
      "  album <id>                  Open an album",
      "  artist <id>                 Open an artist page",
      "  discography <id>            Open an artist's discography",
      "  topTracksOf <id>            Open an artist's top tracks",
      "  playlist <id>               Open a playlist",
      "  mix <id>                    Open a mix",
      "",
      "Page actions",
      "  menu                        Open the context menu for the current page",
      "  toggleLyrics                Toggle lyrics on the now-playing page",
      "  cast                        Open the cast device panel",
      "",
      "Playback & volume",
      "  play | pause | playPause    Control playback; playPause toggles play/pause",
      "  next | previous             Skip to the next / previous track",
      "  seek <[+|-]sec>             Seek relative (+10, -10) or to an absolute position",
      "  volume <0.0-1.5>            Set the volume (1.0 = 100%)",
      "",
      "Status & uninstall",
      "  status                      Show a short playback status",
      "  uninstall                   Uninstall the plugin, daemon and state (asks first)",
      "  help                        Show this help",
      "",
      "The CLI controls the daemon \u2014 playback from the terminal, casting,",
      "account and service management:",
      "  omarchy-tidalplayer help"
    ].join("\n")
  }

  // ---- IPC Handlers ---------------------------------------------------------
  // Supports both 'tidalplayer' (for the default Omarchy SUPER+M keybind) and 'scorchedegg.tidalplayer'.
  IpcHandler {
    target: "tidalplayer"

    // Panel
    function open(): string { root.openMini(); return "ok" }
    function close(): string { root.closeMini(); return "ok" }
    function toggle(): string { root.toggleMini(); return "ok" }
    function back(): string { root.backMini(); return "ok" }
    function forward(): string { root.forwardMini(); return "ok" }

    // Pages
    function nowPlaying(): string { root.setFace("nowPlaying"); return "ok" }
    function music(): string { root.setFace("collections"); return "ok" }
    function queue(): string { root.pushFace("queue", {}); return "ok" }
    function search(q: string): string { root.pushFace("search", { query: q }); return "searching" }
    function albums(): string { root.pushFace("collectionList", { listType: "albums", title: "Albums" }); return "ok" }
    function artists(): string { root.pushFace("collectionList", { listType: "artists", title: "Artists" }); return "ok" }
    function playlists(): string { root.pushFace("collectionList", { listType: "playlists", title: "Playlists" }); return "ok" }
    function mixes(): string { root.pushFace("collectionList", { listType: "mixes", title: "Mixes" }); return "ok" }
    function tracks(): string { root.pushFace("playlist", { playlistId: "favorites", itemType: "favorites", title: "Tracks", subtitle: "", artUrl: "" }); return "ok" }
    function album(id: string): string { root.pushFace("playlist", { playlistId: id, itemType: "album", title: "Album" }); return "ok" }
    function artist(id: string): string { root.pushFace("artist", { artistId: id, name: "", artUrl: "" }); return "ok" }
    function discography(id: string): string { root.pushFace("releases", { filter: "popular", artistId: id, name: "", artUrl: "" }); return "ok" }
    function mix(id: string): string { root.pushFace("playlist", { playlistId: id, itemType: "mix", title: "Mix" }); return "ok" }
    function playlist(id: string): string { root.pushFace("playlist", { playlistId: id, itemType: "playlist", title: "Playlist" }); return "ok" }
    function topTracksOf(id: string): string {
      var art = (root.artistArtCache && root.artistArtCache[id]) ? String(root.artistArtCache[id]) : ""
      root.pushFace("topTracks", { artistId: id, name: "", artUrl: art })
      return "ok"
    }

    // Page actions
    function menu(): string { root.trackMenuMini(); return "ok" }
    function toggleLyrics(): string { root.toggleLyricsMini(); return "ok" }

    // Cast — the panel only; cast control lives on the CLI.
    function cast(): string { root.openCast(); return "ok" }

    // Playback & volume (conveniences for keybinds)
    function play(): string { root.play(); return "ok" }
    function pause(): string { root.pause(); return "ok" }
    function playPause(): string { root.playPause(); return "ok" }
    function next(): string { root.next(); return "ok" }
    function previous(): string { root.previous(); return "ok" }
    function seek(val: string): string {
      var s = String(val !== undefined ? val : "").trim()
      if (s === "") return "ok"
      if (s.indexOf("+") === 0 || s.indexOf("-") === 0) {
        var delta = parseFloat(s)
        if (isFinite(delta)) root.seekBy(delta)
      } else {
        var pos = parseFloat(s)
        if (isFinite(pos)) root.seek(pos)
      }
      return "ok"
    }
    function volume(val: real): string { if (isFinite(val)) root.setVolume(val); return "ok" }

    // Status & system
    function status(): string { return root.statusSummary() }
    function uninstall(): string { root.requestUninstall(); return "opening uninstall terminal" }
    function help(): string { return root.ipcHelp() }
  }

  IpcHandler {
    target: "scorchedegg.tidalplayer"

    // Panel
    function open(): string { root.openMini(); return "ok" }
    function close(): string { root.closeMini(); return "ok" }
    function toggle(): string { root.toggleMini(); return "ok" }
    function back(): string { root.backMini(); return "ok" }
    function forward(): string { root.forwardMini(); return "ok" }

    // Pages
    function nowPlaying(): string { root.setFace("nowPlaying"); return "ok" }
    function music(): string { root.setFace("collections"); return "ok" }
    function queue(): string { root.pushFace("queue", {}); return "ok" }
    function search(q: string): string { root.pushFace("search", { query: q }); return "searching" }
    function albums(): string { root.pushFace("collectionList", { listType: "albums", title: "Albums" }); return "ok" }
    function artists(): string { root.pushFace("collectionList", { listType: "artists", title: "Artists" }); return "ok" }
    function playlists(): string { root.pushFace("collectionList", { listType: "playlists", title: "Playlists" }); return "ok" }
    function mixes(): string { root.pushFace("collectionList", { listType: "mixes", title: "Mixes" }); return "ok" }
    function tracks(): string { root.pushFace("playlist", { playlistId: "favorites", itemType: "favorites", title: "Tracks", subtitle: "", artUrl: "" }); return "ok" }
    function album(id: string): string { root.pushFace("playlist", { playlistId: id, itemType: "album", title: "Album" }); return "ok" }
    function artist(id: string): string { root.pushFace("artist", { artistId: id, name: "", artUrl: "" }); return "ok" }
    function discography(id: string): string { root.pushFace("releases", { filter: "popular", artistId: id, name: "", artUrl: "" }); return "ok" }
    function mix(id: string): string { root.pushFace("playlist", { playlistId: id, itemType: "mix", title: "Mix" }); return "ok" }
    function playlist(id: string): string { root.pushFace("playlist", { playlistId: id, itemType: "playlist", title: "Playlist" }); return "ok" }
    function topTracksOf(id: string): string {
      var art = (root.artistArtCache && root.artistArtCache[id]) ? String(root.artistArtCache[id]) : ""
      root.pushFace("topTracks", { artistId: id, name: "", artUrl: art })
      return "ok"
    }

    // Page actions
    function menu(): string { root.trackMenuMini(); return "ok" }
    function toggleLyrics(): string { root.toggleLyricsMini(); return "ok" }

    // Cast — the panel only; cast control lives on the CLI.
    function cast(): string { root.openCast(); return "ok" }

    // Playback & volume (conveniences for keybinds)
    function play(): string { root.play(); return "ok" }
    function pause(): string { root.pause(); return "ok" }
    function playPause(): string { root.playPause(); return "ok" }
    function next(): string { root.next(); return "ok" }
    function previous(): string { root.previous(); return "ok" }
    function seek(val: string): string {
      var s = String(val !== undefined ? val : "").trim()
      if (s === "") return "ok"
      if (s.indexOf("+") === 0 || s.indexOf("-") === 0) {
        var delta = parseFloat(s)
        if (isFinite(delta)) root.seekBy(delta)
      } else {
        var pos = parseFloat(s)
        if (isFinite(pos)) root.seek(pos)
      }
      return "ok"
    }
    function volume(val: real): string { if (isFinite(val)) root.setVolume(val); return "ok" }

    // Status & system
    function status(): string { return root.statusSummary() }
    function uninstall(): string { root.requestUninstall(); return "opening uninstall terminal" }
    function help(): string { return root.ipcHelp() }
  }
}
