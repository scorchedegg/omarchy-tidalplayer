import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import qs.Commons
import "../components"
import "../lib/Wheel.js" as Wheel
import "../lib/Format.js" as Format

Item {
  id: root
  layer.enabled: true

  property bool alive: true
  Component.onDestruction: {
    root.alive = false
    lyricsNotchTimer.stop()
    lyricSeekHoldTimer.stop()
  }

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  // MiniPlayer's layer above the header, where the sheets are reparented.
  property Item overlayHost: null
  property string playingFrom: (svc && svc.playingContext) ? svc.playingContext : "Top Tracks"
  property bool lyricsActive: false
  property bool menuOpen: false
  property bool pickerOpen: false
  property bool videoActive: true

  // The play/pause tooltip must not rise just because the button's state
  // flipped under a resting pointer (a click or a Space press): it would cover
  // the quality line above the transport. Suppressing it leaves it down until
  // the pointer leaves the button and comes back, like a click does.
  readonly property bool playState: !!(root.svc && root.svc.playing)
  onPlayStateChanged: playTip.suppress()

  signal queueClicked()
  signal artistClicked()
  signal menuRequested()
  signal artistSelected(string id, string name)
  signal albumClicked(string id, string title, string artUrl)
  signal shareClicked()
  signal radioClicked(string id, string artUrl, string recentSubtitle)
  signal contextClicked(var context)

  // Synced Lyrics Data
  property var lyricsData: ({ synced: false, lines: [], plainText: "" })
  // True from the moment a request goes out until its answer lands, so the face
  // can pulse the logo instead of claiming the track has no lyrics.
  property bool lyricsLoading: false
  // Requests can overlap (a skip while the previous answer is in flight), and
  // only the newest one may write the face.
  property int lyricsRequest: 0
  property string loadedLyricsTrackId: ""
  property int activeLyricIndex: -1
  property bool userScrollingLyrics: false
  // The playhead Service publishes is a wall-clock extrapolation, so during
  // playback it advances in step with real time. A sample that disagrees with
  // that by more than a couple of seconds is a seek that did not announce
  // itself — one from MPRIS or another client — and `noteLyricsPlayhead` puts
  // the sheet back on the playing line for it too.
  property real lyricsPlayheadSample: -1
  property double lyricsPlayheadSampledAt: 0
  property real targetLyricsScrollY: -1
  // A seek lands the sheet on the new line at once, but the audio has not
  // started again yet: mpv refills the stream while the wall-clock playhead
  // already runs on from the drop point. `lyricSeekHoldPos` pins the sheet's
  // own playhead to the seek target so it waits on that line until the deck's
  // own clock proves playback resumed from there.
  property real lyricSeekHoldPos: -1
  property double lyricSeekHoldAt: 0
  property int lyricSeekSettledAt: 0
  // The line whose accent is fading in: the sheet only sets it when it is
  // about to glide to that line, and clears it the moment the glide ends. It
  // is written before the active line flips, so the gate in the delegates
  // never depends on the order those two changes are evaluated in — which is
  // what let a replaced line fade its accent out on a backwards seek.
  property int lyricFadeIndex: -1
  // Set while a lyric line's own tap is seeking to it, so the seek it causes
  // does not pre-empt the glide that tap is meant to show.
  property bool lyricTapSeek: false
  // Lyrics density. The delegate is exactly the text's own line box, so this
  // spacing is the whole gap between lyric lines and the active line gets no
  // extra vertical room of its own. Wrapped rows use a slightly tighter line
  // height so a lyric that runs onto a second row stays one block.
  readonly property real lyricLineSpacing: 9
  // The inner breathing room above the first lyric and below the last. Fixed
  // pixels so both ends match; the fade itself is the mask's 6 % ramp.
  readonly property real lyricEdgePad: 8

  // Keyboard cursor over the synced lyric sheet. It is separate from the
  // playing line: the cursor undims a line so it can be read and played with
  // Enter, and it disappears as soon as the pointer moves.
  property int lyricCursorIndex: -1
  property int hoveredLyricIndex: -1
  property bool lyricKeyboardNav: false
  property real lastPointerX: -10000
  property real lastPointerY: -10000
  readonly property bool lyricLinesReady: root.lyricsActive && !!(root.lyricsData
    && root.lyricsData.synced && root.lyricsData.lines && root.lyricsData.lines.length > 0)
    && !root.lyricsLoading

  // "Song - Artist", recorded as the Recently Played label for a track radio so
  // it reads as the song that spawned it instead of the generic "Mix" type. It
  // is deliberately not a face subtitle: the radio header already carries the
  // track count and duration, and the full label is too much text there.
  function trackRadioSubtitle() {
    if (!root.svc) return ""
    var credits = root.svc.displayTrack ? root.svc.displayTrack.artists : null
    return Format.trackRadioLabel(root.svc.title, credits, root.svc.artist)
  }

  // Track radio for the playing song; the `R` key and the song menu share it.
  function openRadio() {
    if (root.svc && root.svc.currentTrackId) {
      root.radioClicked(root.svc.currentTrackId, root.svc.artUrl, root.trackRadioSubtitle())
    }
  }

  function reloadLyrics() {
    var request = ++root.lyricsRequest
    root.resetCursor()
    root.userScrollingLyrics = false
    // A track change or a re-open is not a seek; start the playhead comparison
    // from a fresh sample rather than from the last track's position.
    root.lyricsPlayheadSample = -1
    root.lyricSeekHoldPos = -1
    lyricSeekHoldTimer.stop()
    if (!root.svc || !root.svc.currentTrackId) {
      root.loadedLyricsTrackId = ""
      root.lyricsLoading = false
      root.lyricsData = { synced: false, lines: [], plainText: "" }
      if (plainLyricsFlickable) plainLyricsFlickable.contentY = 0
      return
    }
    var tid = String(root.svc.currentTrackId)
    root.loadedLyricsTrackId = tid
    root.lyricsLoading = true
    root.svc.fetchLyrics(root.svc.currentTrackId, root.svc.title, root.svc.artist, root.svc.length, function(data) {
      if (!root || !root.alive || request !== root.lyricsRequest) return
      root.lyricsLoading = false
      // A cached answer is the same object the face already holds, so the data
      // change is a no-op; clearing the index first makes the snap below run
      // instead of leaving a re-opened sheet parked on the first line.
      root.activeLyricIndex = -1
      root.lyricsData = data || { synced: false, lines: [], plainText: "" }
      // A fresh sheet starts at the first line; updateActiveLyric then snaps
      // straight to the playing line if the track is already under way.
      lyricsListView.positionViewAtBeginning()
      if (plainLyricsFlickable) plainLyricsFlickable.contentY = 0
      root.updateActiveLyric(true)
    })
  }

  onVisibleChanged: {
    if (!root.visible || !root.lyricsActive) return
    var tid = (root.svc && root.svc.currentTrackId) ? String(root.svc.currentTrackId) : ""
    if (tid !== root.loadedLyricsTrackId) {
      root.reloadLyrics()
    } else {
      root.lyricsPlayheadSample = -1
      root.updateActiveLyric(true)
    }
  }

  onLyricsActiveChanged: {
    if (root.lyricsActive) {
      root.reloadLyrics()
    } else {
      root.resetCursor()
      root.userScrollingLyrics = false
      lyricsScrollAnimation.stop()
      root.targetLyricsScrollY = -1
      root.lyricFadeIndex = -1
      root.lyricSeekHoldPos = -1
      lyricSeekHoldTimer.stop()
      root.lyricsNotchState.accumulator = 0
      lyricsNotchTimer.stop()
    }
  }

  Connections {
    target: root.svc
    function onCurrentTrackIdChanged() {
      if (root.lyricsActive && root.visible) root.reloadLyrics()
    }
    function onPositionChanged() {
      if (root.lyricsActive && root.visible) root.noteLyricsPlayhead(root.svc ? root.svc.position : 0)
    }
    // A pause freezes the playhead while real time keeps running, so the
    // sample from before the pause must never be compared with the resume.
    function onPlayingChanged() {
      root.lyricsPlayheadSample = -1
      if (root.svc && !root.svc.playing) root.endLyricSeekHold()
    }
    // The exact seek event: no sampling, no threshold, no race with the
    // transport. Covers the seek bar, the , / . keys, the IPC and a lyric tap.
    function onSeekRevisionChanged() {
      if (!root.lyricsActive || !root.visible) return
      root.beginLyricSeekHold()
      root.recenterAfterSeek()
    }
  }

  // A seek is the one thing that always wins: whatever the sheet was doing —
  // scrolled away, keyboard cursor up — it snaps to the playing line and
  // follows again. The snap is instant rather than animated: seeking through a
  // track would otherwise leave the sheet in the air, always a line or two
  // behind a playhead that jumps in 10 s steps. A ui seek reaches here twice
  // in one tick (as the playhead jump and as the revision bump); the second
  // call writes the same instant position, so it costs nothing and rapid
  // seeks each land.
  function recenterAfterSeek() {
    // A tapped lyric starts its own animated glide to that line; the seek it
    // fires must not snap the sheet there first or there is nothing left to
    // animate.
    if (root.lyricTapSeek) return
    root.resetCursor()
    root.userScrollingLyrics = false
    root.targetLyricsScrollY = -1
    root.activeLyricIndex = -1
    root.updateActiveLyric(true)
    // A seek before the first line has nothing to centre on, so park the
    // sheet at its beginning instead of leaving it where it was scrolled.
    if (root.activeLyricIndex < 0) lyricsListView.positionViewAtBeginning()
  }

  // A seek lands the sheet on the new line immediately, but the audio has a
  // moment of refilling to do first: the wall-clock playhead runs on from the
  // drop point whether or not mpv is playing yet. Pinning the sheet's own
  // playhead to the seek target makes it wait on that line instead of strolling
  // ahead of the sound, and the deck's clock releases it once it is playing.
  function beginLyricSeekHold() {
    if (!root.svc) return
    root.lyricSeekHoldPos = Math.max(0, root.svc.position || 0)
    root.lyricSeekHoldAt = Date.now()
    root.lyricSeekSettledAt = root.svc.seekSettledRevision
    lyricSeekHoldTimer.restart()
  }

  // True only on evidence that playback resumed from the seek target: the
  // daemon answering the seek RPC means the deck has the new position (a
  // reloaded stream included), and the MPRIS playhead is mpv's own clock, so a
  // sample past the target proves it is running again rather than refilling.
  // Without either evidence fall back to a short wait, so a sheet is never
  // stranded mid-seek.
  function lyricPlaybackResumed() {
    var svc = root.svc
    var waited = Date.now() - root.lyricSeekHoldAt
    if (svc && svc.seekSettledRevision !== root.lyricSeekSettledAt) return true
    var player = svc ? svc.player : null
    if (!player || !player.positionSupported || (svc && svc.castActive)) return waited >= 900
    var actual = Number(player.position)
    if (isNaN(actual) || actual < 0) return waited >= 900
    return actual >= root.lyricSeekHoldPos + 0.2
  }

  function endLyricSeekHold() {
    if (root.lyricSeekHoldPos < 0) return
    root.lyricSeekHoldPos = -1
    lyricSeekHoldTimer.stop()
    // The playhead ran on while the sheet waited; take the next sample as the
    // start of normal playback rather than a jump worth recentring for.
    root.lyricsPlayheadSample = -1
    root.updateActiveLyric()
  }

  // Follow the playhead, and treat a jump as a seek: the sheet goes back to
  // the playing line even if the user had scrolled away (or a keyboard cursor
  // was up), and normal follow resumes from there. The threshold clears every
  // ordinary re-anchor Service makes — 1.5 s from MPRIS, 2.0 s from a status
  // snapshot, 0.35 s while casting — so only a real seek crosses it.
  function noteLyricsPlayhead(pos) {
    var now = Date.now()
    // Dragging the seek handle previews a playhead that is not playing yet, so
    // the bar must not move the sheet: it stays on the line it is on until the
    // handle is dropped and that seek lands (recenterAfterSeek). The sample is
    // dropped too, so the drop is not mistaken for a jump.
    if (root.svc && root.svc.isScrubbing) {
      root.lyricsPlayheadSample = -1
      return
    }
    // A seek in flight: the sheet waits on the line it landed on. Only the
    // deck's own clock, a pause, or the escape-hatch timer may release it.
    if (root.lyricSeekHoldPos >= 0) {
      if (!(root.svc && root.svc.playing) || root.lyricPlaybackResumed()) {
        root.endLyricSeekHold()
      }
      return
    }
    // A cast hand-off holds the playhead on purpose; that is not a seek.
    var held = root.svc && root.svc.castPlayheadHeld
    var playing = root.svc && root.svc.playing && !held
    var seeked = false
    var expected = 0
    if (!held && root.lyricsPlayheadSample >= 0) {
      // A playing playhead advances with the wall clock, so the jump is
      // measured against where it should be by now; a paused one only moves
      // when something seeks it.
      expected = playing
        ? root.lyricsPlayheadSample + (now - root.lyricsPlayheadSampledAt) / 1000
        : root.lyricsPlayheadSample
      seeked = Math.abs(pos - expected) > 2.5
    }
    root.lyricsPlayheadSample = held ? -1 : pos
    root.lyricsPlayheadSampledAt = now
    if (seeked) {
      root.lyricsPlayheadSample = -1
      root.recenterAfterSeek()
      return
    }
    root.updateActiveLyric()
  }

  // Follow the playhead. A line that arrives with the song glides so the eye
  // can track it; a seek or a fresh sheet snaps, because the sheet has to be
  // on the right line immediately and a glide would trail it.
  function updateActiveLyric(instant) {
    if (!lyricsData || !lyricsData.synced || !lyricsData.lines || lyricsData.lines.length === 0) {
      root.activeLyricIndex = -1
      return
    }
    var pos = root.svc ? root.svc.position : 0
    // A seek in flight: follow the line the sheet landed on, not the
    // extrapolated playhead that is still racing the refill.
    if (root.lyricSeekHoldPos >= 0) pos = root.lyricSeekHoldPos
    var lines = lyricsData.lines
    var found = -1
    for (var i = 0; i < lines.length; i++) {
      if (pos >= lines[i].time - 0.05) {
        found = i
      } else {
        break
      }
    }
    if (found !== root.activeLyricIndex) {
      var follow = !root.userScrollingLyrics && !root.lyricKeyboardNav && found >= 0 && !!lyricsListView
      if (follow && instant !== true) {
        // Travel first: the accent hand-over in the delegates is gated on the
        // follow glide, so it must already be running when the line states
        // flip, or the new line takes its accent with no transition.
        root.glideLyricTo(found)
        root.activeLyricIndex = found
      } else {
        // Settle the viewport before the states flip, so a snap stays a snap
        // even when it interrupts a glide that was still running.
        if (follow) root.centerLyric(found)
        root.activeLyricIndex = found
      }
    }
  }

  function lyricMinScrollY() {
    return lyricsListView.originY
  }

  // The origin can be an arbitrary positive value once wrapped delegate
  // heights change, so the real range is originY .. originY + contentHeight -
  // height. Using 0 .. contentHeight - height stopped every programmatic
  // scroll short of the bottom that a drag could still reach.
  function lyricMaxScrollY() {
    var view = lyricsListView
    return view.originY + Math.max(0, view.contentHeight - view.height)
  }

  // The scroll position that puts `index` in the middle, clamped to the real
  // content range: near the first and last lines the sheet stays flush with
  // the top/bottom instead of leaving blank space. `positionViewAtIndex` can
  // itself leave contentY outside that range, so it is only used to
  // materialise a row that is not realised yet, and the result is clamped.
  function lyricTargetFor(index) {
    var view = lyricsListView
    var item = view.itemAtIndex(index)
    if (!item) {
      view.positionViewAtIndex(index, ListView.Center)
      // Center can leave contentY outside the list (blank space above the
      // first rows or below the last), so pin it to the real range right away
      // rather than animating back from the overscroll.
      view.contentY = Math.max(root.lyricMinScrollY(), Math.min(root.lyricMaxScrollY(), view.contentY))
      item = view.itemAtIndex(index)
    }
    var minY = root.lyricMinScrollY()
    var maxY = root.lyricMaxScrollY()
    if (!item) return Math.max(minY, Math.min(maxY, view.contentY))
    return Math.max(minY, Math.min(maxY, item.y + item.height / 2 - view.height / 2))
  }

  // Put `index` in the middle at once. Nothing that follows the playhead
  // animates: a line change is a discrete step, and skipping or seeking can
  // jump several at a time, so a glide would only ever trail the real line.
  function centerLyric(index) {
    var target = root.lyricTargetFor(index)
    lyricsScrollAnimation.stop()
    root.targetLyricsScrollY = -1
    root.lyricFadeIndex = -1
    lyricsListView.contentY = target
  }

  // The one animated path: tapping a line travels to it, so the motion is
  // part of what the tap shows alongside the seek. `lyricFadeIndex` is up for
  // exactly this travel, which is what lets the arriving line cross-fade its
  // accent (and its brightness) over the same 260 ms. A line already in the
  // middle has nowhere to go: it settles at once, and the accent with it.
  function glideLyricTo(index) {
    var target = root.lyricTargetFor(index)
    lyricsScrollAnimation.stop()
    root.targetLyricsScrollY = target
    if (Math.abs(target - lyricsListView.contentY) < 0.5) {
      root.lyricFadeIndex = -1
      lyricsListView.contentY = target
      return
    }
    root.lyricFadeIndex = index
    lyricsScrollAnimation.target = lyricsListView
    lyricsScrollAnimation.from = lyricsListView.contentY
    lyricsScrollAnimation.to = target
    lyricsScrollAnimation.duration = 260
    lyricsScrollAnimation.easing.type = Easing.OutCubic
    lyricsScrollAnimation.start()
  }

  function scrollLyricsBy(view, delta, isPixelDelta) {
    if (!view) return
    root.userScrollingLyrics = true
    root.lyricFadeIndex = -1
    var minY = view.originY
    var maxY = minY + Math.max(0, view.contentHeight - view.height)

    if (isPixelDelta) {
      lyricsScrollAnimation.stop()
      root.targetLyricsScrollY = -1
      view.contentY = Math.max(minY, Math.min(maxY, view.contentY - delta))
      return
    }

    var base = (lyricsScrollAnimation.running && root.targetLyricsScrollY >= 0 && lyricsScrollAnimation.target === view)
      ? root.targetLyricsScrollY
      : view.contentY
    var newTarget = Math.max(minY, Math.min(maxY, base - delta))
    root.targetLyricsScrollY = newTarget

    lyricsScrollAnimation.stop()
    lyricsScrollAnimation.target = view
    lyricsScrollAnimation.from = view.contentY
    lyricsScrollAnimation.to = newTarget
    lyricsScrollAnimation.duration = 140
    lyricsScrollAnimation.easing.type = Easing.OutQuad
    lyricsScrollAnimation.start()
  }

  // Wheel scrolling for the lyrics surfaces: touchpad pixels track 1:1,
  // mouse notches become one step each (sub-notch units are summed, see
  // Wheel.js). The step scales with the system's wheel speed like the list
  // views do; at the default setting it is about three lyric lines.
  readonly property real lyricsNotchPx: Qt.styleHints.wheelScrollLines * 28
  property var lyricsNotchState: ({ accumulator: 0 })

  function handleLyricsWheel(event, view) {
    var angle = event.angleDelta.y
    var pixel = event.pixelDelta.y
    if (angle === 0 && pixel === 0) return
    root.endLyricKeyboardNav()

    // Same rule as SmoothScrollHandler: phases mean continuous touchpad
    // scrolling (track its pixels 1:1), no phase means whole mouse notches.
    var continuous = event.phase !== undefined && event.phase !== null
      && event.phase !== Qt.NoScrollPhase
    if (!continuous && angle === 0 && pixel !== 0) continuous = true

    if (continuous) {
      root.flushLyricsNotch()
      root.scrollLyricsBy(view, pixel !== 0 ? pixel : angle, true)
      event.accepted = true
      return
    }

    var notches = Wheel.accumulate(root.lyricsNotchState, angle)
    if (notches !== 0) {
      lyricsNotchTimer.stop()
      root.scrollLyricsBy(view, notches * root.lyricsNotchPx, false)
    } else {
      lyricsNotchTimer.restart()
    }
    event.accepted = true
  }

  function flushLyricsNotch() {
    lyricsNotchTimer.stop()
    var delta = Wheel.leftover(root.lyricsNotchState, root.lyricsNotchPx)
    if (delta === 0) return
    var view = lyricsListView.visible ? lyricsListView : plainLyricsFlickable
    root.scrollLyricsBy(view, delta, false)
  }

  Timer {
    id: lyricsNotchTimer
    interval: 180
    onTriggered: if (root.alive) root.flushLyricsNotch()
  }

  // ---- Keyboard ----------------------------------------------------------------

  readonly property bool overlayOpen: root.menuOpen || root.pickerOpen

  function overlayMove(delta) {
    if (root.pickerOpen) { playlistPicker.moveCursor(delta); return true }
    if (root.menuOpen) { songMenu.moveCursor(delta); return true }
    return false
  }

  function overlayActivate() {
    if (root.pickerOpen) { playlistPicker.activateCursor(); return true }
    if (root.menuOpen) { songMenu.activateCursor(); return true }
    return false
  }

  function overlayEscape() {
    if (root.pickerOpen) { root.pickerOpen = false; return true }
    if (root.menuOpen) { root.menuOpen = false; return true }
    return false
  }

  function lyricsScrollView() {
    if (!root.lyricsActive) return null
    return (root.lyricsData && root.lyricsData.synced) ? lyricsListView : plainLyricsFlickable
  }

  // Keyboard cursor over the synced lines. An arrow key puts the cursor on the
  // hovered line when the pointer is resting on one, otherwise beside the
  // playing line; the selected line undims, but nothing plays until Enter.
  function resetCursor() {
    root.lyricCursorIndex = -1
    root.hoveredLyricIndex = -1
    root.lyricKeyboardNav = false
  }

  function endLyricKeyboardNav() {
    root.lyricCursorIndex = -1
    root.lyricKeyboardNav = false
  }

  function beginLyricKeyboardNav() {
    root.lyricKeyboardNav = true
    // Stop any follow animation so a playing track cannot pull the viewport
    // away from the line the user is choosing. `lyricKeyboardNav` keeps
    // updateActiveLyric from starting a new one while the cursor is up.
    lyricsScrollAnimation.stop()
    root.targetLyricsScrollY = -1
    root.lyricFadeIndex = -1
  }

  function selectLyric(index) {
    root.lyricCursorIndex = index
    lyricsScrollAnimation.stop()
    root.targetLyricsScrollY = -1
    root.lyricFadeIndex = -1
    lyricsListView.contentY = root.lyricTargetFor(index)
  }

  function moveLyricCursor(dy) {
    var count = (root.lyricsData && root.lyricsData.lines) ? root.lyricsData.lines.length : 0
    if (count === 0 || dy === 0) return
    root.beginLyricKeyboardNav()
    if (root.lyricCursorIndex < 0) {
      var seed = root.hoveredLyricIndex >= 0 ? root.hoveredLyricIndex : root.activeLyricIndex
      if (seed < 0) {
        root.selectLyric(dy > 0 ? 0 : count - 1)
        return
      }
      root.lyricCursorIndex = seed
    }
    root.selectLyric(Math.max(0, Math.min(count - 1, root.lyricCursorIndex + dy)))
  }

  function playLyricAt(index, startPlayback) {
    var lines = root.lyricsData ? root.lyricsData.lines : null
    if (!root.svc || !lines || index < 0 || index >= lines.length) return
    var line = lines[index]
    if (!line || line.time === undefined) return
    root.resetCursor()
    root.userScrollingLyrics = false
    // Travel first, then mark the line: the accent hand-over rides the glide.
    root.glideLyricTo(index)
    root.activeLyricIndex = index
    root.lyricTapSeek = true
    root.svc.seek(line.time)
    root.lyricTapSeek = false
    if (startPlayback && !root.svc.playing) root.svc.play()
  }

  function activateCursor(shift) {
    if (!root.lyricKeyboardNav || root.lyricCursorIndex < 0) return
    root.playLyricAt(root.lyricCursorIndex, true)
  }

  function noteLyricPointerMotion() {
    if (!root.lyricKeyboardNav) return
    root.endLyricKeyboardNav()
  }

  HoverHandler {
    id: lyricPointerWatcher
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onPointChanged: {
      var p = point.position
      if (Math.abs(p.x - root.lastPointerX) > 0.5 || Math.abs(p.y - root.lastPointerY) > 0.5) {
        root.lastPointerX = p.x
        root.lastPointerY = p.y
        root.noteLyricPointerMotion()
      }
    }
  }

  function moveCursor(dx, dy) {
    if (dy === 0) return
    if (root.lyricLinesReady) {
      root.moveLyricCursor(dy)
      return
    }
    var view = root.lyricsScrollView()
    if (!view) return
    root.scrollLyricsBy(view, dy * -60, true)
  }

  function pageCursor(direction) {
    root.endLyricKeyboardNav()
    var view = root.lyricsScrollView()
    if (!view) return
    root.scrollLyricsBy(view, -direction * Math.max(40, Math.round(view.height * 0.8)), true)
  }

  function homeEndCursor(toEnd) {
    root.endLyricKeyboardNav()
    var view = root.lyricsScrollView()
    if (!view) return
    root.userScrollingLyrics = true
    lyricsScrollAnimation.stop()
    root.targetLyricsScrollY = -1
    root.lyricFadeIndex = -1
    if (view === lyricsListView) {
      // ListView positions the ends itself, including the arbitrary origin and
      // footer; computing contentY by hand is what stopped short of the last
      // row once the origin had moved.
      if (toEnd) view.positionViewAtEnd()
      else view.positionViewAtBeginning()
      return
    }
    view.contentY = toEnd ? Math.max(0, view.contentHeight - view.height) : 0
  }

  // Keep the sampled API color available for future use, but let the theme own
  // the lower player surface while the album art fades into it from above.
  Item {
    id: backgroundContainer
    anchors.fill: parent
    z: -1
    layer.enabled: true

    Rectangle {
      color: Color.popups.background
      anchors.fill: parent
    }

    Image {
      id: backgroundArtwork
      anchors.fill: parent
      source: root.svc ? root.svc.artUrl : ""
      fillMode: Image.PreserveAspectCrop
      sourceSize.width: 760
      sourceSize.height: 980
      asynchronous: true
      visible: false
      layer.enabled: true
      property string lastReadySource: ""
      onStatusChanged: {
        if (status === Image.Ready) lastReadySource = source
      }
      onSourceChanged: {
        if (source === "") lastReadySource = ""
      }
    }

    // Keep the last blurred backdrop on screen while the next cover loads;
    // otherwise every skip flashes the flat theme background.
    Image {
      id: previousBackgroundArtwork
      anchors.fill: parent
      source: backgroundArtwork.lastReadySource
      fillMode: Image.PreserveAspectCrop
      sourceSize.width: 760
      sourceSize.height: 980
      asynchronous: true
      visible: false
      layer.enabled: true
    }

    MultiEffect {
      id: previousBackgroundBlur
      anchors.fill: previousBackgroundArtwork
      source: previousBackgroundArtwork
      blurEnabled: true
      blurMax: 56
      blur: 0.88
      autoPaddingEnabled: false
      visible: backgroundArtwork.lastReadySource !== ""
        && backgroundArtwork.status !== Image.Ready
      opacity: root.lyricsActive ? 0.6 : 1.0

      Behavior on opacity {
        NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
      }
    }

    MultiEffect {
      id: backgroundBlur
      anchors.fill: backgroundArtwork
      source: backgroundArtwork
      blurEnabled: true
      blurMax: 56
      blur: 0.88
      autoPaddingEnabled: false
      visible: backgroundArtwork.status === Image.Ready
      // Keep the artwork behind the lyrics, but dim it so the text stays the
      // focus.
      opacity: root.lyricsActive ? 0.6 : 1.0

      Behavior on opacity {
        NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
      }
    }

    Rectangle {
      anchors.fill: parent
      gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.30) }
        GradientStop { position: 0.25; color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.46) }
        GradientStop { position: 0.45; color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.66) }
        GradientStop { position: 0.60; color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.84) }
        GradientStop { position: 0.70; color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.94) }
        GradientStop { position: 0.75; color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.99) }
        GradientStop { position: 0.78; color: Color.popups.background }
        GradientStop { position: 1.0; color: Color.popups.background }
      }
    }
  }

  NumberAnimation {
    id: lyricsScrollAnimation
    property: "contentY"
    duration: 260
    easing.type: Easing.OutCubic
    onFinished: {
      root.targetLyricsScrollY = -1
      root.lyricFadeIndex = -1
    }
  }

  // Escape hatch for a seek that never proves it resumed (a device that owns
  // the playhead, a player without a position): the sheet must not wait on a
  // line forever.
  Timer {
    id: lyricSeekHoldTimer
    interval: 2000
    onTriggered: if (root.alive) root.endLyricSeekHold()
  }

  // 2. Main Content Column Layout (topMargin 68 aligns artwork exactly 16px below 36px header buttons)
  ColumnLayout {
    anchors.fill: parent
    anchors.leftMargin: 16
    anchors.rightMargin: 16
    anchors.topMargin: 68
    anchors.bottomMargin: 16
    spacing: 12

    // Center Display Area: Album Art OR Clean Lyrics
    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.bottomMargin: 4

      // State A: Square Album Artwork Card
      Rectangle {
        id: artContainer
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width, parent.height)
        height: width
        radius: 2
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
        border.width: 1
        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
        visible: !root.lyricsActive

        AnimatedArtwork {
          id: artImg
          anchors.fill: parent
          radius: 2
          borderWidth: 1
          borderColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
          source: root.svc ? root.svc.artUrl : ""
          videoSource: root.svc ? String(root.svc.videoUrl || "") : ""
          active: root.videoActive && !root.lyricsActive
          playing: root.svc ? root.svc.playing : false
          sourceSize.width: 512
          sourceSize.height: 512
          visible: source !== "" || videoSource !== ""
        }

        TidalLogo {
          anchors.centerIn: parent
          size: 64
          color: root.foreground
          faint: true
          visible: !artImg.showingArtwork
        }
      }

      // State B: Clean Large Lyrics Display (matches lyrics.png)
      Item {
        id: lyricsContainer
        anchors.fill: parent
        // The edge mask needs a little room to dissolve into: let the sheet
        // run 7 px past the layout box on both sides, leaving ~8 px between
        // the lyrics and the header/track row.
        anchors.topMargin: -7
        anchors.bottomMargin: -7
        visible: root.lyricsActive
        // Dissolve the clipped top and bottom edges instead of cutting a lyric
        // in half where the sheet meets the header and the track row.
        layer.enabled: root.lyricsActive
        layer.effect: FadeVertical {}

        ListView {
          id: lyricsListView
          anchors.fill: parent
          clip: true
          model: (root.lyricsData && root.lyricsData.synced) ? root.lyricsData.lines : []
          spacing: root.lyricLineSpacing
          highlightMoveDuration: 250
          boundsBehavior: Flickable.StopAtBounds
          // Variable-height wrapped lines make ListView's lazy content height
          // an estimate that can be hundreds of pixels off, so wheel/End
          // targets land short of the real end. Realising the whole sheet up
          // front settles contentHeight; a lyric sheet is small enough that
          // the extra delegates are cheap.
          cacheBuffer: 20000
          // Matching header/footer pads: header and footer sit outside the
          // delegate list, so the list's spacing cannot make the bottom gap
          // larger than the top one.
          header: Item {
            width: lyricsListView.width
            height: root.lyricEdgePad
          }
          footer: Item {
            width: lyricsListView.width
            height: root.lyricEdgePad
          }
          visible: !!(root.lyricsData && root.lyricsData.synced && root.lyricsData.lines && root.lyricsData.lines.length > 0)
            && !root.lyricsLoading

          onMovementStarted: {
            root.endLyricKeyboardNav()
            root.userScrollingLyrics = true
            root.targetLyricsScrollY = -1
            root.lyricFadeIndex = -1
            lyricsScrollAnimation.stop()
          }

          WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: function(event) {
              root.handleLyricsWheel(event, lyricsListView)
            }
          }

          delegate: Item {
            id: lyricLineItem
            width: lyricsListView.width

            readonly property bool isCurrent: index === root.activeLyricIndex
            // Lines the song has already passed recede so the eye stays on the
            // live one; upcoming lines keep the reading-strength grey.
            readonly property bool isPast: root.activeLyricIndex >= 0 && index < root.activeLyricIndex
            // Keyboard selection undims its line; hover stays off while the
            // cursor is up, the same hand-off every list in the panel uses.
            readonly property bool hasCursor: root.lyricKeyboardNav && index === root.lyricCursorIndex
            readonly property bool hovered: lyricMa.containsMouse && !root.lyricKeyboardNav
            // The line arriving in the hand-over. Only a follow glide sets it,
            // and only while that glide runs: no other line in the sheet ever
            // fades, whether it is dimming because the song passed it or
            // because a seek skipped it. Gated on the index alone, never on
            // `isCurrent`, so a line losing the accent can never animate.
            readonly property bool handover: index === root.lyricFadeIndex

            height: lyricText.implicitHeight

            Text {
              textFormat: Text.PlainText
              id: lyricText
              width: parent.width
              text: modelData.text || ""
              font.family: root.fontFamily
              font.pixelSize: 18
              font.weight: isCurrent ? Font.Bold : Font.DemiBold
              wrapMode: Text.Wrap
              lineHeight: 0.95
              color: isCurrent ? Color.accent : root.foreground
              opacity: (isCurrent || hasCursor) ? 1.0 : (hovered ? 0.85 : (isPast ? 0.32 : 0.60))

              // The accent fades in, brightness included: the arriving line
              // turns accent as it brightens, over exactly the glide's 260 ms.
              // The line it replaces snaps back to plain text, as does every
              // other line in the sheet.
              Behavior on color {
                enabled: lyricLineItem.handover
                ColorAnimation {
                  duration: lyricsScrollAnimation.duration
                  easing.type: Easing.InOutQuad
                }
              }

              Behavior on opacity {
                enabled: lyricLineItem.handover
                NumberAnimation {
                  duration: lyricsScrollAnimation.duration
                  easing.type: Easing.InOutQuad
                }
              }
            }

            MouseArea {
              id: lyricMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.hoveredLyricIndex = index
              onExited: {
                if (root.hoveredLyricIndex === index) root.hoveredLyricIndex = -1
              }
              onClicked: root.playLyricAt(index, false)
            }
          }
        }

        // Plain Lyrics Fallback
        Flickable {
          id: plainLyricsFlickable
          anchors.fill: parent
          clip: true
          // Same top and bottom breathing room as the synced list: the block
          // can sit clear of both fades rather than ending underneath one.
          contentHeight: plainText.y + plainText.height + root.lyricEdgePad
          visible: !!(root.lyricsData && !root.lyricsData.synced && root.lyricsData.plainText)
            && !root.lyricsLoading
          onMovementStarted: {
            root.userScrollingLyrics = true
            root.targetLyricsScrollY = -1
            lyricsScrollAnimation.stop()
          }

          WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: function(event) {
              root.handleLyricsWheel(event, plainLyricsFlickable)
            }
          }

          Text {
            textFormat: Text.PlainText
            id: plainText
            width: parent.width
            y: root.lyricEdgePad
            text: (root.lyricsData && root.lyricsData.plainText) ? root.lyricsData.plainText : ""
            font.family: root.fontFamily
            font.pixelSize: 16
            lineHeight: 1.4
            wrapMode: Text.Wrap
            color: root.foreground
            opacity: 0.85
          }
        }

        // Loading placeholder: the logo pulses while the request is out, so the
        // face never flashes "No lyrics available" at a track it is still
        // asking about.
        Item {
          anchors.fill: parent
          visible: root.lyricsLoading

          TidalLogo {
            anchors.centerIn: parent
            size: 40
            color: root.foreground
            pulsing: root.lyricsLoading
          }
        }

        // No Lyrics Available Placeholder
        Item {
          anchors.fill: parent
          visible: !root.lyricsLoading
            && !(root.lyricsData && root.lyricsData.synced && root.lyricsData.lines && root.lyricsData.lines.length > 0)
            && !(root.lyricsData && root.lyricsData.plainText)

          Column {
            anchors.centerIn: parent
            spacing: 12

            TidalLogo {
              anchors.horizontalCenter: parent.horizontalCenter
              size: 40
              color: root.foreground
              faint: true
            }

            Text {
              textFormat: Text.PlainText
              text: "No lyrics available"
              font.family: root.fontFamily
              font.pixelSize: 13
              color: root.foreground
              opacity: 0.6
              anchors.horizontalCenter: parent.horizontalCenter
            }
          }
        }
      }
    }

    // 3. Track Details Row (Title, Artist, Lyrics + Heart Favorite buttons)
    RowLayout {
      Layout.fillWidth: true
      Layout.preferredHeight: 46
      spacing: 10

      Column {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        spacing: 2

        FadeText {
          textFormat: Text.PlainText
          width: parent.width
          text: root.svc && root.svc.title !== "" ? root.svc.title : "Not Playing"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: 16
          font.weight: Font.Bold
          maximumLineCount: 1
        }

        ArtistNames {
          width: parent.width
          artists: root.svc && root.svc.displayTrack ? root.svc.displayTrack.artists : []
          fallbackText: root.svc ? root.svc.artist : ""
          fallbackArtistId: root.svc ? root.svc.artistId : ""
          foreground: root.foreground
          textOpacity: 0.72
          fontFamily: root.fontFamily
          fontPixelSize: 12
          onArtistClicked: function(id, name) { root.artistSelected(id, name) }
        }
      }

      // Lyrics + Favourite buttons: the lyrics toggle sits left of the heart,
      // so they read as one cluster.
      Row {
        Layout.alignment: Qt.AlignVCenter
        spacing: 1
        // Icons are centred in 46 px hit areas. Bleed the row 12 px into the
        // page margin so the heart glyph itself ends on the seek rail's right
        // edge instead of 12 px inside it.
        Layout.rightMargin: -12

        // Lyrics Button (Circle only while lyrics are showing)
        Rectangle {
          width: 46
          height: 46
          radius: 23
          color: root.lyricsActive
            ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
            : "transparent"

          SvgIcon {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: 1
            size: 26
            color: root.foreground
            opacity: root.lyricsActive ? 1.0 : (lyricsMa.containsMouse ? 0.85 : 0.7)
            source: Qt.resolvedUrl("../../assets/icons/lyrics.svg")
          }

          MouseArea {
            id: lyricsMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.lyricsActive = !root.lyricsActive
          }

          ButtonToolTip {
            host: lyricsMa
            text: root.lyricsActive ? "Hide lyrics" : "Show lyrics"
            fontFamily: root.fontFamily
          }
        }

        // Heart Favorite Button (Empty / Filled)
        Rectangle {
          width: 46
          height: 46
          radius: 23
          color: "transparent"

          SvgIcon {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: 1
            size: 22
            color: root.foreground
            opacity: (root.svc && root.svc.favorite) ? 1.0 : (favMa.containsMouse ? 0.85 : 0.7)
            source: (root.svc && root.svc.favorite)
              ? Qt.resolvedUrl("../../assets/icons/heart-filled.svg")
              : Qt.resolvedUrl("../../assets/icons/heart.svg")
          }

          MouseArea {
            id: favMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (root.svc) root.svc.toggleFavorite()
            }
          }

          ButtonToolTip {
            host: favMa
            text: (root.svc && root.svc.favorite) ? "Remove from tracks" : "Add to tracks"
            fontFamily: root.fontFamily
          }
        }
      }
    }

    // 4. Full-Width Seek Bar
    SeekBar {
      Layout.fillWidth: true
      svc: root.svc
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    // 5. Main Transport Controls Row (Shuffle, Prev, Play/Pause, Next, Repeat)
    RowLayout {
      Layout.fillWidth: true
      Layout.leftMargin: 20
      Layout.rightMargin: 20
      Layout.preferredHeight: 52
      spacing: 0

      // Shuffle
      Item {
        Layout.fillWidth: true
        Layout.preferredHeight: 48

        Rectangle {
          anchors.centerIn: parent
          width: 48
          height: 48
          radius: 24
          color: shufMa.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12) : "transparent"

          SvgIcon {
            anchors.centerIn: parent
            size: 20
            color: root.foreground
            opacity: (root.svc && root.svc.shuffleEnabled) ? 1.0 : 0.45
            source: Qt.resolvedUrl("../../assets/icons/shuffle.svg")
          }

          MouseArea {
            id: shufMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.svc) root.svc.toggleShuffle()
          }

          ButtonToolTip {
            host: shufMa
            hideOnClick: false
            text: (root.svc && root.svc.shuffleEnabled) ? "Shuffle: On" : "Shuffle: Off"
            fontFamily: root.fontFamily
          }
        }
      }

      // Previous
      Item {
        Layout.fillWidth: true
        Layout.preferredHeight: 48

        Rectangle {
          anchors.centerIn: parent
          width: 48
          height: 48
          radius: 24
          color: prevMa.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12) : "transparent"

          SvgIcon {
            anchors.centerIn: parent
            size: 24
            color: root.foreground
            opacity: 0.95
            source: Qt.resolvedUrl("../../assets/icons/prev.svg")
          }

          MouseArea {
            id: prevMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.svc) root.svc.previous()
          }

          ButtonToolTip {
            host: prevMa
            text: "Previous"
            fontFamily: root.fontFamily
          }
        }
      }

      // Large Circular Play / Pause
      Item {
        Layout.fillWidth: true
        Layout.preferredHeight: 54

        Rectangle {
          anchors.centerIn: parent
          width: 54
          height: 54
          radius: 27
          color: playMa.containsMouse
            ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22)
            : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
          scale: playMa.pressed ? 0.96 : 1.0

          Behavior on scale { NumberAnimation { duration: 100 } }

          SvgIcon {
            anchors.centerIn: parent
            anchors.horizontalCenterOffset: root.svc && root.svc.playing ? 0 : -1
            size: 26
            color: root.foreground
            source: (root.svc && root.svc.playing)
              ? Qt.resolvedUrl("../../assets/icons/pause.svg")
              : Qt.resolvedUrl("../../assets/icons/play.svg")
          }

          MouseArea {
            id: playMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.svc) root.svc.playPause()
          }

          ButtonToolTip {
            id: playTip
            host: playMa
            text: root.playState ? "Pause" : "Play"
            fontFamily: root.fontFamily
          }
        }
      }

      // Next
      Item {
        Layout.fillWidth: true
        Layout.preferredHeight: 48

        Rectangle {
          anchors.centerIn: parent
          width: 48
          height: 48
          radius: 24
          color: nextMa.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12) : "transparent"

          SvgIcon {
            anchors.centerIn: parent
            size: 24
            color: root.foreground
            opacity: 0.95
            source: Qt.resolvedUrl("../../assets/icons/next.svg")
          }

          MouseArea {
            id: nextMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.svc) root.svc.next()
          }

          ButtonToolTip {
            host: nextMa
            text: "Next"
            fontFamily: root.fontFamily
          }
        }
      }

      // Repeat
      Item {
        Layout.fillWidth: true
        Layout.preferredHeight: 48

        Rectangle {
          anchors.centerIn: parent
          width: 48
          height: 48
          radius: 24
          color: repMa.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12) : "transparent"

          SvgIcon {
            anchors.centerIn: parent
            size: 20
            color: root.foreground
            opacity: (root.svc && root.svc.repeatMode !== "off") ? 1.0 : 0.45
            source: (root.svc && root.svc.repeatMode === "track")
              ? Qt.resolvedUrl("../../assets/icons/repeat-one.svg")
              : Qt.resolvedUrl("../../assets/icons/repeat.svg")
          }

          MouseArea {
            id: repMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.svc) root.svc.toggleRepeat()
          }

          ButtonToolTip {
            host: repMa
            hideOnClick: false
            text: (root.svc && root.svc.repeatMode === "track") ? "Repeat: One"
              : ((root.svc && root.svc.repeatMode === "all") ? "Repeat: All" : "Repeat: Off")
            fontFamily: root.fontFamily
          }
        }
      }
    }

    // 6. Footer Row: Queue, Playing from Context, Volume, More Actions (...)
    RowLayout {
      Layout.fillWidth: true
      Layout.preferredHeight: 36
      spacing: 8

      // Queue Button (Faint circular background matching playing 1.png)
      Rectangle {
        Layout.preferredWidth: 36
        Layout.preferredHeight: 36
        radius: 18
        color: queueMa.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)

        SvgIcon {
          anchors.centerIn: parent
          size: 18
          color: root.foreground
          source: Qt.resolvedUrl("../../assets/icons/queue.svg")
        }

        MouseArea {
          id: queueMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.queueClicked()
        }

        ButtonToolTip {
          host: queueMa
          text: "Queue"
          fontFamily: root.fontFamily
        }
      }

      // "Playing from" Context (Clickable)
      Item {
        id: playingFromCol
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredHeight: 36
        implicitHeight: 36
        clip: true
        opacity: ctxMa.containsMouse ? 0.8 : 1.0

        Behavior on opacity { NumberAnimation { duration: 120 } }

        Column {
          id: ctxColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 1

          Text {
            id: ctxLabel
            textFormat: Text.PlainText
            text: "Playing from"
            color: root.foreground
            opacity: 0.58
            font.family: root.fontFamily
            font.pixelSize: 9
            maximumLineCount: 1
          }

          FadeText {
            id: ctxText
            textFormat: Text.PlainText
            width: parent.width
            text: root.playingFrom
            color: root.foreground
            opacity: 0.92
            font.family: root.fontFamily
            font.pixelSize: 11
            font.weight: Font.DemiBold
            maximumLineCount: 1
          }
        }

        // Only the text block is a target; the free width the column fills
        // belongs to the row, not the link.
        MouseArea {
          id: ctxMa
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Math.min(parent.width, Math.max(ctxLabel.implicitWidth, ctxText.implicitWidth))
          height: ctxColumn.implicitHeight
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            var ctx = (root.svc && root.svc.currentContext && root.svc.currentContext.title)
              ? root.svc.currentContext
              : null
            root.contextClicked(ctx)
          }
        }
      }

      // Volume: the share button's slot, grown on hover into a level bar. The
      // pill's right edge stays put (the speaker is right-anchored), so it
      // expands leftwards until its far end reaches the panel's halfway mark.
      VolumeControl {
        svc: root.svc
        foreground: root.foreground
        fontFamily: root.fontFamily
        expandedWidth: Math.max(36, Math.round(root.width * 0.5) - 60)
        Layout.alignment: Qt.AlignVCenter
      }

      // More Actions Button (...) (Faint circular background)
      Rectangle {
        Layout.preferredWidth: 36
        Layout.preferredHeight: 36
        radius: 18
        color: moreMa.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)

        SvgIcon {
          anchors.centerIn: parent
          size: 18
          color: root.foreground
          opacity: 0.85
          source: Qt.resolvedUrl("../../assets/icons/more-vertical.svg")
        }

        MouseArea {
          id: moreMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.menuRequested()
        }

        ButtonToolTip {
          host: moreMa
          text: "More"
          fontFamily: root.fontFamily
        }
      }
    }
  }

  // 7. Song Action Menu Bottom Sheet Overlay (...)
  SongMenu {
    id: songMenu
    // Reparented above the header by MiniPlayer (see overlayHost there).
    parent: root.overlayHost ? root.overlayHost : root
    anchors.fill: parent
    svc: root.svc
    foreground: root.foreground
    fontFamily: root.fontFamily
    open: root.menuOpen

    onCloseRequested: root.menuOpen = false
    onAddToPlaylistRequested: {
      // One sheet at a time: the picker replaces the menu it came from.
      root.menuOpen = false
      root.pickerOpen = true
    }
    onRemoveFromPlaylistRequested: {
      if (root.svc) {
        root.svc.removeCurrentFromPlaylist(function(ok) {
          if (!root || !root.alive) return
          // The row is a tick until the daemon answers; roll it back to
          // "Remove from …" when the removal failed so it can be retried.
          if (!ok) songMenu.revertRemove()
        })
      }
    }
    onShareRequested: {
      root.shareClicked()
    }
    onFavoriteToggled: {
      if (root.svc) root.svc.toggleFavorite()
    }
    onPlayNextRequested: {
      if (root.svc && root.svc.apiTrack) {
        root.svc.playNext(root.svc.apiTrack)
      }
    }
    onTrackRadioRequested: root.openRadio()
    onGoToAlbumRequested: {
      if (root.svc && (root.svc.albumId || root.svc.album)) {
        root.albumClicked(root.svc.albumId || "", root.svc.album, root.svc.artUrl)
      }
    }
    onGoToArtistRequested: {
      root.artistClicked()
    }
  }

  // 8. Add-to-playlist sheet (opened from the action menu)
  PlaylistPicker {
    id: playlistPicker
    // Reparented above the header by MiniPlayer (see overlayHost there).
    parent: root.overlayHost ? root.overlayHost : root
    anchors.fill: parent
    svc: root.svc
    foreground: root.foreground
    fontFamily: root.fontFamily
    open: root.pickerOpen
    trackIds: (root.svc && root.svc.currentTrackId) ? [String(root.svc.currentTrackId)] : []
    onCloseRequested: root.pickerOpen = false
  }
}
