import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import qs.Commons
import "../components"
import "../lib/Design.js" as Design
import "../lib/Format.js" as Format
import "../lib/Playlist.js" as Playlist

Item {
  id: root

  property bool alive: true
  Component.onDestruction: {
    root.alive = false
    loadTimer.stop()
  }

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  // MiniPlayer's layer above the header, where the dialogs are reparented.
  property Item overlayHost: null
  property real bottomInset: 0
  // Floating PlayerHeader height and the fixed track-row rhythm. The ListView
  // uses these for keyboard paging and cursor visibility. Rows sit flush
  // against each other; the height carries the breathing room instead.
  readonly property int topBarHeight: 52
  // 50 px of content with the old 1 px seam split into 1 px above and below.
  readonly property int rowHeight: 52
  readonly property int rowSpacing: 0

  // Natural page height excluding the dock padding. A short page must not
  // scroll into blank space, so the footer only adds the collapsed player's
  // inset when the header and rows actually overflow the area above it.
  readonly property real footerNaturalHeight: root.albumCopyright !== ""
    ? Style.space(8) + footerMeasure.implicitHeight : 0
  readonly property real naturalContentHeight: {
    if (!playlistFlickable || !playlistFlickable.headerItem) return 0
    return playlistFlickable.headerItem.height
      + Math.max(0, playlistFlickable.count) * (root.rowHeight + root.rowSpacing)
      + root.footerNaturalHeight
  }
  readonly property real footerHeight: {
    if (!playlistFlickable) return 0
    var pad = root.naturalContentHeight > Math.max(0, playlistFlickable.height - root.bottomInset)
      ? root.bottomInset + Style.space(16) : 0
    return root.footerNaturalHeight + pad
  }

  property string playlistId: ""
  property string itemType: "playlist" // "playlist", "mix", "album"
  property string title: ""
  property string subtitle: ""
  // Label for the Recently Played entry only, kept apart from `subtitle` so a
  // context can name itself in the recent list without that text landing in the
  // page header (a track radio records "Song - Artist", which is too much for
  // the header's meta line).
  property string recentSubtitle: ""
  property string artUrl: ""

  property var tracks: []
  property var albumData: null
  property string resolvedAlbumId: ""
  property int requestGeneration: 0
  property bool loading: false
  // The favourites revision the current rows were loaded under. A re-entry
  // with the same revision keeps the cached rows; a toggle bumps the revision
  // and forces a refetch.
  property int loadedFavoritesRevision: -1
  // The playlist item revision the current rows were loaded under; the song
  // menu and the picker mutate playlists behind this page, so re-entry
  // refetches when they bumped it (mirrors loadedFavoritesRevision).
  property int loadedPlaylistRevision: -1
  // Paged loading: the first page renders immediately and the tail is
  // appended in the background. Play requests wait until the tail is done so
  // the queue always receives the complete list.
  property int nextTrackOffset: -1
  property bool loadingMore: false
  property var pendingPlay: null
  readonly property int firstPageSize: 100

  // Playlist management (playlists created by the signed-in user only)
  property bool own: false
  property var playlistInfo: null
  property string localTitle: ""
  // `null` means "no local edit yet", so a cleared description is representable.
  property var localDescription: null
  property bool playlistPublic: false
  // Inline edit mode: the page itself becomes the editor (title/description
  // fields below the artwork, row drag handles and delete buttons) until Save
  // or Cancel. Track changes stay local until Save, so Escape or leaving the
  // page discards all of it together.
  property bool editMode: false
  property string editName: ""
  property string editDescription: ""
  // The track list as it was when edit mode began (same track objects, old
  // order) and its raw TIDAL item indices, so Save can compile a mutation
  // plan against the pre-edit list.
  property var editOriginal: null
  property var editOriginalRaw: []
  // Row drag state while reordering in edit mode: which row is carried, the
  // scene Y the drag began at, its live travel, and the slot it hovers over.
  property int dragFrom: -1
  property real dragStartY: 0
  property real dragY: 0
  readonly property int dragTo: {
    if (root.dragFrom < 0) return -1
    var stride = root.rowHeight + root.rowSpacing
    return Math.max(0, Math.min(root.tracks.length - 1, root.dragFrom + Math.round(root.dragY / stride)))
  }
  property bool deleteOpen: false

  readonly property bool canManage: root.own && root.itemType === "playlist"

  // 1 while the cover backdrop is under the floating header, fading to 0 as
  // the header scrolls past it onto the flat page background. PlayerHeader
  // uses this to fade its buttons towards the flat-page surface.
  readonly property real heroBackdropHeight: 420
  readonly property real headerArtworkProgress: {
    if (root.itemType === "favorites" || root.playlistId === "favorites") return 0
    // The inline ListView header sits above contentY 0, so the view's
    // originY is negative by the header's height and contentY alone is not
    // the distance the page has scrolled. A short album can reach the end of
    // its scroll range while still at a small positive contentY, which left
    // the buttons on the artwork surface; measure from the page top instead.
    var scrolled = playlistFlickable.contentY - playlistFlickable.originY
    var stripBottom = scrolled + root.topBarHeight
    var fadeStart = root.heroBackdropHeight * 0.45
    var fadeEnd = root.heroBackdropHeight * 0.9
    return Math.max(0, Math.min(1, (fadeEnd - stripBottom) / (fadeEnd - fadeStart)))
  }

  // Entity favourites: the album header heart and the Add button on
  // playlists the user does not own. Own playlists cannot be favourited
  // (they are already in the collection).
  property bool entityFavorite: false
  readonly property bool entityCanFavorite: root.itemType === "album"
    || (root.itemType === "playlist" && !root.loading && !root.own && root.playlistId !== "")

  readonly property string displayTitle: root.localTitle !== ""
    ? root.localTitle
    : (root.itemType === "album" && root.albumData && root.albumData.title
        ? root.albumData.title
        : (root.itemType === "playlist" && root.playlistInfo && root.playlistInfo.title
            ? root.playlistInfo.title : root.title))
  // Album-level credits with their ids, so the header can open each artist.
  // Fall back to the plain `artist` string (and its id) for older daemon
  // responses that do not carry the `artists` array yet.
  readonly property var albumArtists: {
    if (!root.albumData) return []
    var credits = root.albumData.artists
    if (Array.isArray(credits) && credits.length > 0) return credits
    var name = String(root.albumData.artist || "").trim()
    if (name === "") return []
    return [{ id: String(root.albumData.artist_id || ""), name: name }]
  }
  // A single-track release reads as "Single" instead of "1 tracks"; TIDAL's
  // release type wins when the album endpoint reports it. While a fresh page
  // is loading there is no count to report, so the line stays empty.
  readonly property string trackCountLabel: {
    if (root.loading && root.tracks.length === 0) return ""
    if (root.itemType === "album") {
      var releaseType = root.albumData ? String(root.albumData.release_type || "").toUpperCase() : ""
      if (releaseType === "SINGLE") return "Single"
      if (releaseType === "" && root.tracks.length === 1) return "Single"
    }
    return root.tracks.length + (root.tracks.length === 1 ? " track" : " tracks")
  }
  readonly property string albumReleaseLine: {
    if (!root.albumData) return ""
    var parts = []
    var date = Design.releaseDate(root.albumData.release_date || "")
    if (date) parts.push(date)
    if (root.albumData.number_of_volumes && root.albumData.number_of_volumes > 1) {
      parts.push(root.albumData.number_of_volumes + " volumes")
    }
    return parts.join(" · ")
  }
  readonly property string albumCopyright: root.albumData && root.albumData.copyright
    ? String(root.albumData.copyright) : ""
  readonly property string playlistDescription: root.localDescription !== null
    ? String(root.localDescription)
    : (root.playlistInfo && root.playlistInfo.description
        ? String(root.playlistInfo.description) : "")
  readonly property string displaySubtitle: root.itemType === "album" && root.albumData && root.albumData.artist
    ? root.albumData.artist : root.subtitle
  readonly property string recentContextSubtitle: root.recentSubtitle !== ""
    ? root.recentSubtitle : root.displaySubtitle
  // Only contexts that are named by type carry a "Type: Name" label
  // ("Artist Radio: …"); albums, playlists, mixes and the tracks page show
  // their own name. Recent cards keep the raw title and show the type
  // underneath, so they use `recentTitle`.
  readonly property string playbackContextTitle: {
    if (root.itemType === "artistRadio") {
      return root.displaySubtitle
        ? "Artist Radio: " + root.displaySubtitle
        : root.displayTitle
    }
    if (root.itemType === "favorites") {
      return root.displayTitle || "Tracks"
    }
    return root.displayTitle
  }
  // Everything under the title on one line: for albums the artist credits sit
  // on the clickable line above, so this is track count, duration, volumes
  // and release date.
  readonly property string headerMetaLine: {
    var parts = []
    if (root.itemType !== "album" && root.displaySubtitle) parts.push(root.displaySubtitle)
    if (root.trackCountLabel !== "") parts.push(root.trackCountLabel)
    if (root.totalSeconds > 0) parts.push(Format.formatDuration(root.totalSeconds))
    if (root.itemType === "album" && root.albumReleaseLine !== "") parts.push(root.albumReleaseLine)
    return parts.join(" · ")
  }
  readonly property string displayArtUrl: {
    if (root.itemType === "favorites" || root.playlistId === "favorites") return ""
    if (root.itemType === "album" && root.albumData && root.albumData.art_url) {
      // The album list already handed us the cover at another size. Keeping
      // it avoids swapping the source for the same bitmap when the album
      // response lands, which reloads the image and blinks the hero.
      if (root.artUrl && Format.sameArtwork(root.artUrl, root.albumData.art_url)) return root.artUrl
      return root.albumData.art_url
    }
    if (root.itemType === "playlist" && root.playlistInfo && root.playlistInfo.art_url) {
      if (root.artUrl && Format.sameArtwork(root.artUrl, root.playlistInfo.art_url)) return root.artUrl
      return root.playlistInfo.art_url
    }
    return root.artUrl
  }
  // The album or playlist page is the only thing its Share button can share, so
  // its cover is kept in the file that button sends.
  onDisplayArtUrlChanged: if (root.svc) root.svc.warmShareArt("view", root.displayArtUrl)

  signal trackSelected(var track, int index)
  signal currentTrackClicked()
  signal playbackStarted()
  signal artistSelected(string id, string name)
  signal menuRequested()
  signal closeRequested()
  // Ask MiniPlayer to seat the keyboard on its catcher (row picks in edit
  // mode; a field has just released focus).
  signal keyboardRequested()

  Timer {
    id: loadTimer
    interval: 0
    repeat: false
    onTriggered: if (root.alive) root.loadData()
  }

  function scheduleLoad() {
    loadTimer.restart()
  }

  function loadData() {
    loadTimer.stop()
    var generation = ++root.requestGeneration
    var requestedId = root.playlistId
    var requestedType = root.itemType
    var requestedTitle = root.title
    var effectiveId = requestedId || root.resolvedAlbumId
    var isCurrentRequest = function() {
      return root && root.alive
        && generation === root.requestGeneration
        && requestedId === root.playlistId
        && requestedType === root.itemType
        && (requestedId !== "" || requestedType !== "album" || requestedTitle === root.title)
    }
    if (!root.svc) {
      root.loading = false
      return
    }
    // A fresh load invalidates any edit session: its snapshot and raw index
    // plan are about the rows being thrown away.
    root.editMode = false
    root.editOriginal = null
    root.editOriginalRaw = []
    root.dragFrom = -1
    root.dragY = 0
    root.tracks = []
    root.albumData = null
    root.own = false
    root.playlistInfo = null
    root.localTitle = ""
    root.localDescription = null
    root.playlistPublic = false
    root.entityFavorite = false
    root.loadedPlaylistRevision = root.svc ? root.svc.playlistRevision : -1
    root.nextTrackOffset = -1
    root.loadingMore = false
    root.pendingPlay = null
    root.loading = true
    var cb = function(data) {
      if (!isCurrentRequest()) return
      root.tracks = data || []
      root.nextTrackOffset = -1
      root.loading = false
    }
    // Paged types render the first page immediately and fetch the rest in
    // the background; play requests wait for the tail so a partial list can
    // never become a partial queue.
    var applyPage = function(page) {
      if (!isCurrentRequest()) return
      root.tracks = (page && page.tracks) || []
      root.nextTrackOffset = (page && page.next_offset !== null && page.next_offset !== undefined)
        ? Number(page.next_offset) : -1
      root.loading = false
      root.continueLoading()
    }

    if (requestedType === "favorites" || requestedId === "favorites") {
      root.loadedFavoritesRevision = root.svc.favoritesRevision
      root.svc.fetchFavorites(0, root.firstPageSize, applyPage)
    } else if (requestedType === "album" && !effectiveId && requestedTitle) {
      root.svc.search(requestedTitle, function(results) {
        if (!isCurrentRequest()) return
        if (results && results.albums && results.albums.length > 0) {
          root.resolvedAlbumId = String(results.albums[0].id || "")
          if (root.resolvedAlbumId) root.loadData()
          else root.loading = false
        } else {
          root.loading = false
        }
      })
      return
    } else if (!effectiveId) {
      root.loading = false
      return
    } else if (requestedType === "mix") {
      root.svc.fetchMixTracks(effectiveId, cb)
    } else if (requestedType === "artistRadio") {
      root.svc.fetchArtistRadio(effectiveId, cb)
    } else if (requestedType === "album") {
      root.svc.fetchAlbum(effectiveId, root.firstPageSize, function(data) {
        if (!isCurrentRequest()) return
        if (data) {
          root.albumData = data
          root.tracks = data.tracks || []
          root.nextTrackOffset = (data.next_track_offset !== null && data.next_track_offset !== undefined)
            ? Number(data.next_track_offset) : -1
          root.entityFavorite = !!data.favorite
        }
        root.loading = false
        root.continueLoading()
      })
    } else {
      root.svc.fetchPlaylistTracks(effectiveId, 0, root.firstPageSize, applyPage)
      root.svc.fetchPlaylistInfo(effectiveId, function(info) {
        if (!isCurrentRequest() || !info) return
        root.playlistInfo = info
        root.own = !!info.own
        root.playlistPublic = info.public === true
        root.entityFavorite = !!info.favorite
        if (root.svc && root.svc.currentContext
            && root.svc.currentContext.type === "playlist"
            && String(root.svc.currentContext.id || "") === String(effectiveId)
            && root.svc.currentContext.own !== root.own) {
          root.svc.currentContext = Object.assign({}, root.svc.currentContext, { own: root.own })
        }
      })
    }
  }

  // Fetches the rest of a paged list after its first page is on screen.
  function continueLoading() {
    if (root.nextTrackOffset < 0 || !root.svc) {
      root.finishLoading()
      return
    }
    if (root.loadingMore) return
    root.loadingMore = true
    var generation = root.requestGeneration
    var offset = root.nextTrackOffset
    var done = function(page) {
      if (!root || !root.alive || generation !== root.requestGeneration) return
      var next = (page && page.next_offset !== null && page.next_offset !== undefined)
        ? Number(page.next_offset) : -1
      // Never re-request the same page: a non-advancing cursor would loop.
      if (next >= 0 && next === offset) next = -1
      var incoming = (page && page.tracks) || []
      if (root.itemType === "favorites" || root.playlistId === "favorites") {
        // TIDAL's favourites offsets can overlap across pages when tracks are
        // unavailable; favourites never legitimately repeat, so drop repeats.
        var seen = {}
        for (var i = 0; i < root.tracks.length; i++) {
          seen[String(root.tracks[i].id || "")] = true
        }
        var fresh = []
        for (var j = 0; j < incoming.length; j++) {
          var tid = String(incoming[j].id || "")
          if (seen[tid]) continue
          seen[tid] = true
          fresh.push(incoming[j])
        }
        root.tracks = root.tracks.concat(fresh)
      } else {
        root.tracks = root.tracks.concat(incoming)
      }
      root.nextTrackOffset = next
      root.loadingMore = false
      if (root.nextTrackOffset >= 0) root.continueLoading()
      else root.finishLoading()
    }
    if (root.itemType === "favorites" || root.playlistId === "favorites") {
      root.svc.fetchFavorites(offset, 0, done)
    } else if (root.itemType === "album") {
      root.svc.fetchAlbumTracks(root.resolvedAlbumId || root.playlistId, offset, 0, done)
    } else if (root.itemType === "playlist") {
      root.svc.fetchPlaylistTracks(root.playlistId, offset, 0, done)
    } else {
      root.nextTrackOffset = -1
      root.loadingMore = false
      root.finishLoading()
    }
  }

  function finishLoading() {
    var pending = root.pendingPlay
    root.pendingPlay = null
    if (!pending) return
    if (pending.index >= 0) {
      var wasCurrent = root.isCurrentTrack(root.tracks[pending.index])
      root.playTrack(pending.index)
      if (pending.openNowPlaying && !wasCurrent) root.currentTrackClicked()
    } else {
      root.playAll(pending.shuffle)
    }
  }

  // A model write resets the ListView to the top, so every working-list write
  // goes through here: hold the viewport where the user left it across the
  // rebuild, and once more after layout has caught up.
  function setWorkingList(list) {
    var y = playlistFlickable.contentY
    root.tracks = list
    var restore = function() {
      if (!root || !root.alive || !playlistFlickable) return
      scrollHandler.reset()
      var maxY = Design.maxScrollY(playlistFlickable.originY, playlistFlickable.contentHeight, playlistFlickable.height)
      playlistFlickable.contentY = Math.max(playlistFlickable.originY, Math.min(maxY, y))
    }
    restore()
    Qt.callLater(restore)
  }

  // Deletes and drags in edit mode are local: they change the working list
  // only, and Save compiles them into one removal request plus a move
  // sequence against the pre-edit snapshot.
  function removeTrack(index) {
    if (!root.editMode) return
    if (index < 0 || index >= root.tracks.length) return
    var list = root.tracks.slice()
    list.splice(index, 1)
    root.setWorkingList(list)
  }

  function dragMoveTo(from, to) {
    if (!root.editMode || from === to) return
    if (from < 0 || from >= root.tracks.length || to < 0 || to >= root.tracks.length) return
    var list = root.tracks.slice()
    var item = list.splice(from, 1)[0]
    list.splice(to, 0, item)
    root.setWorkingList(list)
  }

  // The raw TIDAL item index of a track. The parser drops unplayable items,
  // so display position and raw index can differ; the playlist fetch fills
  // `item_index` in. The fallback keeps old daemons working as before.
  function rawIndexAt(track, displayIndex) {
    return track && track.item_index !== undefined && track.item_index !== null
      ? Number(track.item_index) : displayIndex
  }

  function openEdit() {
    if (!root.canManage || root.editMode || !root.svc) return
    // Same rule as play actions: the plan needs the complete list, so an
    // edit cannot start while the tail is still paging in.
    if (root.nextTrackOffset >= 0 || root.loadingMore) return
    root.editName = root.displayTitle
    root.editDescription = root.playlistDescription
    if (playlistFlickable.headerItem && typeof playlistFlickable.headerItem.setEditFields === "function") {
      playlistFlickable.headerItem.setEditFields(root.editName, root.editDescription)
    }
    root.editOriginal = root.tracks.slice()
    var raw = []
    for (var i = 0; i < root.editOriginal.length; i++) {
      raw.push(root.rawIndexAt(root.editOriginal[i], i))
    }
    root.editOriginalRaw = raw
    root.editMode = true
  }

  // Cancel discards everything: the fields' text and the local track edits.
  // Escape, leaving the page and any fresh load route here.
  function cancelEdit() {
    if (!root.editMode) return
    root.dragFrom = -1
    root.dragY = 0
    root.editMode = false
    if (root.editOriginal) root.setWorkingList(root.editOriginal)
    root.editOriginal = null
    root.editOriginalRaw = []
  }

  function commitEdit() {
    var name = root.editName.trim()
    if (!name || !root.svc || !root.editMode) return
    var targetId = root.playlistId
    var generation = root.requestGeneration
    var description = root.editDescription
    // Compile the plan from the pre-edit list against the working list. Raw
    // indices ride on the track objects; a row dragged since edit began is
    // matched back to its snapshot slot for the same identity.
    var workingRaw = []
    for (var i = 0; i < root.tracks.length; i++) {
      var at = root.editOriginal.indexOf(root.tracks[i])
      workingRaw.push(at >= 0 ? root.editOriginalRaw[at] : root.rawIndexAt(root.tracks[i], i))
    }
    var plan = Playlist.planTrackEdits(root.editOriginalRaw, workingRaw)
    var hasTrackChanges = plan.remove.length > 0 || plan.moves.length > 0
    // Optimistic: leave edit mode at once and reload if TIDAL refuses a step.
    root.editMode = false
    root.editOriginal = null
    root.editOriginalRaw = []
    root.localTitle = name
    root.localDescription = description
    root.svc.updatePlaylist(targetId, name, description, function(err) {
      if (!root || !root.alive || !root.svc) return
      var sameView = generation === root.requestGeneration && targetId === root.playlistId
      if (err) {
        root.svc.notify("Could not update playlist")
        if (sameView) root.loadData()
        return
      }
      root.applyTrackPlan(targetId, plan, function(planErr) {
        if (!root || !root.alive || !root.svc) return
        var stillSame = generation === root.requestGeneration && targetId === root.playlistId
        if (planErr) {
          root.svc.notify("Could not update playlist")
          if (stillSame) root.loadData()
        } else if (hasTrackChanges && stillSame) {
          // Refresh live TIDAL item_index values so a second edit in the same
          // visit compiles against accurate server slots.
          root.loadData()
        }
      })
    })
  }

  // The plan runs in order: one removal request first (its indices are only
  // valid before anything moves), then each single-item move against the
  // arrangement its predecessor produced.
  function applyTrackPlan(targetId, plan, done) {
    if (!root.svc) {
      done(true)
      return
    }
    if (plan.remove.length > 0) {
      root.svc.removePlaylistTracks(targetId, plan.remove, function(err) {
        if (!root || !root.alive) return
        if (err) {
          done(err)
          return
        }
        root.applyMoves(targetId, plan.moves, 0, done)
      })
    } else {
      root.applyMoves(targetId, plan.moves, 0, done)
    }
  }

  function applyMoves(targetId, moves, i, done) {
    if (i >= moves.length) {
      done(null)
      return
    }
    if (!root.svc) {
      done(true)
      return
    }
    root.svc.movePlaylistTrack(targetId, moves[i].from, moves[i].to, function(err) {
      if (!root || !root.alive) return
      if (err) {
        done(err)
        return
      }
      root.applyMoves(targetId, moves, i + 1, done)
    })
  }

  // Drop: the carried row lands in its hover slot locally. The drag state is
  // cleared before the model write so the delegates that rebuild cannot
  // compute a shift from a stale drag; no paint runs inside this call.
  function finishDrag() {
    var from = root.dragFrom
    var to = root.dragTo
    root.dragFrom = -1
    root.dragY = 0
    if (from >= 0 && to >= 0 && from !== to) root.dragMoveTo(from, to)
  }

  // Optimistic privacy toggle. TIDAL's set-public/set-private endpoints answer
  // 200 with an empty body, so the local flag is the source of truth until the
  // next load. Success is silent: the button's own highlight shows the state.
  function togglePublic() {
    if (!root.svc || !root.canManage) return
    var generation = root.requestGeneration
    var targetId = root.playlistId
    var next = !root.playlistPublic
    root.playlistPublic = next
    root.svc.setPlaylistPublic(targetId, next, function(err) {
      if (!root || !root.alive || !root.svc) return
      if (err) {
        if (generation === root.requestGeneration && targetId === root.playlistId) {
          root.playlistPublic = !next
        }
        root.svc.notify("Could not update playlist privacy")
      }
    })
  }

  function shareEntity() {
    if (!root.svc) return
    if (root.itemType === "album") {
      root.svc.shareAlbum(root.playlistId || root.resolvedAlbumId, root.displayTitle, root.displayArtUrl)
    } else if (root.itemType === "playlist") {
      root.svc.sharePlaylist(root.playlistId, root.displayTitle, root.displayArtUrl)
    }
  }

  function confirmDelete() {
    root.deleteOpen = false
    if (!root.svc) return
    var generation = root.requestGeneration
    var targetId = root.playlistId
    root.svc.deletePlaylist(targetId, function(err) {
      if (!root || !root.alive || !root.svc) return
      if (err) {
        root.svc.notify("Could not delete playlist")
      } else {
        root.svc.notify("Playlist deleted")
        if (generation === root.requestGeneration && targetId === root.playlistId) {
          root.closeRequested()
        }
      }
    })
  }

  // Optimistic favourite toggle for the Add button and the context menu of
  // playlists that are not owned.
  function toggleEntityFavorite() {
    if (!root.svc || !root.entityCanFavorite) return
    var generation = root.requestGeneration
    var kind = root.itemType
    var id = root.playlistId || root.resolvedAlbumId
    if (!id) return
    var next = !root.entityFavorite
    root.entityFavorite = next
    root.svc.toggleEntityFavorite(kind, id, function(err, data) {
      if (!root || !root.alive || !root.svc) return
      var sameView = generation === root.requestGeneration && id === (root.playlistId || root.resolvedAlbumId)
      if (err || !data || data.favorite === undefined) {
        if (sameView) root.entityFavorite = !next
        root.svc.notify(kind === "playlist" ? "Could not update playlists" : "Could not update albums")
      } else if (sameView) {
        root.entityFavorite = !!data.favorite
      }
    })
  }

  // Items and preview row for the shared bottom-sheet ContextMenu (owned by
  // MiniPlayer so it can cover the floating header). Albums have no menu: the
  // header carries share/heart directly.
  function entityMenuItems() {
    var items = []
    if (root.itemType === "playlist" && root.canManage) {
      items.push({ action: "delete", label: "Delete playlist", icon: Qt.resolvedUrl("../../assets/icons/close.svg"), destructive: true })
    }
    if (root.itemType === "playlist" && !root.canManage) {
      items.push({
        action: "favorite",
        label: root.entityFavorite ? "Remove from playlists" : "Add to playlists",
        icon: root.entityFavorite
          ? Qt.resolvedUrl("../../assets/icons/heart-filled.svg")
          : Qt.resolvedUrl("../../assets/icons/heart.svg")
      })
      items.push({ action: "share", label: "Share", icon: Qt.resolvedUrl("../../assets/icons/share.svg") })
    }
    return items
  }

  function entityMenuHeader() {
    return {
      artUrl: root.displayArtUrl,
      title: root.displayTitle,
      subtitle: root.headerMetaLine,
      roundArt: false
    }
  }

  function handleMenuAction(action) {
    if (!root.svc) return
    if (action === "favorite") {
      root.toggleEntityFavorite()
    } else if (action === "share") {
      root.shareEntity()
    } else if (action === "delete") {
      root.deleteOpen = true
    }
  }

  function requestAlbumArtistArt() {
    if (!root.svc) return
    for (var i = 0; i < root.albumArtists.length; i++) {
      var artistId = String(root.albumArtists[i].id || "")
      if (artistId) root.svc.requestArtistArt(artistId)
    }
  }

  // Called by MiniPlayer on fresh navigation (push/setFace). Back-navigation
  // leaves the Flickable alone so the user returns to where they were.
  function scrollToTop() {
    scrollHandler.reset()
    // Include the inline header; contentY 0 is the first delegate, not the
    // page top.
    playlistFlickable.positionViewAtBeginning()
  }

  // ---- Overlay keyboard (delete dialog) ----------------------------------------

  readonly property bool overlayOpen: root.deleteOpen
  // Delete confirmation cursor: 0 = Cancel (default, safe), 1 = Delete.
  property int deleteCursor: 0

  onDeleteOpenChanged: if (root.deleteOpen) root.deleteCursor = 0

  function overlayMove(delta) {
    if (root.deleteOpen) {
      if (delta !== 0) root.deleteCursor = Math.max(0, Math.min(1, root.deleteCursor + delta))
      return true
    }
    return false
  }

  function overlayActivate() {
    if (root.deleteOpen) {
      if (root.deleteCursor === 1) root.confirmDelete()
      else root.deleteOpen = false
      return true
    }
    return false
  }

  function overlayEscape() {
    // Escape cancels the edit before the ladder would navigate away.
    if (root.editMode) { root.cancelEdit(); return true }
    if (root.deleteOpen) { root.deleteOpen = false; return true }
    return false
  }

  // The delete dialog closes with the sheets, for MiniPlayer's
  // one-sheet-at-a-time rule. Inline edit mode is not a sheet: it survives
  // sheets opening over it and ends only on Save, Cancel, Escape or leaving
  // the page.
  function closeOverlays() {
    root.deleteOpen = false
  }

  Shortcut {
    sequence: "Escape"
    enabled: root.deleteOpen
    onActivated: root.deleteOpen = false
  }

  // ---- Keyboard cursor --------------------------------------------------------

  property int cursorIndex: -1

  // Pointer/keyboard exclusivity: an arrow key hides the hover highlight and
  // shows the cursor; moving the real pointer hands the list back to the
  // mouse.
  property bool keyboardNav: false
  property int hoveredIndex: -1

  // Any real pointer move hands the list back to the mouse. The handler sits
  // on the stationary view root and only counts position changes, so repaints
  // and rows scrolling under a still cursor leave keyboard mode alone.
  property real lastPointerX: -10000
  property real lastPointerY: -10000

  HoverHandler {
    id: pointerWatcher
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onPointChanged: {
      var p = point.position
      if (Math.abs(p.x - root.lastPointerX) > 0.5 || Math.abs(p.y - root.lastPointerY) > 0.5) {
        root.lastPointerX = p.x
        root.lastPointerY = p.y
        root.notePointerMotion()
      }
    }
  }

  function notePointerMotion() {
    if (!root.keyboardNav) return
    root.keyboardNav = false
    root.cursorIndex = -1
  }

  function rowHovered(index) {
    root.hoveredIndex = index
  }

  function rowUnhovered(index) {
    if (root.hoveredIndex === index) root.hoveredIndex = -1
  }

  function beginKeyboardNav() {
    if (root.keyboardNav) return
    root.keyboardNav = true
    if (root.hoveredIndex >= 0) root.cursorIndex = root.hoveredIndex
  }

  function resetCursor() {
    root.cursorIndex = -1
    root.hoveredIndex = -1
    root.keyboardNav = false
  }

  function playAll(shuffle) {
    if (!root.svc || root.tracks.length === 0) return
    if (root.nextTrackOffset >= 0 || root.loadingMore) {
      root.pendingPlay = { shuffle: shuffle, index: -1 }
      return
    }
    var playable = Format.playableTracks(root.tracks, 0).tracks
    if (playable.length === 0) return
    var ctxObj = { type: root.itemType, id: root.playlistId || root.resolvedAlbumId, title: root.playbackContextTitle, recentTitle: root.displayTitle, subtitle: root.recentContextSubtitle, artUrl: root.displayArtUrl, own: root.canManage }
    if (shuffle) {
      root.svc.setShuffle(true)
      root.svc.playContext(playable, Math.floor(Math.random() * playable.length), ctxObj)
    } else {
      root.svc.setShuffle(false)
      root.svc.playContext(playable, 0, ctxObj)
    }
    root.playbackStarted()
  }

  function isCurrentTrack(track) {
    if (!root.svc || !track) return false
    var cur = String(root.svc.currentTrackId || "")
    return cur !== "" && cur === String(track.id || "")
  }

  function playTrack(index) {
    if (!root.svc || index < 0 || index >= root.tracks.length) return
    var track = root.tracks[index]
    if (!Format.isTrackAvailable(track)) return
    if (root.isCurrentTrack(track)) {
      root.currentTrackClicked()
      return
    }
    if (root.nextTrackOffset >= 0 || root.loadingMore) {
      var openNowPlaying = Boolean(root.pendingPlay && root.pendingPlay.index === index)
      root.pendingPlay = { shuffle: false, index: index, openNowPlaying: openNowPlaying }
      return
    }
    var ctxObj = { type: root.itemType, id: root.playlistId || root.resolvedAlbumId, title: root.playbackContextTitle, recentTitle: root.displayTitle, subtitle: root.recentContextSubtitle, artUrl: root.displayArtUrl, own: root.canManage }
    root.svc.playContext(root.tracks, index, ctxObj)
    root.trackSelected(track, index)
  }

  function firstVisibleIndex() {
    if (root.tracks.length === 0) return -1
    var stride = root.rowHeight + root.rowSpacing
    // ListView rows start at content y = 0; the header sits above at the
    // negative origin. Pick the row under the floating top bar, or the first
    // row while the header is still on screen.
    var viewTop = playlistFlickable.contentY + root.topBarHeight
    return Math.max(0, Math.min(root.tracks.length - 1, Math.floor(Math.max(0, viewTop) / stride)))
  }

  function moveCursor(dx, dy, shift) {
    if (dy === 0 || root.tracks.length === 0) return
    // Shift+arrows carry the cursor row along, in edit mode only: the move is
    // local like the drag, and Save compiles it into the plan.
    if (shift === true && root.editMode && root.canManage) {
      root.beginKeyboardNav()
      if (root.cursorIndex < 0) {
        root.cursorIndex = root.firstVisibleIndex()
        root.ensureCursorVisible()
        return
      }
      var to = root.cursorIndex + dy
      if (to < 0 || to >= root.tracks.length) return
      root.dragMoveTo(root.cursorIndex, to)
      root.cursorIndex = to
      // After the rebuild settles (the model write pinned the scroll), bring
      // the moved row back into view if the step crossed an edge.
      Qt.callLater(function() { if (root && root.alive) root.ensureCursorVisible() })
      return
    }
    root.beginKeyboardNav()
    if (root.cursorIndex < 0) {
      root.cursorIndex = root.firstVisibleIndex()
      root.ensureCursorVisible()
      return
    }
    // Up from the first row leaves the list for the description field just
    // above it (the name field sits above that).
    if (dy < 0 && root.editMode && root.cursorIndex === 0) {
      root.focusDescriptionField()
      return
    }
    root.cursorIndex = Math.max(0, Math.min(root.tracks.length - 1, root.cursorIndex + dy))
    root.ensureCursorVisible()
  }

  // The keyboard chain in edit mode: list <-> description <-> name (the
  // fields sit above the list, so moving up reaches the description first).
  // Tab belongs to the panel's face switcher, so the arrow keys walk the
  // chain at its edges instead.
  function focusTitleField() {
    root.resetCursor()
    if (playlistFlickable.headerItem) playlistFlickable.headerItem.focusTitle()
  }

  function focusDescriptionField() {
    root.resetCursor()
    if (playlistFlickable.headerItem) playlistFlickable.headerItem.focusDescription()
  }

  function focusFirstRow() {
    if (root.tracks.length === 0) {
      root.keyboardRequested()
      return
    }
    root.beginKeyboardNav()
    root.cursorIndex = 0
    root.ensureCursorVisible()
    root.keyboardRequested()
  }

  // Ctrl+S saves from anywhere in the edit.
  Shortcut {
    sequences: [StandardKey.Save]
    enabled: root.editMode
    onActivated: root.commitEdit()
  }

  // Del removes the keyboard-cursor row, in edit mode only.
  function deleteCursorRow() {
    if (!root.editMode || !root.canManage) return
    if (root.cursorIndex < 0 || root.cursorIndex >= root.tracks.length) return
    root.removeTrack(root.cursorIndex)
    if (root.cursorIndex >= root.tracks.length) root.cursorIndex = Math.max(0, root.tracks.length - 1)
  }

  function pageCursor(direction) {
    if (root.tracks.length === 0) return
    root.beginKeyboardNav()
    var rows = Math.max(1, Math.floor((playlistFlickable.height - root.topBarHeight - root.bottomInset) / (root.rowHeight + root.rowSpacing)) - 1)
    if (root.cursorIndex < 0) root.cursorIndex = root.firstVisibleIndex()
    else root.cursorIndex = Math.max(0, Math.min(root.tracks.length - 1, root.cursorIndex + direction * rows))
    root.ensureCursorVisible()
  }

  function homeEndCursor(toEnd) {
    if (root.tracks.length === 0) return
    root.beginKeyboardNav()
    root.cursorIndex = toEnd ? root.tracks.length - 1 : 0
    root.ensureCursorVisible()
  }

  function activateCursor(shift) {
    // Rows do not play while the page is being edited.
    if (root.editMode) return
    if (root.cursorIndex < 0 || root.cursorIndex >= root.tracks.length) {
      // No selection: Enter plays the page, Shift+Enter shuffles it.
      root.playAll(shift)
      return
    }
    root.playTrack(root.cursorIndex)
  }

  function ensureCursorVisible() {
    if (root.cursorIndex < 0) return
    var stride = root.rowHeight + root.rowSpacing
    var row = playlistFlickable.itemAtIndex(root.cursorIndex)
    var top = row ? row.mapToItem(playlistFlickable.contentItem, 0, 0).y : root.cursorIndex * stride
    var bottom = top + root.rowHeight
    // Content scrolls under the floating top bar, so the usable viewport
    // starts below it.
    var viewTop = playlistFlickable.contentY + root.topBarHeight
    // Keep the row above the collapsed player docked at the bottom.
    var viewBottom = playlistFlickable.contentY + playlistFlickable.height - root.bottomInset
    var margin = Style.space(8)
    var target = playlistFlickable.contentY
    if (top - margin < viewTop) target = top - margin - root.topBarHeight
    else if (bottom + margin > viewBottom) target = bottom + margin - (playlistFlickable.height - root.bottomInset)
    var maxY = Design.maxScrollY(playlistFlickable.originY, playlistFlickable.contentHeight, playlistFlickable.height)
    target = Math.max(playlistFlickable.originY, Math.min(maxY, target))
    if (Math.abs(target - playlistFlickable.contentY) < 1) return
    scrollHandler.reset()
    playlistFlickable.contentY = target
  }

  // Delete confirmation
  Item {
    // Reparented above the header by MiniPlayer (see overlayHost there).
    parent: root.overlayHost ? root.overlayHost : root
    anchors.fill: parent
    z: 100
    visible: root.deleteOpen

    // Scrolling over the dialog must not scroll the playlist behind it.
    WheelShield {}

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.6)

      MouseArea {
        anchors.fill: parent
        // Hover too: the dimmed playlist behind the dialog must not light a
        // row up under the pointer.
        hoverEnabled: true
        onClicked: root.deleteOpen = false
      }
    }

    Rectangle {
      anchors.centerIn: parent
      width: Math.min(parent.width - 48, 320)
      height: deleteCol.implicitHeight + 32
      radius: 10
      color: Color.popups.background

      Column {
        id: deleteCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 16
        spacing: 10

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "Delete playlist?"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: 14
          font.weight: Font.Bold
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "“" + root.displayTitle + "” will be removed from your collection. This cannot be undone."
          color: root.foreground
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: 12
          wrapMode: Text.WordWrap
        }

        RowLayout {
          width: parent.width
          spacing: 10

          Item { Layout.fillWidth: true }

          Rectangle {
            Layout.preferredWidth: 76
            Layout.preferredHeight: 30
            radius: 15
            border.color: root.deleteCursor === 0 ? Color.accent : "transparent"
            border.width: root.deleteCursor === 0 ? 1 : 0
            color: deleteCancelMa.containsMouse
              ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: "Cancel"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: 12
            }

            MouseArea {
              id: deleteCancelMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.deleteOpen = false
            }
          }

          Rectangle {
            Layout.preferredWidth: 86
            Layout.preferredHeight: 30
            radius: 15
            border.color: root.deleteCursor === 1 ? Color.popups.background : "transparent"
            border.width: root.deleteCursor === 1 ? 1 : 0
            color: deleteConfirmMa.containsMouse
              ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.85)
              : Color.accent

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: "Delete"
              color: Color.popups.background
              font.family: root.fontFamily
              font.pixelSize: 12
              font.weight: Font.Bold
            }

            MouseArea {
              id: deleteConfirmMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.confirmDelete()
            }
          }
        }
      }
    }
  }

  onPlaylistIdChanged: {
    root.resolvedAlbumId = ""
    root.albumData = null
    root.scheduleLoad()
  }
  onItemTypeChanged: {
    root.resolvedAlbumId = ""
    root.albumData = null
    root.scheduleLoad()
  }
  onTitleChanged: if (root.itemType === "album" && root.playlistId === "") {
    root.resolvedAlbumId = ""
    root.scheduleLoad()
  }
  onAlbumArtistsChanged: root.requestAlbumArtistArt()
  onSvcChanged: {
    root.requestAlbumArtistArt()
    if (root.svc && visible) root.scheduleLoad()
  }
  onVisibleChanged: {
    // Leaving the page abandons an inline edit; nothing half-typed or
    // locally reordered survives the round trip.
    if (!visible) {
      root.cancelEdit()
      return
    }
    if (!root.svc) return
    // Favourites are mutated from the now-playing heart, so the cached rows
    // can go stale while the page is off screen. Reload only when a toggle
    // happened since they were loaded; otherwise re-entry is instant.
    if (root.itemType === "favorites" || root.playlistId === "favorites") {
      if (root.tracks.length === 0
          || root.loadedFavoritesRevision !== root.svc.favoritesRevision) {
        root.scheduleLoad()
      }
    } else if ((root.tracks.length === 0 && !root.loading
        && (root.playlistId !== "" || root.resolvedAlbumId !== ""))
        // The song menu and the picker mutate playlists behind this page;
        // refetch when their changes bumped the revision.
        || (root.itemType === "playlist" && root.playlistId !== ""
            && root.loadedPlaylistRevision !== root.svc.playlistRevision)) {
      root.scheduleLoad()
    }
  }
  // And drop/add a row live if the heart is toggled while this page is open.
  property int favoritesRevision: root.svc ? root.svc.favoritesRevision : 0
  onFavoritesRevisionChanged: {
    if (root.visible && (root.itemType === "favorites" || root.playlistId === "favorites")) {
      root.scheduleLoad()
    }
  }
  Component.onCompleted: {
    if (root.visible) root.scheduleLoad()
    if (root.svc) root.svc.warmShareArt("view", root.displayArtUrl)
  }

  // Calculate total duration
  readonly property real totalSeconds: {
    var total = 0
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i].duration) total += tracks[i].duration
    }
    return total
  }

  // Scrolling cover backdrop, full width like the artist-page hero. It sits
  // behind the page content, fades into the flat background, and scrolls
  // away with the rest of the page.
  Item {
    id: heroBackdrop
    x: 0
    y: playlistFlickable.originY - playlistFlickable.contentY
    width: parent.width
    height: root.heroBackdropHeight
    clip: true
    visible: root.displayArtUrl !== ""
    layer.enabled: visible

    Rectangle {
      color: Color.popups.background
      anchors.fill: parent
    }

    Image {
      id: backgroundArtwork
      anchors.fill: parent
      source: root.displayArtUrl
      fillMode: Image.PreserveAspectCrop
      sourceSize.width: 760
      sourceSize.height: 980
      asynchronous: true
      visible: false
      layer.enabled: true
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
    }

    Rectangle {
      anchors.fill: parent
      gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.28) }
        GradientStop { position: 0.28; color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.45) }
        GradientStop { position: 0.50; color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.64) }
        GradientStop { position: 0.68; color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.82) }
        GradientStop { position: 0.80; color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.94) }
        GradientStop { position: 0.88; color: Color.popups.background }
        GradientStop { position: 1.0; color: Color.popups.background }
      }
    }
  }

  // Mirrors the footer copyright's layout so the root can measure its real
  // height without reaching into the footer's component scope.
  Text {
    id: footerMeasure
    visible: false
    // Use the page width, not the ListView's: this item is created before the
    // list, and a width of 0 would wrap the copyright one character per line
    // and inflate the footer into a screenful of blank scroll space.
    width: Math.max(0, root.width - 2 * Design.pageGutter)
    textFormat: Text.PlainText
    text: root.albumCopyright
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption || 10
    wrapMode: Text.WordWrap
    topPadding: Style.space(4)
  }

  ListView {
    id: playlistFlickable
    anchors.fill: parent
    // Rows paint their fill over the panel's full width (see Design.pageGutter);
    // the header and footer inset themselves instead.
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    spacing: 0
    model: root.tracks
    cacheBuffer: Style.space(320)

    SmoothScrollHandler { id: scrollHandler }

    // The page header lives in this inline header, so its height (credits,
    // duration, a wrapping title) lands after the page was positioned at the
    // top. Keep that top edge under the viewport instead of letting the page
    // drift down by the growth. See ScrollAnchor.qml.
    ScrollAnchor { }

    header: Item {
      width: playlistFlickable.width
      // Leave the same 14 px visual gap before the first row that the old
      // Column placed between the page header and the track list; the row's
      // own 1 px top padding supplies the rest.
      height: mainCol.implicitHeight + Style.space(14) - 1

      // Focus targets for the keyboard chain; the field ids live in this
      // header's scope, so the entry points do too.
      function focusTitle() { editNameInput.forceActiveFocus() }
      function focusDescription() { editDescriptionInput.forceActiveFocus() }
      function setEditFields(name, description) {
        editNameInput.text = name || ""
        editDescriptionInput.text = description || ""
      }

      Column {
        id: mainCol
        width: playlistFlickable.width - 2 * Design.pageGutter
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(14)

        // 1. Hero Artwork (centered square, padded below the floating header)
        Item {
          width: parent.width
          height: (root.itemType !== "favorites" && root.playlistId !== "favorites") ? 64 + 140 : Design.headerClearance

          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 64
            width: 140
            height: 140
            visible: root.itemType !== "favorites" && root.playlistId !== "favorites"
            radius: 2
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

            RoundedImage {
              id: heroArt
              anchors.fill: parent
              radius: 2
              borderWidth: 1
              borderColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
              source: root.displayArtUrl
              sourceSize.width: 280
              sourceSize.height: 280
              visible: source !== ""
            }

            TidalLogo {
              anchors.centerIn: parent
              size: 48
              color: root.foreground
              faint: true
              visible: !heroArt.showingImage
            }
          }
        }

        // 2. Title & Metadata
        Column {
          width: parent.width
          spacing: 4
          anchors.horizontalCenter: parent.horizontalCenter

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: !root.editMode
            text: root.displayTitle || "Playlist"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading + 4
            font.weight: Font.Bold
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // Clickable artist chips, one per album credit. The chip owns the
          // artwork/name sizing so album and artist pages match.
          Item {
            id: artistHeader
            width: parent.width
            height: artistChipRow.implicitHeight + Style.space(2) * 2
            visible: root.itemType === "album" && root.albumArtists.length > 0

            Row {
              id: artistChipRow
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, artistHeader.width)
              spacing: Style.space(6)
              clip: true

              Repeater {
                model: root.albumArtists

                ArtistChip {
                  required property var modelData

                  svc: root.svc
                  artistId: String(modelData.id || "")
                  artistName: String(modelData.name || "")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: function(id, name) { root.artistSelected(id, name) }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: text !== "" && !root.editMode
            text: root.headerMetaLine
            color: root.foreground
            opacity: 0.68
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption || 11
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.itemType === "playlist" && root.playlistDescription !== "" && !root.editMode
            text: root.playlistDescription
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption || 10
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
          }
        }

        // 2b. Edit fields: title and description editors below the artwork,
        // in place of the metadata block.
        Column {
          width: parent.width
          spacing: 10
          visible: root.editMode

          Rectangle {
            width: parent.width
            height: 40
            radius: 6
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
            border.color: editNameInput.activeFocus ? Color.popups.border : "transparent"
            border.width: 1

            // The inputs claim no cursor of their own; this is the filter
            // bar's pattern: a full-size area under the editor carries the
            // text cursor and focuses the field from the padding.
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.IBeamCursor
              onClicked: editNameInput.forceActiveFocus()
            }

            TextInput {
              id: editNameInput
              anchors.fill: parent
              anchors.leftMargin: 10
              anchors.rightMargin: 10
              verticalAlignment: TextInput.AlignVCenter
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: 14
              selectByMouse: true
              onTextChanged: root.editName = text
              onAccepted: root.commitEdit()
              // Down walks the edit chain: name -> description -> list.
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Down) {
                  root.focusDescriptionField()
                  event.accepted = true
                }
              }
            }
          }

          Rectangle {
            width: parent.width
            height: 76
            radius: 6
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
            border.color: editDescriptionInput.activeFocus ? Color.popups.border : "transparent"
            border.width: 1

            // Same cursor/focus area as the title field.
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.IBeamCursor
              onClicked: editDescriptionInput.forceActiveFocus()
            }

            // The placeholder sits behind the editor so it never covers the
            // field's own input handling (hover, cursor, clicks).
            Text {
              textFormat: Text.PlainText
              anchors.fill: parent
              anchors.margins: 7
              anchors.leftMargin: 11
              anchors.rightMargin: 10
              text: "Description"
              color: root.foreground
              opacity: 0.4
              font.family: root.fontFamily
              font.pixelSize: 13
              visible: !editDescriptionInput.text && !editDescriptionInput.inputMethodComposing
            }

            // Wrapped in a Flickable so long descriptions scroll (wheel events
            // fall through from the TextEdit, which never scrolls itself).
            Flickable {
              id: editDescriptionFlick
              anchors.fill: parent
              anchors.margins: 7
              anchors.leftMargin: 10
              anchors.rightMargin: 10
              contentWidth: width
              contentHeight: editDescriptionInput.height
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              flickableDirection: Flickable.VerticalFlick

              TextEdit {
                id: editDescriptionInput
                width: editDescriptionFlick.width
                height: Math.max(contentHeight, editDescriptionFlick.height)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: 13
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                onTextChanged: root.editDescription = text
                // At the very ends of the text the arrow keys leave the
                // field: up back to the name, down to the track list.
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Up && editDescriptionInput.cursorPosition === 0) {
                    root.focusTitleField()
                    event.accepted = true
                  } else if (event.key === Qt.Key_Down
                      && editDescriptionInput.cursorPosition >= editDescriptionInput.text.length) {
                    root.focusFirstRow()
                    event.accepted = true
                  }
                }
              }
            }
          }
        }

        // 3. Action Buttons Row: [ Play ] and [ Shuffle ] Pills
        RowLayout {
          width: parent.width
          spacing: 12
          visible: !root.editMode

          // Play Pill Button
          Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            radius: 20
            color: playPillMa.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.88) : root.foreground

            RowLayout {
              anchors.centerIn: parent
              spacing: 6

              SvgIcon {
                size: 16
                color: Color.popups.background
                source: Qt.resolvedUrl("../../assets/icons/play.svg")
              }

              Text {
                textFormat: Text.PlainText
                text: "Play"
                color: Color.popups.background
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall || 12
                font.weight: Font.Bold
              }
            }

            MouseArea {
              id: playPillMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.playAll(false)
            }
          }

          // Shuffle Pill Button
          Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            radius: 20
            color: shufPillMa.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.09)

            RowLayout {
              anchors.centerIn: parent
              spacing: 6

              SvgIcon {
                size: 16
                color: root.foreground
                source: Qt.resolvedUrl("../../assets/icons/shuffle.svg")
              }

              Text {
                textFormat: Text.PlainText
                text: "Shuffle"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall || 12
                font.weight: Font.Bold
              }
            }

            MouseArea {
              id: shufPillMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.playAll(true)
            }
          }
        }

        // Playlist quick actions, styled like the artist page's row: own
        // playlists can be edited, made private/public, shared and deleted;
        // other playlists can be added to the collection instead. The wrapper
        // trims the tiles' transparent padding so the row does not push the
        // track list away. The tiles stand down while editing.
        Item {
          id: playlistActions
          width: parent.width
          height: 42
          visible: root.itemType === "playlist" && !root.editMode

          RowLayout {
            width: parent.width
            spacing: 2

            ActionTile {
              visible: root.canManage
              foreground: root.foreground
              fontFamily: root.fontFamily
              label: "Edit"
              iconSource: Qt.resolvedUrl("../../assets/icons/edit.svg")
              iconColor: root.foreground
              onTriggered: root.openEdit()
            }

            ActionTile {
              visible: root.canManage
              foreground: root.foreground
              fontFamily: root.fontFamily
              label: root.playlistPublic ? "Public" : "Private"
              iconSource: root.playlistPublic
                ? Qt.resolvedUrl("../../assets/icons/globe.svg")
                : Qt.resolvedUrl("../../assets/icons/lock.svg")
              // Public state reads as active, like Following on the artist page.
              iconColor: root.playlistPublic ? Color.accent : root.foreground
              onTriggered: root.togglePublic()
            }

            ActionTile {
              visible: !root.canManage && root.entityCanFavorite
              foreground: root.foreground
              fontFamily: root.fontFamily
              label: root.entityFavorite ? "Added" : "Add"
              iconSource: root.entityFavorite
                ? Qt.resolvedUrl("../../assets/icons/heart-filled.svg")
                : Qt.resolvedUrl("../../assets/icons/heart.svg")
              iconColor: root.entityFavorite ? Color.accent : root.foreground
              onTriggered: root.toggleEntityFavorite()
            }

            ActionTile {
              foreground: root.foreground
              fontFamily: root.fontFamily
              label: "Share"
              iconSource: Qt.resolvedUrl("../../assets/icons/share.svg")
              iconColor: root.foreground
              onTriggered: root.shareEntity()
            }

            ActionTile {
              foreground: root.foreground
              fontFamily: root.fontFamily
              label: "More"
              iconSource: Qt.resolvedUrl("../../assets/icons/more-vertical.svg")
              iconColor: root.foreground
              onTriggered: root.menuRequested()
            }
          }
        }

        // Loading indicator, filling the blank area under the page header.
        Item {
          width: parent.width
          height: root.loading && root.tracks.length === 0
            ? Math.max(40, playlistFlickable.height - y - root.bottomInset - Style.space(24))
            : 0
          visible: height > 0

          TidalLogo {
            anchors.centerIn: parent
            size: 32
            color: root.foreground
            pulsing: root.loading && root.tracks.length === 0
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: !root.loading && root.tracks.length === 0
          text: root.itemType === "favorites" ? "No saved tracks yet" : "No tracks"
          color: root.foreground
          opacity: 0.55
          font.family: root.fontFamily
          font.pixelSize: Style.font.body || 13
          horizontalAlignment: Text.AlignHCenter
          topPadding: 28
        }
      }
    }

    delegate: Rectangle {
      id: trackRow
      required property var modelData
      required property int index

      // While a row is dragged it follows the pointer and the rows it crosses
      // slide one slot out of its way; the model itself changes on drop.
      readonly property real dragShift: {
        if (root.dragFrom < 0) return 0
        var stride = root.rowHeight + root.rowSpacing
        if (trackRow.index === root.dragFrom) return root.dragY
        if (root.dragFrom < root.dragTo && trackRow.index > root.dragFrom && trackRow.index <= root.dragTo) return -stride
        if (root.dragFrom > root.dragTo && trackRow.index >= root.dragTo && trackRow.index < root.dragFrom) return stride
        return 0
      }

      readonly property bool isCurrent: root.svc && String(root.svc.currentTrackId || "") === String(trackRow.modelData.id || "")
      readonly property bool isAvailable: Format.isTrackAvailable(trackRow.modelData)
      readonly property bool interactiveRow: root.editMode || trackRow.isAvailable
      readonly property bool hasCursor: root.keyboardNav && root.cursorIndex === trackRow.index
      // The row's own controls sit above its hover area; keep the band lit
      // while the pointer is over one of them — and for the whole of a drag,
      // where the pointer may drift off the handle entirely.
      readonly property bool hovered: trackRow.dragging
        || ((trackRowHover.hovered || removeMa.containsMouse || dragMa.containsMouse) && !root.keyboardNav)
      readonly property bool dragging: root.dragFrom === trackRow.index
      // A carried row floats over other rows, so its resting look (the page
      // background under its tint) is composited into one opaque fill —
      // visually identical, but nothing shows through it.
      readonly property color restingFill: {
        if (trackRow.isCurrent) {
          return Qt.rgba(Color.popups.background.r * 0.85 + Color.accent.r * 0.15,
            Color.popups.background.g * 0.85 + Color.accent.g * 0.15,
            Color.popups.background.b * 0.85 + Color.accent.b * 0.15, 1)
        }
        return Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 1)
      }
      width: playlistFlickable.width
      height: root.rowHeight
      transform: Translate { y: trackRow.dragShift }
      // The carried row paints above the rows it passes.
      z: trackRow.index === root.dragFrom ? 2 : 0
      // Full-bleed band: the fill and the click target reach the panel edges,
      // the row's content stays on Design.pageGutter.
      radius: 0
      color: trackRow.dragging
        ? trackRow.restingFill
        : (trackRow.hasCursor
          ? Style.hoverFillFor(root.foreground, Color.accent)
          : (trackRow.isCurrent
            ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.15)
            : "transparent"))

      HoverFill {
        anchors.fill: parent
        tint: trackRow.isCurrent ? Color.accent : root.foreground
        strength: 0.08
        active: trackRow.hovered && trackRow.interactiveRow
        instant: root.keyboardNav
      }

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Design.pageGutter
        anchors.rightMargin: Design.pageGutter
        spacing: 10

        // Track thumbnail for playlists, mixes, and favorites
        Rectangle {
          Layout.alignment: Qt.AlignVCenter
          Layout.preferredWidth: 36
          Layout.preferredHeight: 36
          radius: 2
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
          border.width: 1
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
          visible: root.itemType !== "album"
          opacity: trackRow.isAvailable ? 1.0 : 0.4

          RoundedImage {
            id: rowArt
            anchors.fill: parent
            radius: 2
            borderWidth: 1
            borderColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
            source: trackRow.modelData.art_url || ""
            sourceSize.width: 80
            sourceSize.height: 80
            visible: source !== ""
          }

          TidalLogo {
            anchors.centerIn: parent
            size: 16
            color: root.foreground
            faint: true
            visible: !rowArt.showingImage
          }
        }

        // Track number for albums
        Item {
          Layout.alignment: Qt.AlignVCenter
          Layout.preferredWidth: 24
          Layout.preferredHeight: 24
          visible: root.itemType === "album"
          opacity: trackRow.isAvailable ? 1.0 : 0.4

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: (trackRow.index + 1).toString()
            // The playing row's number joins its accent title; the rest stay
            // as a quiet track index.
            color: trackRow.isCurrent ? Color.accent : root.foreground
            opacity: trackRow.isCurrent ? 1.0 : 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption || 11
            font.weight: Font.DemiBold
          }
        }

        // Title and Artist
        Column {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          spacing: 2
          clip: true
          opacity: trackRow.isAvailable ? 1.0 : 0.4

          Row {
            width: parent.width
            spacing: 4

            FadeText {
              id: playlistTrackTitle
              textFormat: Text.PlainText
              text: trackRow.modelData.title || ""
              color: trackRow.isCurrent ? Color.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall || 12
              font.weight: trackRow.isCurrent ? Font.Bold : Font.DemiBold
              width: Math.min(implicitWidth, Math.max(0, parent.width - (trackRow.modelData.explicit ? 18 : 0)))
            }

            Rectangle {
              width: 12
              height: 12
              radius: 2
              anchors.verticalCenter: playlistTrackTitle.verticalCenter
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
              visible: !!trackRow.modelData.explicit

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: "E"
                color: root.foreground
                font.pixelSize: 8
                font.bold: true
              }
            }
          }

          ArtistNames {
            width: parent.width
            height: implicitHeight
            enabled: !root.editMode && trackRow.isAvailable
            interactive: !root.editMode && trackRow.isAvailable
            artists: trackRow.modelData.artists || []
            fallbackText: trackRow.modelData.artist || ""
            fallbackArtistId: trackRow.modelData.artist_id || ""
            foreground: root.foreground
            textOpacity: trackRow.isCurrent ? 0.85 : 0.6
            fontFamily: root.fontFamily
            fontPixelSize: Style.font.caption || 10
            onArtistClicked: function(id, name) { root.artistSelected(id, name) }
          }
        }

        // Playing indicator for every track list (albums, playlists, mixes,
        // favourites, artist radio)
        EqualizerBars {
          Layout.alignment: Qt.AlignVCenter
          visible: trackRow.isCurrent && !root.editMode && Boolean(root.svc && root.svc.playing)
          playing: Boolean(root.svc && root.svc.playing)
          barColor: Color.accent
          width: 12
          height: 12
        }

        // Duration
        Text {
          Layout.alignment: Qt.AlignVCenter
          textFormat: Text.PlainText
          text: trackRow.modelData.duration ? Format.formatDuration(trackRow.modelData.duration) : ""
          color: root.foreground
          opacity: trackRow.isAvailable ? 0.5 : 0.25
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption || 10
          visible: text !== "" && !root.editMode
        }

        // Edit-mode controls: delete the row, or drag it by the handle.
        // Outside edit mode the rows carry neither.
        Row {
          Layout.alignment: Qt.AlignVCenter
          spacing: 2
          visible: root.editMode

          Rectangle {
            width: 28
            height: 28
            radius: 14
            // Destructive: the tint carries the meaning, the wash follows it.
            color: removeMa.containsMouse
              ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.15)
              : "transparent"

            SvgIcon {
              anchors.centerIn: parent
              size: 14
              color: Color.urgent
              source: Qt.resolvedUrl("../../assets/icons/close.svg")
            }

            MouseArea {
              id: removeMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.removeTrack(trackRow.index)
            }

            ButtonToolTip {
              host: removeMa
              text: "Remove from playlist"
              fontFamily: root.fontFamily
            }
          }

          // Drag handle: three rules. The drag maps its travel through the
          // view root, where the row's own translate cancels out of the
          // mapping, so the carried row cannot feed back into the gesture.
          Item {
            width: 28
            height: 28

            Column {
              anchors.centerIn: parent
              spacing: 3

              Repeater {
                model: 3

                Rectangle {
                  width: 16
                  height: 2
                  radius: 1
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, dragMa.containsMouse ? 0.9 : 0.5)
                }
              }
            }

            MouseArea {
              id: dragMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: dragMa.pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
              // The ListView must not steal the gesture as a flick.
              preventStealing: true
              onPressed: function(mouse) {
                root.dragFrom = trackRow.index
                root.dragStartY = dragMa.mapToItem(root, mouse.x, mouse.y).y
                root.dragY = 0
              }
              onPositionChanged: function(mouse) {
                if (!dragMa.pressed) return
                root.dragY = dragMa.mapToItem(root, mouse.x, mouse.y).y - root.dragStartY
              }
              onReleased: root.finishDrag()
              onCanceled: root.finishDrag()
            }

            ButtonToolTip {
              host: dragMa
              text: "Drag to reorder"
              fontFamily: root.fontFamily
            }
          }
        }
      }

      CursorRules {
        anchors.fill: parent
        shown: trackRow.hasCursor
      }

      HoverHandler {
        id: trackRowHover
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onHoveredChanged: {
          if (hovered) root.rowHovered(trackRow.index)
          else root.rowUnhovered(trackRow.index)
        }
      }

      MouseArea {
        id: trackRowMa
        anchors.fill: parent
        z: -1
        hoverEnabled: true
        cursorShape: (root.editMode || !trackRow.isAvailable) ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: {
          if (root.editMode) {
            // Pick the row and hand the keyboard back, so the list
            // shortcuts (Shift+move, Del) work on it right away.
            root.beginKeyboardNav()
            root.cursorIndex = trackRow.index
            root.keyboardRequested()
            return
          }
          if (!trackRow.isAvailable) return
          root.playTrack(trackRow.index)
        }
      }
    }

    footer: Item {
      width: playlistFlickable.width
      height: root.footerHeight

      Column {
        id: footerCol
        x: Design.pageGutter
        y: Style.space(8)
        width: parent.width - 2 * Design.pageGutter

        // Album copyright, below the track list.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.itemType === "album" && root.albumCopyright !== ""
          text: root.albumCopyright
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption || 10
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          topPadding: Style.space(4)
        }
      }
    }
  }

}