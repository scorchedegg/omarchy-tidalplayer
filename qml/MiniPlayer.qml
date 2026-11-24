import QtQuick
import qs.Commons
import "components"
import "views"

Item {
  id: root

  property bool alive: true
  Component.onDestruction: {
    root.alive = false
    sheetResetTimer.stop()
    idleResetTimer.stop()
    castLookupTimer.stop()
  }

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  // Animated album artwork only plays while the popup is open and the
  // now-playing face is on screen (including its fade-out).
  property bool videoActive: true

  readonly property bool hasTrack: svc ? (svc.title !== "" || svc.playing) : false
  readonly property bool playing: svc ? svc.playing : false
  // A start the user asked for from the offline page keeps that page: its
  // button reports progress in place instead of the panel swapping pages
  // underneath the click.
  readonly property bool daemonManualStarting: svc ? (svc.daemonState === "starting" && svc.daemonStartManual === true) : false
  readonly property bool daemonDown: svc ? (svc.daemonState === "down" || root.daemonManualStarting) : false
  readonly property bool daemonStarting: svc ? (svc.daemonState === "starting" && !root.daemonManualStarting) : false
  readonly property bool daemonBlocked: daemonDown || daemonStarting

  // Navigation state: "nowPlaying", "collections", "collectionList", "search", "queue", "playlist", "artist", "topTracks", "releases", "keybinds", "login"
  property string currentFace: hasTrack ? "nowPlaying" : "collections"
  property var viewStack: []
  // Forward history: entries popped off viewStack by a back step, returned
  // by a forward step. New navigation (push/set) starts a fresh branch.
  property var forwardStack: []
  property var viewParams: ({})
  property var playlistParams: ({})
  property var artistParams: ({})
  property var topTracksParams: ({})
  property var releasesParams: ({ filter: "popular" })
  property var collectionListParams: ({ listType: "playlists", title: "Playlists" })

  // Entity context menu (playlist and artist More buttons) and the artist
  // biography sheet. Both live here so they can cover the header.
  property bool menuOpen: false
  property var menuItems: []
  property var menuHeader: null
  property string menuOwner: ""
  property bool bioOpen: false
  property string bioTitle: ""
  property string bioText: ""
  // Cast device sheet, opened from the header button.
  property bool castOpen: false

  // True while the bar popup is open (wired from BarWidget); drives the
  // on-open focus choice.
  property bool panelOpen: false
  // The panel returns to its default face after being closed this long, so a
  // quick reopen keeps the page you were on but an idle one starts fresh.
  readonly property int resetAfterClosedMs: 15000

  onPanelOpenChanged: {
    if (!root.panelOpen) {
      // Clear sheets and perform the idle reset while the panel is closed,
      // never mid-fade on open: anything changing state during KeyboardPanel's
      // open fade plays a second transition inside the panel's fade.
      sheetResetTimer.restart()
      idleResetTimer.restart()
      return
    }
    sheetResetTimer.stop()
    idleResetTimer.stop()
    // First run (or a shell restart before login): land on the login face
    // instead of an empty collections page.
    root.syncLoginFace()
    // Cast discovery is on-demand: a sweep when the panel opens, plus the
    // explicit Refresh row in the sheet.
    if (root.svc) root.svc.refreshCastDevices(true)
    Qt.callLater(function() {
      if (!root || !root.alive || !root.panelOpen) return
      if (root.currentFace === "search") header.focusSearch()
      else if (root.currentFace === "collectionList") colListView.focusFilter()
      else root.focusKeyboard()
    })
  }

  readonly property var activeFocusItem: Window.activeFocusItem
  // A sheet or dialog owns the keyboard: MiniPlayer's Escape shortcut stands
  // down and the sheet's own Shortcut closes it.
  readonly property bool overlayOpen: root.menuOpen || root.bioOpen || root.castOpen
    || npView.overlayOpen || playlistView.overlayOpen
  // Mirrors the header's back button: collections is root when idle.
  readonly property bool backAvailable: root.currentFace !== "nowPlaying"
    && root.currentFace !== "login"
    && !(root.currentFace === "collections" && !root.hasTrack)
  readonly property bool forwardAvailable: root.forwardStack.length > 0

  signal closeRequested()
  signal tabRequested(int direction)

  // Whenever the focused editor goes away (dialog closed, filter hidden),
  // give the keyboard back to the catcher so panel keys keep working.
  onActiveFocusItemChanged: root.ensureKeyboardFocus()

  function ensureKeyboardFocus() {
    if (!root.panelOpen) return
    var item = root.activeFocusItem
    if (item && item !== keyCatcher && item.visible !== false) return
    if (!keyCatcher || !keyCatcher.enabled || !keyCatcher.visible) return
    Qt.callLater(function() {
      if (!root || !root.alive || !root.panelOpen) return
      if (keyCatcher && keyCatcher.enabled && keyCatcher.visible && !keyCatcher.activeFocus) keyCatcher.forceActiveFocus()
    })
  }

  function focusKeyboard() {
    if (keyCatcher) keyCatcher.forceActiveFocus()
  }

  // A fresh install has no session yet: open the login face rather than an
  // empty collection list. Runs only while the daemon is up.
  function syncLoginFace() {
    if (!root.svc || !root.svc.daemonRunning || !root.svc.statusLoaded) return
    if (!root.svc.loggedIn && root.currentFace !== "login") {
      root.currentFace = "login"
    } else if (root.svc.loggedIn && root.currentFace === "login") {
      root.currentFace = "nowPlaying"
    }
  }

  function openEntityMenu(owner) {
    var view = owner === "artist" ? artistView : playlistView
    if (!view || typeof view.entityMenuItems !== "function") return
    root.menuItems = view.entityMenuItems()
    root.menuHeader = view.entityMenuHeader()
    root.menuOwner = owner
    root.openSheet("entity")
  }

  function runEntityMenuAction(action) {
    var owner = root.menuOwner
    root.menuOpen = false
    if (owner === "artist") artistView.handleMenuAction(action)
    else if (owner === "playlist") playlistView.handleMenuAction(action)
  }

  implicitWidth: Style.space(380)
  implicitHeight: Style.space(620)

  // Pre-composite the entire panel into one texture before KeyboardPanel's
  // open/close fade touches it. That fade is an opacity on the whole card, and
  // it alpha-blends every item beneath it separately: at alpha 0.5 an opaque
  // item stops hiding what is behind it, so the page bled through the docked
  // player's glass and, worse, through the offline page — the overlay faded in
  // and out on top of a still-visible view, which read as two transitions.
  // Flattened here, the fade applies once to the finished panel image: every
  // element stays static inside it, every z relationship holds at every alpha,
  // and nothing can show through anything else mid-fade. Do not add a painting
  // item outside this layer; only non-visual handlers (TapHandler, KeyCatcher,
  // Shortcut) belong outside. Same pattern as the view backdrops.
  layer.enabled: true

  // Fresh navigation into a face resets its scroll position and cursor.
  // Back-navigation never resets — the view keeps whatever state the user
  // left it in.
  function resetFaceState(face) {
    if (face === "collections") { colView.scrollToTop(); colView.resetCursor() }
    else if (face === "collectionList") { colListView.scrollToTop(); colListView.resetCursor() }
    else if (face === "search") { searchView.scrollToTop(); searchView.resetCursor() }
    else if (face === "queue") { queueView.prepareFreshEntry(); queueView.resetCursor() }
    else if (face === "playlist") { playlistView.scrollToTop(); playlistView.resetCursor() }
    else if (face === "artist") { artistView.scrollToTop(); artistView.resetCursor() }
    else if (face === "topTracks") { topTracksView.scrollToTop(); topTracksView.resetCursor() }
    else if (face === "releases") { releasesView.scrollToTop(); releasesView.resetFilter() }
    else if (face === "nowPlaying") { npView.resetCursor() }
    else if (face === "keybinds") { keybindsView.scrollToTop() }
  }

  // Every bottom sheet and dialog, wherever it lives, closed at once.
  function closeSheets() {
    root.menuOpen = false
    root.bioOpen = false
    root.castOpen = false
    if (npView) {
      npView.menuOpen = false
      npView.pickerOpen = false
    }
    if (playlistView && playlistView.closeOverlays) playlistView.closeOverlays()
  }

  // Only one sheet is up at a time: opening one closes whatever was already
  // open, so a sheet opened with the keyboard cannot stack a second scrim over
  // the first. `name` is "entity" (the shared context menu), "bio", "cast",
  // "song" (the track menu) or "picker" (add to playlist).
  function openSheet(name) {
    root.closeSheets()
    if (name === "entity") root.menuOpen = true
    else if (name === "bio") root.bioOpen = true
    else if (name === "cast") root.castOpen = true
    else if (name === "song" && npView) npView.menuOpen = true
    else if (name === "picker" && npView) npView.pickerOpen = true
  }

  // Runs after the pane's close fade (120 ms) plus the panel's own (180 ms),
  // so the sheets disappear while nothing is on screen. Left open, they would
  // still be showing when the pane next fades in and play a second fade inside
  // it.
  Timer {
    id: sheetResetTimer
    interval: 320
    onTriggered: {
      if (root.alive && !root.panelOpen) root.closeSheets()
    }
  }

  // Resets idle navigation while hidden so reopening never cross-fades faces
  // inside KeyboardPanel's open fade.
  Timer {
    id: idleResetTimer
    interval: root.resetAfterClosedMs
    onTriggered: {
      if (root.alive && !root.panelOpen) root.resetToDefault()
    }
  }

  // The daemon re-probes each known device's Cast port on every list request.
  // While the panel is open, poll that list so a device that drops off is
  // dimmed as Unavailable and then removed after the daemon's minute-long
  // grace, instead of waiting for the next panel open.
  Timer {
    id: castLookupTimer
    interval: 10000
    repeat: true
    running: root.panelOpen && root.svc !== null
    onTriggered: {
      if (root.alive && root.svc && !root.svc.castLoading) root.svc.refreshCastDevices(false, null, true)
    }
  }

  // Drop transient navigation when the panel has been closed for a while.
  // The default face is the now-playing page, or collections when idle.
  // Lyrics are a mode, not navigation: enabled lyrics stay enabled until the
  // user turns them off, so an idle reset must not clear them.
  function resetToDefault() {
    root.closeSheets()
    root.viewStack = []
    root.forwardStack = []
    root.viewParams = ({})
    root.playlistParams = ({})
    root.artistParams = ({})
    root.topTracksParams = ({})
    root.releasesParams = ({ filter: "popular" })
    root.collectionListParams = ({ listType: "playlists", title: "Playlists" })
    root.currentFace = root.hasTrack ? "nowPlaying" : "collections"
    root.resetFaceState(root.currentFace)
  }

  function pushFace(face, params) {
    if (face === "lyrics") {
      root.pushFace("nowPlaying", params || {})
      npView.lyricsActive = true
      return
    }
    var nextParams = params || {}
    var stack = root.viewStack.slice()
    stack.push({ face: root.currentFace, params: root.viewParams })
    root.viewStack = stack
    root.forwardStack = []
    root.viewParams = nextParams
    if (face === "playlist") root.playlistParams = nextParams
    if (face === "artist") root.artistParams = nextParams
    if (face === "topTracks") root.topTracksParams = nextParams
    if (face === "releases") root.releasesParams = nextParams
    if (face === "collectionList") root.collectionListParams = nextParams
    // Opening search starts from the requested query (the button passes an
    // empty one); popping back into search must keep the results.
    if (face === "search") header.setSearchQuery(nextParams.query || "")
    var prevFace = root.currentFace
    root.resetFaceState(face)
    root.currentFace = face
    if (face === "search") header.animateSearchIn()
    if (face === "collectionList" && prevFace === "collectionList") {
      Qt.callLater(function() { if (root && root.alive && colListView) colListView.focusFilter() })
    }
  }

  // Restore a stored {face, params} entry without touching the target view's
  // scroll position or cursor: back and forward return to a view as the user
  // left it.
  function restoreFace(entry) {
    var prevFace = root.currentFace
    root.viewParams = entry.params || {}
    if (entry.face === "playlist") root.playlistParams = root.viewParams
    if (entry.face === "artist") root.artistParams = root.viewParams
    if (entry.face === "topTracks") root.topTracksParams = root.viewParams
    if (entry.face === "releases") root.releasesParams = root.viewParams
    if (entry.face === "collectionList") root.collectionListParams = root.viewParams
    root.currentFace = entry.face
    if (entry.face === "search") header.showSearchNow()
    if (entry.face === "collectionList" && prevFace === "collectionList") {
      Qt.callLater(function() { if (root && root.alive && colListView) colListView.focusFilter() })
    }
  }

  function popFace() {
    if (root.viewStack.length > 0) {
      var stack = root.viewStack.slice()
      var prev = stack.pop()
      root.viewStack = stack
      // Remember the face we are leaving so a forward step can return to it.
      root.forwardStack = root.forwardStack.concat(
        [{ face: root.currentFace, params: root.viewParams }])
      root.restoreFace(prev)
    } else {
      root.currentFace = root.hasTrack ? "nowPlaying" : "collections"
    }
  }

  function forwardFace() {
    if (root.forwardStack.length === 0) return
    var fwd = root.forwardStack.slice()
    var next = fwd.pop()
    root.forwardStack = fwd
    var stack = root.viewStack.slice()
    stack.push({ face: root.currentFace, params: root.viewParams })
    root.viewStack = stack
    root.restoreFace(next)
  }

  // `lyrics` is sugar for now playing with lyrics on. Moving between faces
  // leaves the lyrics mode alone: it stays on until the user turns it off.
  function setFace(face, params) {
    if (face === "lyrics") {
      root.viewParams = params || {}
      root.currentFace = "nowPlaying"
      npView.lyricsActive = true
      return
    }
    var prevFace = root.currentFace
    root.forwardStack = []
    root.viewParams = params || {}
    if (face === "playlist") root.playlistParams = root.viewParams
    if (face === "artist") root.artistParams = root.viewParams
    if (face === "topTracks") root.topTracksParams = root.viewParams
    if (face === "releases") root.releasesParams = root.viewParams
    if (face === "collectionList") root.collectionListParams = root.viewParams
    if (face === "search") header.setSearchQuery(root.viewParams.query || "")
    root.resetFaceState(face)
    root.currentFace = face
    if (face === "search") header.animateSearchIn()
    if (face === "collectionList" && prevFace === "collectionList") {
      Qt.callLater(function() { if (root && root.alive && colListView) colListView.focusFilter() })
    }
  }

  // ---- Keyboard commands ----------------------------------------------------

  // Route a cursor command to the active face's view. Views that do not
  // support the command simply do not define it.
  function faceCommand(command, args) {
    var view = null
    if (root.currentFace === "nowPlaying") view = npView
    else if (root.currentFace === "queue") view = queueView
    else if (root.currentFace === "playlist") view = playlistView
    else if (root.currentFace === "artist") view = artistView
    else if (root.currentFace === "topTracks") view = topTracksView
    else if (root.currentFace === "releases") view = releasesView
    else if (root.currentFace === "collectionList") view = colListView
    else if (root.currentFace === "search") view = searchView
    else if (root.currentFace === "collections") view = colView
    if (!view || typeof view[command] !== "function") return
    view[command].apply(view, args || [])
  }

  function handleMove(dx, dy, shift) {
    var delta = dy !== 0 ? dy : dx
    if (root.menuOpen) { contextMenu.moveCursor(delta); return }
    if (root.castOpen) { castSheet.moveCursor(delta); return }
    if (root.bioOpen) { bioSheet.scrollBy(delta); return }
    if (root.currentFace === "keybinds") { keybindsView.scrollBy(delta); return }
    if (npView.overlayMove(delta)) return
    if (playlistView.overlayMove(delta)) return
    // `shift` rides along for list views that move the row with the cursor
    // (playlist edit mode); the other views ignore the extra argument.
    root.faceCommand("moveCursor", [dx, dy, shift === true])
  }

  // Del removes the keyboard-cursor row where rows can be removed: the
  // playlist page in edit mode.
  function handleDelete() {
    if (root.currentFace === "playlist") playlistView.deleteCursorRow()
  }

  function handleActivate(shift) {
    if (root.menuOpen) { contextMenu.activateCursor(); return }
    if (root.castOpen) { castSheet.activateCursor(); return }
    if (root.bioOpen || root.currentFace === "keybinds") return
    if (npView.overlayActivate()) return
    if (playlistView.overlayActivate()) return
    root.faceCommand("activateCursor", [shift])
  }

  function handlePage(direction) {
    if (root.bioOpen) { bioSheet.pageBy(direction); return }
    if (root.currentFace === "keybinds") { keybindsView.pageBy(direction); return }
    if (root.overlayOpen) return
    root.faceCommand("pageCursor", [direction])
  }

  function handleHomeEnd(toEnd) {
    if (root.bioOpen) { bioSheet.homeEnd(toEnd); return }
    if (root.currentFace === "keybinds") { keybindsView.homeEnd(toEnd); return }
    if (root.overlayOpen) return
    root.faceCommand("homeEndCursor", [toEnd])
  }

  function toggleCollections() {
    if (root.currentFace === "collections") {
      if (root.hasTrack) root.setFace("nowPlaying", {})
    } else {
      root.pushFace("collections", {})
    }
  }

  function toggleLyrics() {
    if (root.currentFace === "nowPlaying") {
      npView.lyricsActive = !npView.lyricsActive
    } else {
      root.pushFace("lyrics", {})
    }
  }

  function openTrackMenu() {
    if (root.currentFace === "nowPlaying") {
      if (root.hasTrack) root.openSheet("song")
    } else if (root.currentFace === "artist") {
      root.openEntityMenu("artist")
    } else if (root.currentFace === "playlist" && root.playlistParams.itemType === "playlist") {
      root.openEntityMenu("playlist")
    }
  }

  // `a` adds / follows, `A` removes / unfollows. The RPCs are
  // toggles, so each key only fires when the state says it has something to do.
  function handleAdd() {
    if (root.currentFace === "nowPlaying") {
      if (root.svc && !root.svc.favorite) root.svc.toggleFavorite()
    } else if (root.currentFace === "artist") {
      if (!artistView.following) artistView.toggleFollow()
    } else if (root.currentFace === "playlist") {
      if (!playlistView.entityFavorite) playlistView.toggleEntityFavorite()
    }
  }

  function handleRemove() {
    if (root.currentFace === "nowPlaying") {
      if (root.svc && root.svc.favorite) root.svc.toggleFavorite()
    } else if (root.currentFace === "artist") {
      if (artistView.following) artistView.toggleFollow()
    } else if (root.currentFace === "playlist") {
      if (playlistView.entityFavorite) playlistView.toggleEntityFavorite()
    }
  }

  function handleShare() {
    if (root.currentFace === "nowPlaying") {
      if (root.svc && root.svc.currentTrackId) root.svc.shareTrack(root.svc.currentTrackId)
    } else if (root.currentFace === "artist") {
      artistView.shareArtist()
    } else if (root.currentFace === "playlist") {
      playlistView.shareEntity()
    }
  }

  function handleEdit() {
    if (root.currentFace === "playlist" && playlistView.canManage) playlistView.openEdit()
  }

  // `R` goes to radio: track radio from the now-playing view (the default view
  // for the current track), artist radio on an artist page.
  function handleRadio() {
    if (root.currentFace === "artist") artistView.openRadio()
    else if (root.currentFace === "nowPlaying") npView.openRadio()
  }

  // Open the album/artist/top-tracks/playlist/mix a queue was started from.
  // Shared by the now-playing footer link and the queue's "Playing from" bar.
  function openContext(ctx) {
    if (!ctx || (!ctx.id && !ctx.type)) {
      if (root.svc && root.svc.currentContext && (root.svc.currentContext.id || root.svc.currentContext.type)) {
        ctx = root.svc.currentContext
      } else if (root.svc && root.svc.albumId) {
        root.pushFace("playlist", { playlistId: root.svc.albumId, itemType: "album", title: root.svc.album, artUrl: root.svc.artUrl })
        return
      } else {
        root.pushFace("collections", {})
        return
      }
    }
    if (ctx.type === "album") {
      root.pushFace("playlist", { playlistId: ctx.id, itemType: "album", title: ctx.title, artUrl: ctx.artUrl })
    } else if (ctx.type === "artist") {
      root.pushFace("artist", { artistId: ctx.id, name: ctx.title, artUrl: ctx.artUrl })
    } else if (ctx.type === "artistTopTracks") {
      root.pushFace("topTracks", { artistId: ctx.id, name: ctx.title, artUrl: ctx.artUrl })
    } else if (ctx.type === "artistRadio") {
      root.pushFace("playlist", { playlistId: ctx.id, itemType: "artistRadio", title: ctx.title, subtitle: ctx.subtitle || "", artUrl: ctx.artUrl })
    } else if (ctx.type === "mix") {
      // The context carries the recently-played label ("Song - Artist" for a
      // track radio); keep it for the recent card, out of the page header.
      root.pushFace("playlist", { playlistId: ctx.id, itemType: "mix", title: ctx.title, recentSubtitle: ctx.subtitle || "", artUrl: ctx.artUrl })
    } else if (ctx.type === "favorites") {
      root.pushFace("playlist", { playlistId: "favorites", itemType: "favorites", title: "Tracks", subtitle: "", artUrl: "" })
    } else if (ctx.type === "playlist") {
      root.pushFace("playlist", { playlistId: ctx.id, itemType: "playlist", title: ctx.title, artUrl: ctx.artUrl })
    } else {
      root.pushFace("collections", {})
    }
  }

  function nudgeVolume(direction) {
    if (!root.svc) return
    root.svc.stepVolume(direction)
  }

  // Esc ladder: close the top sheet first, then a back step, then the panel.
  function handleEscape() {
    if (root.daemonBlocked) { root.closeRequested(); return }
    if (root.menuOpen) { root.menuOpen = false; root.focusKeyboard(); return }
    if (root.castOpen) { root.castOpen = false; root.focusKeyboard(); return }
    if (root.bioOpen) { root.bioOpen = false; root.focusKeyboard(); return }
    if (npView.overlayEscape()) { root.focusKeyboard(); return }
    if (playlistView.overlayEscape()) { root.focusKeyboard(); return }
    if (root.backAvailable) { root.popFace(); root.focusKeyboard(); return }
    root.closeRequested()
  }

  // Backspace: one back step, never closes the panel.
  function handleBack() {
    if (root.backAvailable) root.popFace()
  }

  // Shift+Backspace and the mouse forward button: one forward step.
  function handleForward() {
    if (root.forwardAvailable) root.forwardFace()
  }

  // IPC entry point (Service forwards `omarchy shell tidalplayer back`).
  function back() {
    root.handleBack()
  }

  // IPC entry point (Service forwards `omarchy shell tidalplayer forward`).
  function forward() {
    root.handleForward()
  }

  function handleTextKey(text) {
    if (root.currentFace === "login") {
      if (text === "c" || text === "C") loginView.copyLoginUrl()
      else if (text === "o" || text === "O") loginView.openBrowser()
      return
    }
    if (text === "?") {
      if (root.overlayOpen) return
      if (root.currentFace === "keybinds") root.popFace()
      else root.pushFace("keybinds", {})
      return
    }
    // `c` opens and closes the cast sheet, so it runs before the overlay guard
    // and stands down while any other sheet owns the keyboard.
    if (text === "c" || text === "C") {
      if (root.castOpen) { root.castOpen = false; root.focusKeyboard(); return }
      if (root.overlayOpen) return
      root.openSheet("cast")
      return
    }
    if (root.overlayOpen) return
    if (text === "/") {
      if (root.currentFace !== "search") root.pushFace("search", { query: "" })
      return
    }
    if (text === "m") { root.toggleCollections(); return }
    if (text === "M") { root.openTrackMenu(); return }
    if (text === "q" || text === "Q") {
      if (root.currentFace === "queue") root.popFace()
      else root.pushFace("queue", {})
      return
    }
    if (text === "y" || text === "Y") { root.toggleLyrics(); return }
    if (text === "a") { root.handleAdd(); return }
    if (text === "A") { root.handleRemove(); return }
    if (text === "S") { root.handleShare(); return }
    if (text === "e" || text === "E") { root.handleEdit(); return }
    if (text === "R") { root.handleRadio(); return }
    if (!root.svc) return
    if (text === "s") { root.svc.toggleShuffle(); return }
    if (text === "r") { root.svc.toggleRepeat(); return }
    if (text === "<") { root.svc.previous(); return }
    if (text === ">") { root.svc.next(); return }
    if (text === ",") { root.svc.seekBy(-10); return }
    if (text === ".") { root.svc.seekBy(10); return }
    if (text === "-" || text === "_") { root.nudgeVolume(-1); return }
    if (text === "=" || text === "+") { root.nudgeVolume(1); return }
  }

  // Auto-redirect to login if not logged in and no track is active
  onCurrentFaceChanged: {
    root.closeSheets()
    if (root.currentFace === "nowPlaying" && root.svc && root.svc.statusLoaded && !root.svc.loggedIn && !root.hasTrack && root.svc.daemonRunning) {
      root.currentFace = "login"
    }
    if (root.currentFace === "collectionList") {
      Qt.callLater(function() { if (root && root.alive && colListView) colListView.focusFilter() })
    } else if (root.currentFace !== "search") {
      // Mouse navigation does not move focus, so a stale editor from the
      // previous face could keep (and swallow) the keyboard. Seat it on the
      // catcher; search re-focuses its field through PlayerHeader.
      Qt.callLater(function() { if (root && root.alive && root.panelOpen) root.focusKeyboard() })
    }
  }

  Connections {
    target: root.svc
    function onLoggedInChanged() {
      if (!root.svc) return
      if (root.svc.loggedIn && root.currentFace === "login") {
        root.currentFace = root.hasTrack ? "nowPlaying" : "collections"
      } else if (!root.svc.loggedIn) {
        root.navStack = []
        root.forwardStack = []
        root.closeSheets()
        root.syncLoginFace()
      }
    }
    function onDaemonStateChanged() {
      // The offline/starting page owns the whole panel; a sheet left open
      // underneath would reappear as soon as the daemon came back.
      if (root.svc && root.daemonBlocked) root.closeSheets()
      if (root.svc && root.svc.daemonState === "connected") root.syncLoginFace()
    }
    function onStatusLoadedChanged() {
      root.syncLoginFace()
    }
  }

  // Sheets owned by the views (the track menu, the playlist picker, the
  // playlist dialogs) are reparented here so they sit above the floating
  // header: a view cannot stack over a sibling of its own container, and a
  // scrim that dims the page but not the header buttons reads as broken.
  // Declared before the container so its id is resolved when the views
  // (which are created with the container) bind their `overlayHost`.
  Item {
    id: sheetHost
    anchors.fill: parent
    z: 190
  }

  // Clean Flat Dark Container (fills popup with squared edges, no nested card)
  Rectangle {
    id: containerBg
    anchors.fill: parent
    color: "transparent"
    radius: 0
    clip: true
    // No layer here: MiniPlayer's root layer already flattens the whole panel
    // (page, glass, sheets and the daemon pages) before the open/close fade,
    // so a second one would only add a pass.

    Rectangle {
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: 1
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
      z: 20
    }

    // 1. Top Header Bar
    PlayerHeader {
      id: header
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: 52
      z: 10
      svc: root.svc
      foreground: root.foreground
      fontFamily: root.fontFamily
      blurSource: viewContainer
      // 1 while a hero/backdrop is under the header, fading to 0 as the page
      // scrolls onto the flat background; drives the button surface fade.
      headerArtworkProgress: root.currentFace === "nowPlaying"
        ? 1
        : (root.currentFace === "playlist"
          ? playlistView.headerArtworkProgress
          : (root.currentFace === "artist" ? artistView.headerArtworkProgress : 0))
      currentFace: root.currentFace
      currentArtists: root.svc ? root.svc.currentArtists : []
      artistArtCache: root.svc ? root.svc.artistArtCache : ({})
      artistArtUrl: root.currentFace === "nowPlaying" && root.svc
        ? root.svc.currentArtistArtUrl
        : (root.currentFace === "artist" ? (root.artistParams.artUrl || "") : "")
      // Artist sub-pages carry the artist chip after the back button.
      showArtistChip: root.currentFace === "topTracks" || root.currentFace === "releases"
      headerArtistId: root.currentFace === "topTracks"
        ? topTracksView.displayArtistId
        : (root.currentFace === "releases" ? releasesView.displayArtistId : "")
      headerArtistName: root.currentFace === "topTracks"
        ? topTracksView.displayArtistName
        : (root.currentFace === "releases" ? releasesView.displayArtistName : "")
      headerArtistArtUrl: root.currentFace === "topTracks"
        ? topTracksView.displayArtistArtUrl
        : (root.currentFace === "releases" ? releasesView.displayArtistArtUrl : "")
      collectionsActive: root.currentFace === "collections"
      // Album pages carry a share button and a heart in the header; playlists
      // show their actions under the Play/Shuffle pills instead.
      showEntityButtons: root.currentFace === "playlist"
        && root.playlistParams.itemType === "album"
      entityFavorite: playlistView.entityFavorite
      entityCanFavorite: playlistView.entityCanFavorite
      // The button exists while the list has a device in it. The daemon keeps
      // each device in that list for a minute after its Cast-port probe
      // starts failing, so a Wi-Fi hiccup cannot hide the button, but a
      // device that is really gone does not linger.
      castAvailable: root.svc
        ? ((root.svc.castDevices && root.svc.castDevices.length > 0) || root.svc.castActive)
        : false
      castActive: root.svc ? root.svc.castActive : false
      castDeviceKind: root.svc ? root.svc.castDeviceKind : ""
      castDeviceName: root.svc ? root.svc.castDeviceName : ""
      visible: root.currentFace !== "login"

      onBackClicked: root.popFace()
      onArtistSelected: function(id, name, artUrl) {
        if (id || name) {
          root.pushFace("artist", { artistId: id || "", name: name || "Artist", artUrl: artUrl || "" })
        }
      }
      onCollectionsClicked: root.toggleCollections()
      onCastClicked: root.openSheet("cast")
      onSearchClicked: root.pushFace("search", { query: "" })
      onHeaderArtistClicked: function(id, name) {
        var artUrl = root.currentFace === "topTracks"
          ? topTracksView.displayArtistArtUrl
          : (root.currentFace === "releases" ? releasesView.displayArtistArtUrl : "")
        root.pushFace("artist", { artistId: id || "", name: name || "Artist", artUrl: artUrl || "" })
      }
      onQueueBarClicked: root.openContext(root.svc ? root.svc.currentContext : null)
      onEntityFavoriteClicked: playlistView.toggleEntityFavorite()
      onEntityShareClicked: playlistView.shareEntity()
      onSearchDownRequested: {
        root.focusKeyboard()
        searchView.moveCursor(0, 1, false)
      }
    }

    // 2. Main Content View Router with Smooth Transitions
    Item {
      id: viewContainer
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      clip: true

      Rectangle {
        anchors.fill: parent
        color: Color.popups.background
        z: -99
      }

      // View A: Now Playing View
      NowPlayingView {
        id: npView
        anchors.fill: parent
        svc: root.svc
        foreground: root.foreground
        fontFamily: root.fontFamily
        overlayHost: sheetHost
        playingFrom: (root.svc && root.svc.playingContext) ? root.svc.playingContext : "Top Tracks"
        enabled: root.currentFace === "nowPlaying"
        // Keep decoding while the face is still on screen so the loop plays
        // through the fade-out when navigating to another view. Nothing should
        // decode underneath the offline page.
        videoActive: root.videoActive && (root.currentFace === "nowPlaying" || npView.visible)
          && !root.daemonBlocked

        opacity: root.currentFace === "nowPlaying" ? 1.0 : 0.0
        y: 0
        visible: opacity > 0.01

        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        onQueueClicked: root.pushFace("queue", {})
        onMenuRequested: root.openSheet("song")
        onArtistClicked: {
          if (root.svc && (root.svc.artistId || root.svc.artist)) {
            root.pushFace("artist", { artistId: root.svc.artistId || "", name: root.svc.artist, artUrl: root.svc.currentArtistArtUrl || "" })
          }
        }
        onArtistSelected: function(id, name) {
          root.pushFace("artist", { artistId: id || "", name: name, artUrl: "" })
        }
        onAlbumClicked: function(id, title, artUrl) {
          root.pushFace("playlist", { playlistId: id, itemType: "album", title: title, artUrl: artUrl })
        }
        onRadioClicked: function(id, artUrl, recentSubtitle) {
          root.pushFace("playlist", { playlistId: id, itemType: "mix", title: "Track Radio", recentSubtitle: recentSubtitle || "", artUrl: artUrl || "" })
        }
        onShareClicked: {
          if (root.svc && root.svc.currentTrackId) {
            root.svc.shareTrack(root.svc.currentTrackId)
          }
        }
        onContextClicked: function(ctx) {
          root.openContext(ctx)
        }
      }

      // View B: Collections View
      CollectionsView {
        id: colView
        anchors.fill: parent
        svc: root.svc
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: root.currentFace === "collections"
        bottomInset: collapsedPlayer.shouldBeVisible ? collapsedPlayer.height : 0

        opacity: root.currentFace === "collections" ? 1.0 : 0.0
        visible: opacity > 0.01

        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        onPlaylistSelected: function(id, title, artUrl) {
          root.pushFace("playlist", { playlistId: id, itemType: "playlist", title: title, artUrl: artUrl })
        }
        onMixSelected: function(id, title, artUrl, recentSubtitle) {
          root.pushFace("playlist", { playlistId: id, itemType: "mix", title: title, recentSubtitle: recentSubtitle || "", artUrl: artUrl })
        }
        onAlbumSelected: function(id, title, artUrl) {
          root.pushFace("playlist", { playlistId: id, itemType: "album", title: title, artUrl: artUrl })
        }
        onArtistSelected: function(id, name, artUrl) {
          root.pushFace("artist", { artistId: id, name: name, artUrl: artUrl })
        }
        onTopTracksSelected: function(id, name, artUrl) {
          root.pushFace("topTracks", { artistId: id, name: name, artUrl: artUrl })
        }
        onArtistRadioSelected: function(id, title, subtitle, artUrl) {
          root.pushFace("playlist", { playlistId: id, itemType: "artistRadio", title: title || "Artist Radio", subtitle: subtitle || "", artUrl: artUrl || "" })
        }
        onTrackSelected: function(item) {
          if (!root.svc || !item) return
          var id = String(item.id || "")
          if (id !== "" && id === String(root.svc.currentTrackId || "")) {
            root.setFace("nowPlaying", {})
            return
          }
          var track = {
            id: id,
            title: item.title || "Track",
            artist: item.subtitle || "",
            album: "",
            art_url: item.art_url || "",
            duration: 0
          }
          var context = { type: "track", id: track.id, title: track.title, subtitle: track.artist, artUrl: track.art_url }
          root.svc.playContext([track], 0, context)
          root.setFace("nowPlaying", {})
        }
        onCategorySelected: function(cat) {
          if (cat === "playlists") {
            root.pushFace("collectionList", { listType: "playlists", title: "Playlists" })
          } else if (cat === "albums") {
            root.pushFace("collectionList", { listType: "albums", title: "Albums" })
          } else if (cat === "artists") {
            root.pushFace("collectionList", { listType: "artists", title: "Artists" })
          } else if (cat === "mixes") {
            root.pushFace("collectionList", { listType: "mixes", title: "Mixes" })
          } else if (cat === "tracks") {
            root.pushFace("playlist", { playlistId: "favorites", itemType: "favorites", title: "Tracks", subtitle: "", artUrl: "" })
          }
        }
      }

      // View C: Collection List View (Playlists, Albums, Artists, Mixes)
      CollectionListView {
        id: colListView
        anchors.fill: parent
        anchors.topMargin: 52
        svc: root.svc
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: root.currentFace === "collectionList"
        bottomInset: collapsedPlayer.shouldBeVisible ? collapsedPlayer.height : 0
        listType: root.collectionListParams.listType || "playlists"

        opacity: root.currentFace === "collectionList" ? 1.0 : 0.0
        visible: opacity > 0.01 || root.currentFace === "collectionList"

        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        onPlaylistSelected: function(id, title, artUrl) {
          root.pushFace("playlist", { playlistId: id, itemType: "playlist", title: title, artUrl: artUrl })
        }
        onAlbumSelected: function(id, title, artUrl) {
          root.pushFace("playlist", { playlistId: id, itemType: "album", title: title, artUrl: artUrl })
        }
        onArtistSelected: function(id, name, artUrl) {
          root.pushFace("artist", { artistId: id, name: name, artUrl: artUrl })
        }
        onMixSelected: function(id, title, artUrl) {
          root.pushFace("playlist", { playlistId: id, itemType: "mix", title: title, artUrl: artUrl })
        }
        onFilterFocusRequested: colListView.focusFilter()
        onFilterDownRequested: {
          root.focusKeyboard()
          colListView.moveCursor(0, 1, false)
        }
      }

      // View D: Search View
      SearchView {
        id: searchView
        anchors.fill: parent
        anchors.topMargin: 52
        svc: root.svc
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: root.currentFace === "search"
        bottomInset: collapsedPlayer.shouldBeVisible ? collapsedPlayer.height : 0
        searchQuery: header.searchQuery

        opacity: root.currentFace === "search" ? 1.0 : 0.0
        visible: opacity > 0.01

        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        onQueryRequested: function(q) {
          header.setSearchQuery(q)
        }
        onQueryFocusRequested: header.focusSearch()
        onCancelClicked: root.popFace()
        onArtistSelected: function(id, name, artUrl) {
          root.pushFace("artist", { artistId: id, name: name, artUrl: artUrl })
        }
        onAlbumSelected: function(id, title, artUrl) {
          root.pushFace("playlist", { playlistId: id, itemType: "album", title: title, artUrl: artUrl })
        }
        onPlaylistSelected: function(id, title, artUrl) {
          root.pushFace("playlist", { playlistId: id, itemType: "playlist", title: title, artUrl: artUrl })
        }
        onCurrentTrackClicked: root.setFace("nowPlaying")
      }

      // View E: Queue View
      QueueView {
        id: queueView
        anchors.fill: parent
        svc: root.svc
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: root.currentFace === "queue"
        bottomInset: collapsedPlayer.shouldBeVisible ? collapsedPlayer.height : 0

        opacity: root.currentFace === "queue" ? 1.0 : 0.0
        visible: opacity > 0.01

        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        onCurrentTrackClicked: {
          root.setFace("nowPlaying")
        }
        onArtistSelected: function(id, name) {
          root.pushFace("artist", { artistId: id || "", name: name, artUrl: "" })
        }
      }

      // View F: Playlist / Album / Favorites View
      PlaylistView {
        id: playlistView
        anchors.fill: parent
        svc: root.svc
        foreground: root.foreground
        fontFamily: root.fontFamily
        overlayHost: sheetHost
        enabled: root.currentFace === "playlist"
        bottomInset: editActionBar.shouldBeVisible ? editActionBar.height : (collapsedPlayer.shouldBeVisible ? collapsedPlayer.height : 0)
        playlistId: root.playlistParams.playlistId || ""
        itemType: root.playlistParams.itemType || "playlist"
        title: root.playlistParams.title || ""
        subtitle: root.playlistParams.subtitle || ""
        recentSubtitle: root.playlistParams.recentSubtitle || ""
        artUrl: root.playlistParams.artUrl || ""

        opacity: root.currentFace === "playlist" ? 1.0 : 0.0
        visible: opacity > 0.01

        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        onArtistSelected: function(id, name) {
          var artUrl = (root.svc && id && root.svc.artistArtCache)
            ? String(root.svc.artistArtCache[id] || "")
            : ""
          root.pushFace("artist", { artistId: id, name: name, artUrl: artUrl })
        }

        onPlaybackStarted: root.setFace("nowPlaying", {})
        onCurrentTrackClicked: root.setFace("nowPlaying")
        onMenuRequested: root.openEntityMenu("playlist")
        onCloseRequested: root.popFace()
        onKeyboardRequested: root.focusKeyboard()
        // Leaving edit mode hands the keyboard back to the catcher: the field
        // that just went away cannot. Gated on the playlist face — the
        // cross-fade cancels an edit up to 220 ms after a face change, and
        // must not steal focus from the new page's editor.
        onEditModeChanged: {
          if (!playlistView.editMode && root.currentFace === "playlist") root.focusKeyboard()
        }
      }

      // View G: Artist View
      ArtistView {
        id: artistView
        anchors.fill: parent
        svc: root.svc
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: root.currentFace === "artist"
        bottomInset: collapsedPlayer.shouldBeVisible ? collapsedPlayer.height : 0
        artistId: root.artistParams.artistId || ""
        artistName: root.artistParams.name || ""
        artistArtUrl: root.artistParams.artUrl || ""

        opacity: root.currentFace === "artist" ? 1.0 : 0.0
        visible: opacity > 0.01

        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        onAlbumSelected: function(id, title, artUrl) {
          root.pushFace("playlist", { playlistId: id, itemType: "album", title: title, artUrl: artUrl })
        }
        onArtistSelected: function(id, name) {
          root.pushFace("artist", { artistId: id || "", name: name, artUrl: "" })
        }
        onRadioRequested: function(id, name, artUrl) {
          root.pushFace("playlist", { playlistId: id, itemType: "artistRadio", title: "Artist Radio", subtitle: name, artUrl: artUrl })
        }
        onTopTracksRequested: function(id, name, artUrl) {
          root.pushFace("topTracks", { artistId: id, name: name, artUrl: artUrl })
        }
        onReleasesRequested: function(filter, id, name, artUrl) {
          root.pushFace("releases", { filter: filter, artistId: id, name: name, artUrl: artUrl })
        }
        onMenuRequested: root.openEntityMenu("artist")
        onBioRequested: {
          root.bioTitle = artistView.displayArtistName
          root.bioText = artistView.artistDescription
          root.openSheet("bio")
        }

        onPlaybackStarted: root.setFace("nowPlaying", {})
        onCurrentTrackClicked: root.setFace("nowPlaying")
      }

      // View G2: Artist Top Tracks View
      ArtistTopTracksView {
        id: topTracksView
        anchors.fill: parent
        svc: root.svc
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: root.currentFace === "topTracks"
        bottomInset: collapsedPlayer.shouldBeVisible ? collapsedPlayer.height : 0
        artistId: root.topTracksParams.artistId || ""
        artistName: root.topTracksParams.name || ""
        artistArtUrl: root.topTracksParams.artUrl || ""

        opacity: root.currentFace === "topTracks" ? 1.0 : 0.0
        visible: opacity > 0.01

        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        onArtistSelected: function(id, name, artUrl) {
          root.pushFace("artist", { artistId: id || "", name: name || "Artist", artUrl: artUrl || "" })
        }
        onPlaybackStarted: root.setFace("nowPlaying", {})
        onCurrentTrackClicked: root.setFace("nowPlaying")
      }

      // View G3: Artist Discography View
      ArtistReleasesView {
        id: releasesView
        anchors.fill: parent
        svc: root.svc
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: root.currentFace === "releases"
        bottomInset: collapsedPlayer.shouldBeVisible ? collapsedPlayer.height : 0
        artistId: root.releasesParams.artistId || ""
        artistName: root.releasesParams.name || ""
        artistArtUrl: root.releasesParams.artUrl || ""
        requestedFilter: root.releasesParams.filter || "popular"

        opacity: root.currentFace === "releases" ? 1.0 : 0.0
        visible: opacity > 0.01

        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        onAlbumSelected: function(id, title, artUrl) {
          root.pushFace("playlist", { playlistId: id, itemType: "album", title: title, artUrl: artUrl })
        }
      }

      // View G4: Keyboard reference page (`?`)
      KeybindsView {
        id: keybindsView
        anchors.fill: parent
        foreground: root.foreground
        fontFamily: root.fontFamily
        bottomInset: collapsedPlayer.shouldBeVisible ? collapsedPlayer.height : 0

        opacity: root.currentFace === "keybinds" ? 1.0 : 0.0
        visible: opacity > 0.01

        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      }

      // View H: Login View
      LoginView {
        id: loginView
        anchors.fill: parent
        svc: root.svc
        foreground: root.foreground
        fontFamily: root.fontFamily

        opacity: root.currentFace === "login" ? 1.0 : 0.0
        visible: opacity > 0.01

        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        onLoginCompleted: {
          root.currentFace = root.hasTrack ? "nowPlaying" : "collections"
        }
      }
    }

    // 3. Collapsed Bottom Player (Docked flush edge-to-edge on sub-pages)
    CollapsedPlayer {
      id: collapsedPlayer
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 58
      svc: root.svc
      foreground: root.foreground
      fontFamily: root.fontFamily
      blurSource: viewContainer

      readonly property bool shouldBeVisible: root.currentFace !== "nowPlaying" && root.currentFace !== "login" && root.hasTrack
        // The edit dock takes this slot while the playlist page is edited.
        && !(root.currentFace === "playlist" && playlistView.editMode)
      visible: opacity > 0.01
      enabled: shouldBeVisible
      opacity: shouldBeVisible ? 1.0 : 0.0

      transform: Translate {
        y: collapsedPlayer.shouldBeVisible ? 0 : 58
        Behavior on y { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
      }

      Behavior on opacity { NumberAnimation { duration: 200 } }

      onExpandRequested: {
        root.setFace("nowPlaying")
      }
    }

    // 3b. Floating Save/Cancel dock while the playlist page is being edited.
    // It takes the collapsed player's slot so Save is always in reach,
    // however long the list is.
    EditActionBar {
      id: editActionBar
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 58
      foreground: root.foreground
      fontFamily: root.fontFamily
      blurSource: viewContainer

      readonly property bool shouldBeVisible: root.currentFace === "playlist" && playlistView.editMode
      visible: opacity > 0.01
      enabled: shouldBeVisible
      opacity: shouldBeVisible ? 1.0 : 0.0

      transform: Translate {
        y: editActionBar.shouldBeVisible ? 0 : 58
        Behavior on y { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
      }

      Behavior on opacity { NumberAnimation { duration: 200 } }

      onSaveRequested: playlistView.commitEdit()
      onCancelRequested: playlistView.cancelEdit()
    }
  }

  // 4. Shared entity context menu, above the header and collapsed player.
  ContextMenu {
    id: contextMenu
    anchors.fill: parent
    z: 200
    svc: root.svc
    foreground: root.foreground
    fontFamily: root.fontFamily
    open: root.menuOpen
    items: root.menuItems
    header: root.menuHeader

    onActionTriggered: function(action) { root.runEntityMenuAction(action) }
    onCloseRequested: root.menuOpen = false
  }

  // 5. Artist biography sheet, opened from the artist context menu.
  BioSheet {
    id: bioSheet
    anchors.fill: parent
    z: 201
    foreground: root.foreground
    fontFamily: root.fontFamily
    open: root.bioOpen
    title: root.bioTitle
    text: root.bioText

    onCloseRequested: root.bioOpen = false
  }

  // 6. Cast device sheet, opened from the header's Cast button.
  CastSheet {
    id: castSheet
    anchors.fill: parent
    z: 202
    svc: root.svc
    foreground: root.foreground
    fontFamily: root.fontFamily
    open: root.castOpen

    onCloseRequested: root.castOpen = false
  }

  // 7. Starting page. An automatic start nobody asked for (a slow first
  // install or plugin load) shows this instead of the offline page while setup
  // is still running. A start from the offline page's own button never gets
  // here — that page stays up and disables its button.
  DaemonStarting {
    id: daemonStartingPage
    anchors.fill: parent
    z: 300
    foreground: root.foreground
    fontFamily: root.fontFamily
    visible: root.daemonStarting
  }

  // 8. Offline page. It sits above every sheet and the floating header: when
  // the daemon is gone there is nothing truthful left to show underneath.
  // The id must not match the `daemonDown` property: an id and a property of
  // the same name in one component shadow each other, and every unqualified
  // `daemonDown` reference silently becomes the item (always truthy).
  DaemonDown {
    id: daemonDownPage
    anchors.fill: parent
    z: 301
    svc: root.svc
    foreground: root.foreground
    fontFamily: root.fontFamily
    visible: root.daemonDown
  }

  // Mouse back/forward buttons step through the face stack while the panel
  // is open (the bar widget keeps mapping them to previous/next). Only those
  // buttons are grabbed, so clicks and wheel events pass through untouched.
  // ReleaseWithinBounds keeps the tap alive when the mouse moves a little
  // between press and release, which is easy to do by accident.
  TapHandler {
    acceptedButtons: Qt.BackButton | Qt.ForwardButton
    gesturePolicy: TapHandler.ReleaseWithinBounds
    enabled: !root.daemonBlocked
    onTapped: function(eventPoint, button) {
      if (button === Qt.ForwardButton) root.handleForward()
      else root.handleBack()
    }
  }

  // 6. Panel keyboard target. It holds focus until a text editor in a view
  // takes it; MiniPlayer returns it here once the editor goes away.
  KeyCatcher {
    id: keyCatcher
    anchors.fill: parent
    enabled: !root.daemonBlocked
    onMoveRequested: function(dx, dy, shift) { root.handleMove(dx, dy, shift) }
    onActivateRequested: function(shift) { root.handleActivate(shift) }
    onPlayPauseRequested: if (root.svc) root.svc.playPause()
    onDeleteRequested: root.handleDelete()
    onEscapeRequested: root.handleEscape()
    onPageRequested: function(direction) { root.handlePage(direction) }
    onHomeEndRequested: function(toEnd) { root.handleHomeEnd(toEnd) }
    onBackRequested: root.handleBack()
    onForwardRequested: root.handleForward()
    onTabRequested: function(direction) { root.tabRequested(direction) }
    onTextKey: function(text) { root.handleTextKey(text) }
  }

  // Window-level Escape so the ladder still runs while a view editor (search
  // bar, filter, dialog field) owns the keyboard. An open sheet's own
  // Shortcut wins first through `overlayOpen`.
  Shortcut {
    sequence: "Escape"
    enabled: root.panelOpen && !root.overlayOpen
    onActivated: root.handleEscape()
  }
}
