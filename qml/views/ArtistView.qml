import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../components"
import "../lib/Design.js" as Design
import "../lib/Format.js" as Format

Item {
  id: root
  layer.enabled: true

  property bool alive: true
  Component.onDestruction: {
    root.alive = false
    loadTimer.stop()
  }

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  property real bottomInset: 0
  readonly property int topBarHeight: 52

  property string artistId: ""
  property string artistName: ""
  property string artistArtUrl: ""
  property var artistData: null
  property string resolvedArtistId: ""
  property int requestGeneration: 0
  property bool following: false

  property var topTracks: []
  property var releases: []
  // "popular", "albums", "eps" or "live"; the pill row owns the choice.
  property string releaseFilter: "popular"
  property bool loading: false

  readonly property var filteredReleases: Format.filterReleases(root.releases, root.releaseFilter)
  readonly property var releaseFilterOptions: Format.releaseFilterOptions()
  readonly property var emptyReleaseFilters: Format.emptyReleaseFilters(root.releases)
  readonly property string latestReleaseId: root.releases.length > 0 ? String(root.releases[0].id || "") : ""

  readonly property string displayArtistId: root.artistId || root.resolvedArtistId
  readonly property string displayArtistName: root.artistData && root.artistData.name ? root.artistData.name : root.artistName
  readonly property string displayArtistArtUrl: root.artistData && root.artistData.art_url ? root.artistData.art_url : root.artistArtUrl
  readonly property string fanInfo: root.artistData && root.artistData.fans ? root.artistData.fans : ""
  readonly property string artistDescription: root.artistData && root.artistData.description ? root.artistData.description : ""
  // On a dark theme the hero name reads best in pure white rather than the
  // theme's tinted foreground; light themes keep their dark text colour.
  readonly property bool darkTheme: Design.luminance(Color.popups.background) < 0.5
  readonly property color heroNameColor: root.darkTheme ? "white" : root.foreground

  // 1 while the hero photo is under the floating header, fading to 0 as the
  // header scrolls past it onto the flat page background. PlayerHeader uses
  // this to fade its buttons towards the flat-page surface.
  readonly property real headerArtworkProgress: {
    var stripBottom = artistFlickable.contentY + 52
    var fadeStart = heroPhotoWrapper.height * 0.45
    var fadeEnd = heroPhotoWrapper.height * 0.9
    return Math.max(0, Math.min(1, (fadeEnd - stripBottom) / (fadeEnd - fadeStart)))
  }

  signal trackSelected(var track, int index)
  signal currentTrackClicked()
  signal playbackStarted()
  signal albumSelected(string id, string title, string artUrl)
  signal artistSelected(string id, string name)
  signal topTracksRequested(string id, string name, string artUrl)
  // Open the full discography on the pill the artist page is showing.
  signal releasesRequested(string filter, string id, string name, string artUrl)
  signal radioRequested(string id, string name, string artUrl)
  signal menuRequested()
  signal bioRequested()

  Timer {
    id: loadTimer
    interval: 0
    repeat: false
    onTriggered: if (root.alive) root.loadArtist()
  }

  function scheduleLoad() {
    loadTimer.restart()
  }

  function loadArtist() {
    loadTimer.stop()
    var generation = ++root.requestGeneration
    var requestedId = root.artistId
    var requestedName = root.artistName
    var isCurrentRequest = function() {
      return root && root.alive
        && generation === root.requestGeneration
        && requestedId === root.artistId
        && requestedName === root.artistName
    }
    if (!root.svc) {
      root.loading = false
      return
    }
    root.artistData = null
    root.resolvedArtistId = ""
    root.topTracks = []
    root.releases = []
    root.releaseFilter = "popular"
    root.following = false
    if (!requestedId && requestedName) {
      root.loading = true
      root.svc.search(requestedName, function(results) {
        if (!isCurrentRequest()) return
        if (results && results.artists && results.artists.length > 0) {
          root.resolvedArtistId = String(results.artists[0].id || "")
          if (root.resolvedArtistId) fetchArtist(root.resolvedArtistId)
          else root.loading = false
        } else {
          root.loading = false
        }
      })
      return
    }
    if (!requestedId) {
      root.loading = false
      return
    }
    root.loading = true
    fetchArtist(requestedId)

    function fetchArtist(id) {
      root.svc.fetchArtist(id, function(data) {
        if (!isCurrentRequest() || String((data && data.id) || id) !== id) return
        if (data) {
          root.artistData = data
          root.topTracks = data.top_tracks || []
          root.releases = data.releases || []
          root.following = !!data.favorite
        }
        root.loading = false
      })
    }
  }

  // Follow/Following toggles the artist in the user's collection.
  function toggleFollow() {
    if (!root.svc || !root.displayArtistId) return
    var generation = root.requestGeneration
    var targetId = root.displayArtistId
    var next = !root.following
    root.following = next
    root.svc.toggleEntityFavorite("artist", targetId, function(err, data) {
      if (!root || !root.alive || !root.svc) return
      if (generation !== root.requestGeneration || targetId !== root.displayArtistId) return
      if (err || !data || data.favorite === undefined) {
        root.following = !next
        root.svc.notify("Could not update following")
      } else {
        root.following = !!data.favorite
      }
    })
  }

  function openRadio() {
    if (!root.svc || !root.displayArtistId) return
    root.radioRequested(root.displayArtistId, root.displayArtistName, root.displayArtistArtUrl)
  }

  function shareArtist() {
    if (!root.svc) return
    root.svc.shareArtist(root.displayArtistId, root.displayArtistName, root.displayArtistArtUrl)
  }

  // Items and preview row for the shared bottom-sheet ContextMenu (owned by
  // MiniPlayer so it can cover the floating header).
  function entityMenuItems() {
    var items = []
    items.push({
      action: "follow",
      label: root.following ? "Unfollow" : "Follow",
      icon: root.following
        ? Qt.resolvedUrl("../../assets/icons/check.svg")
        : Qt.resolvedUrl("../../assets/icons/follow.svg"),
      destructive: root.following
    })
    if (root.artistDescription !== "") {
      items.push({ action: "bio", label: "Bio", icon: Qt.resolvedUrl("../../assets/icons/info.svg") })
    }
    items.push({ action: "share", label: "Share", icon: Qt.resolvedUrl("../../assets/icons/share.svg") })
    items.push({ action: "radio", label: "Go to artist radio", icon: Qt.resolvedUrl("../../assets/icons/mixes.svg") })
    return items
  }

  function entityMenuHeader() {
    return {
      artUrl: root.displayArtistArtUrl,
      title: root.displayArtistName,
      subtitle: root.fanInfo,
      roundArt: true
    }
  }

  function handleMenuAction(action) {
    if (action === "follow") root.toggleFollow()
    else if (action === "bio") root.bioRequested()
    else if (action === "share") root.shareArtist()
    else if (action === "radio") root.openRadio()
  }

  onArtistIdChanged: root.scheduleLoad()
  onArtistNameChanged: root.scheduleLoad()
  onSvcChanged: if (root.svc && visible) root.scheduleLoad()
  onVisibleChanged: if (visible && root.svc && !root.artistData && !root.loading && (root.artistId !== "" || root.artistName !== "")) root.scheduleLoad()

  // Called by MiniPlayer on fresh navigation (push/setFace). Back-navigation
  // leaves the Flickable alone so the user returns to where they were.
  function scrollToTop() {
    scrollHandler.reset()
    if (artistFlickable.contentY !== 0) artistFlickable.contentY = 0
  }

  // ---- Keyboard cursor --------------------------------------------------------

  property int cursorIndex: -1
  readonly property int trackCount: Math.min(5, root.topTracks.length)
  // Four cards preview the chosen pill; the full grid lives on the
  // Discography page opened by "View all".
  readonly property int releaseCount: Math.min(4, root.filteredReleases.length)
  readonly property int cursorCount: root.trackCount + root.releaseCount

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

  // A filter can shorten the grid under the cursor, so start over.
  onReleaseFilterChanged: root.resetCursor()

  function playAll(shuffle) {
    if (!root.svc || root.topTracks.length === 0) return
    var playable = Format.playableTracks(root.topTracks, 0).tracks
    if (playable.length === 0) return
    var ctxObj = { type: "artistTopTracks", id: root.displayArtistId, title: "Top Tracks: " + root.displayArtistName, recentTitle: root.displayArtistName, artUrl: root.displayArtistArtUrl }
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
    if (!root.svc || index < 0 || index >= root.topTracks.length) return
    var track = root.topTracks[index]
    if (!Format.isTrackAvailable(track)) return
    if (root.isCurrentTrack(track)) {
      root.currentTrackClicked()
      return
    }
    var ctxObj = { type: "artistTopTracks", id: root.displayArtistId, title: "Top Tracks: " + root.displayArtistName, recentTitle: root.displayArtistName, artUrl: root.displayArtistArtUrl }
    root.svc.playContext(root.topTracks, index, ctxObj)
    root.trackSelected(track, index)
  }

  function cursorItem(index) {
    if (index < 0) return null
    if (index < root.trackCount) return topTrackRepeater.itemAt(index)
    return releaseRepeater.itemAt(index - root.trackCount)
  }

  function firstVisibleIndex() {
    var viewTop = artistFlickable.contentY + root.topBarHeight
    for (var i = 0; i < root.cursorCount; i++) {
      var item = root.cursorItem(i)
      if (item && item.mapToItem(artistFlickable.contentItem, 0, 0).y + item.height > viewTop + 1) return i
    }
    return 0
  }

  function moveCursor(dx, dy) {
    if (root.cursorCount === 0) return
    root.beginKeyboardNav()
    if (root.cursorIndex < 0) {
      root.cursorIndex = root.firstVisibleIndex()
      root.ensureCursorVisible()
      return
    }
    var idx = root.cursorIndex
    if (idx < root.trackCount) {
      // Top tracks are a single column; down from the last one enters the
      // discography grid.
      if (dy > 0) idx = (idx + 1 < root.trackCount) ? idx + 1 : root.trackCount
      else if (dy < 0 && idx > 0) idx -= 1
    } else {
      // The discography preview is a two-column grid.
      var rel = idx - root.trackCount
      if (dy !== 0) {
        var next = rel + dy * 2
        if (next < 0) idx = root.trackCount - 1
        else if (next >= root.releaseCount) idx = root.trackCount + root.releaseCount - 1
        else idx = root.trackCount + next
      } else if (dx < 0) {
        if (rel % 2 === 1) idx = root.trackCount + rel - 1
      } else if (dx > 0) {
        if (rel % 2 === 0 && rel + 1 < root.releaseCount) idx = root.trackCount + rel + 1
      }
    }
    root.cursorIndex = Math.max(0, Math.min(root.cursorCount - 1, idx))
    root.ensureCursorVisible()
  }

  function pageCursor(direction) {
    if (root.cursorCount === 0) return
    root.beginKeyboardNav()
    if (root.cursorIndex < 0) root.cursorIndex = root.firstVisibleIndex()
    else root.cursorIndex = Math.max(0, Math.min(root.cursorCount - 1, root.cursorIndex + direction * 2))
    root.ensureCursorVisible()
  }

  function homeEndCursor(toEnd) {
    if (root.cursorCount === 0) return
    root.beginKeyboardNav()
    root.cursorIndex = toEnd ? root.cursorCount - 1 : 0
    root.ensureCursorVisible()
  }

  function activateCursor(shift) {
    if (root.cursorIndex < 0) {
      // No selection: Enter plays the top tracks, Shift+Enter shuffles them.
      root.playAll(shift)
      return
    }
    if (root.cursorIndex < root.trackCount) {
      root.playTrack(root.cursorIndex)
    } else {
      var release = root.filteredReleases[root.cursorIndex - root.trackCount]
      if (release) root.albumSelected(String(release.id || ""), String(release.title || ""), String(release.art_url || ""))
    }
  }

  function ensureCursorVisible() {
    var item = root.cursorItem(root.cursorIndex)
    if (!item) return
    var top = item.mapToItem(artistFlickable.contentItem, 0, 0).y
    var bottom = top + item.height
    var viewTop = artistFlickable.contentY + root.topBarHeight
    // Keep the row above the collapsed player docked at the bottom.
    var viewBottom = artistFlickable.contentY + artistFlickable.height - root.bottomInset
    var margin = Style.space(8)
    var target = artistFlickable.contentY
    if (top - margin < viewTop) target = top - margin - root.topBarHeight
    else if (bottom + margin > viewBottom) target = bottom + margin - (artistFlickable.height - root.bottomInset)
    var maxY = Math.max(0, artistFlickable.contentHeight - artistFlickable.height)
    target = Math.max(0, Math.min(maxY, target))
    if (Math.abs(target - artistFlickable.contentY) < 1) return
    scrollHandler.reset()
    artistFlickable.contentY = target
  }
  // The artist page is the only thing its Share tile can share, so the photo is
  // kept in the file that tile sends.
  onDisplayArtistArtUrlChanged: if (root.svc) root.svc.warmShareArt("view", root.displayArtistArtUrl)
  Component.onCompleted: {
    if (root.visible) root.scheduleLoad()
    if (root.svc) root.svc.warmShareArt("view", root.displayArtistArtUrl)
  }

  Flickable {
    id: artistFlickable
    anchors.fill: parent
    contentWidth: width
    contentHeight: Design.scrollContentHeight(contentCol.implicitHeight, artistFlickable.height, root.bottomInset, 16)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick

    SmoothScrollHandler { id: scrollHandler }

    Column {
      id: contentCol
      width: parent.width
                spacing: Style.space(10)

      // 1. Hero Photography Banner
      Item {
        id: heroContainer
        width: parent.width
        height: Math.max(360, heroContentCol.implicitHeight + 140)

        // Fixed-size photography header so hero image never extends, shifts, or zooms
        Item {
          id: heroPhotoWrapper
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: 360
          clip: true
          layer.enabled: true

          // Art handed over from the previous view stays put while the
          // higher-resolution detail image decodes, so the hero never blanks
          // out mid-load.
          Image {
            id: heroFallbackPhoto
            anchors.fill: parent
            source: root.artistArtUrl
            fillMode: Image.PreserveAspectCrop
            verticalAlignment: Image.AlignTop
            sourceSize.width: 750
            sourceSize.height: 750
            asynchronous: true
            visible: source !== ""
          }

          Image {
            id: heroPhoto
            anchors.fill: parent
            source: (root.artistData && root.artistData.art_url) ? root.artistData.art_url : ""
            fillMode: Image.PreserveAspectCrop
            verticalAlignment: Image.AlignTop
            sourceSize.width: 750
            sourceSize.height: 750
            asynchronous: true
            opacity: status === Image.Ready ? 1 : 0
            visible: opacity > 0.01

            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
          }

          // Gradient fade to background at bottom of photography
          Rectangle {
            anchors.fill: parent
            gradient: Gradient {
              GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.25) }
              GradientStop { position: 0.25; color: "transparent" }
              GradientStop { position: 0.40; color: Qt.rgba(0, 0, 0, 0.2) }
              GradientStop { position: 0.55; color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.72) }
              GradientStop { position: 0.75; color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.94) }
              GradientStop { position: 0.92; color: Color.popups.background }
              GradientStop { position: 1.0; color: Color.popups.background }
            }
          }
        }

        // Seamless background fill if the hero runs taller than the photo.
        Rectangle {
          anchors.top: heroPhotoWrapper.bottom
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          color: Color.popups.background
          visible: parent.height > 360
          z: -1
        }

        // Artist Name, Fan Count & Action Buttons overlay
        Column {
          id: heroContentCol
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 8
          width: parent.width - 2 * Design.pageGutter
          spacing: 6

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.displayArtistName || "Artist"
            color: root.heroNameColor
            font.family: root.fontFamily
            font.pixelSize: 28
            font.weight: Font.Bold
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.fanInfo
            color: root.foreground
            opacity: 0.72
            font.family: root.fontFamily
            font.pixelSize: 12
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
            visible: text !== ""
          }

          // Artist Write-up lives in the context menu's Bio sheet now, so the
          // hero stays uncluttered.

          Item {
            width: parent.width
            height: 4
          }

          // Action Pill Buttons Row: [ Play ] and [ Shuffle ]
          RowLayout {
            width: parent.width
            spacing: 12

            // Play Pill
            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: 40
              radius: 20
              color: playPillMa.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.88) : root.foreground

              RowLayout {
                anchors.centerIn: parent
                spacing: 8

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

            // Shuffle Pill
            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: 40
              radius: 20
              color: shufPillMa.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.09)

              RowLayout {
                anchors.centerIn: parent
                spacing: 8

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

          // Extra breathing room above the quick actions, tighter below.
          Item {
            width: parent.width
            height: 8
          }

          // Quick actions row: Follow/Following, Artist Radio, Share, More.
          RowLayout {
            width: parent.width
            spacing: 2

            ActionTile {
              foreground: root.foreground
              fontFamily: root.fontFamily
              label: root.following ? "Following" : "Follow"
              iconSource: root.following
                ? Qt.resolvedUrl("../../assets/icons/check.svg")
                : Qt.resolvedUrl("../../assets/icons/follow.svg")
              iconColor: root.following ? Color.accent : root.foreground
              onTriggered: root.toggleFollow()
            }

            ActionTile {
              foreground: root.foreground
              fontFamily: root.fontFamily
              label: "Radio"
              iconSource: Qt.resolvedUrl("../../assets/icons/mixes.svg")
              iconColor: root.foreground
              onTriggered: root.openRadio()
            }

            ActionTile {
              foreground: root.foreground
              fontFamily: root.fontFamily
              label: "Share"
              iconSource: Qt.resolvedUrl("../../assets/icons/share.svg")
              iconColor: root.foreground
              onTriggered: root.shareArtist()
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
      }

      // Loading indicator — centered in the blank area below the artist hero
      Item {
        width: parent.width
        height: root.loading
          ? Math.max(40, artistFlickable.height - y - root.bottomInset - Style.space(24))
          : 0
        visible: height > 0

        TidalLogo {
          anchors.centerIn: parent
          size: 32
          color: root.foreground
          pulsing: root.loading
        }
      }

      // 3. Top Tracks Section
      Column {
        width: parent.width - 2 * Design.pageGutter
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)
        visible: root.topTracks.length > 0

        RowLayout {
          width: parent.width
          spacing: 8

          Text {
            textFormat: Text.PlainText
            text: "Top Tracks"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle || 15
            font.weight: Font.Bold
          }

          Item { Layout.fillWidth: true }

          ViewAllButton {
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.topTracksRequested(root.displayArtistId, root.displayArtistName, root.displayArtistArtUrl)
          }
        }

        Column {
          width: parent.width
          spacing: 0

          Repeater {
            id: topTrackRepeater
            model: root.topTracks.slice(0, 5)

            Rectangle {
              id: topTrackRow
            required property var modelData
            required property int index

            readonly property bool isCurrent: root.svc && String(root.svc.currentTrackId || "") === String(topTrackRow.modelData.id || "")
            readonly property bool isAvailable: Format.isTrackAvailable(topTrackRow.modelData)
            readonly property bool hasCursor: root.keyboardNav && root.cursorIndex === topTrackRow.index
            readonly property bool hovered: topTrackHover.hovered && !root.keyboardNav
            // Full-bleed band: the fill and the click target reach the panel
            // edges, the row's content stays on Design.pageGutter.
            x: -Design.pageGutter
            width: parent.width + 2 * Design.pageGutter
            height: 50
            radius: 0
            color: topTrackRow.hasCursor
              ? Style.hoverFillFor(root.foreground, Color.accent)
              : (topTrackRow.isCurrent
                ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.15)
                : "transparent")

            HoverFill {
              anchors.fill: parent
              tint: topTrackRow.isCurrent ? Color.accent : root.foreground
              strength: 0.08
              active: topTrackRow.hovered && topTrackRow.isAvailable
              instant: root.keyboardNav
            }

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Design.pageGutter
              anchors.rightMargin: Design.pageGutter
              spacing: 10
              opacity: topTrackRow.isAvailable ? 1.0 : 0.4

              // Thumbnail
              Rectangle {
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: 36
                Layout.preferredHeight: 36
                radius: 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
                border.width: 1
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

                RoundedImage {
                  id: rowArt
                  anchors.fill: parent
                  radius: 2
                  borderWidth: 1
                  borderColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
                  source: topTrackRow.modelData.art_url || ""
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

              // Title and Album
              Column {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.alignment: Qt.AlignVCenter
                spacing: 2
                clip: true

                Row {
                  width: parent.width
                  spacing: 4

                  FadeText {
                    id: artistTrackTitle
                    textFormat: Text.PlainText
                    text: topTrackRow.modelData.title || ""
                    color: topTrackRow.isCurrent ? Color.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall || 12
                    font.weight: topTrackRow.isCurrent ? Font.Bold : Font.DemiBold
                    width: Math.min(implicitWidth, Math.max(0, parent.width - (topTrackRow.modelData.explicit ? 18 : 0)))
                  }

                  Rectangle {
                    width: 12
                    height: 12
                    radius: 2
                    anchors.verticalCenter: artistTrackTitle.verticalCenter
                    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
                    visible: !!topTrackRow.modelData.explicit

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
                  enabled: topTrackRow.isAvailable
                  interactive: topTrackRow.isAvailable
                  artists: topTrackRow.modelData.artists || []
                  fallbackText: topTrackRow.modelData.artist || root.displayArtistName
                  fallbackArtistId: topTrackRow.modelData.artist_id || root.displayArtistId
                  foreground: root.foreground
                  textOpacity: topTrackRow.isCurrent ? 0.85 : 0.6
                  fontFamily: root.fontFamily
                  fontPixelSize: Style.font.caption || 10
                  onArtistClicked: function(id, name) { root.artistSelected(id, name) }
                }
              }

              // Playing indicator for current track
              EqualizerBars {
                Layout.alignment: Qt.AlignVCenter
                visible: topTrackRow.isCurrent && Boolean(root.svc && root.svc.playing)
                playing: Boolean(root.svc && root.svc.playing)
                barColor: Color.accent
                width: 12
                height: 12
              }

              // Duration
              Text {
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: implicitWidth
                textFormat: Text.PlainText
                text: topTrackRow.modelData.duration ? Format.formatDuration(topTrackRow.modelData.duration) : ""
                color: root.foreground
                opacity: 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption || 10
                visible: text !== ""
              }
            }

            CursorRules {
              anchors.fill: parent
              shown: topTrackRow.hasCursor
            }

            HoverHandler {
              id: topTrackHover
              acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
              onHoveredChanged: {
                if (hovered) root.rowHovered(topTrackRow.index)
                else root.rowUnhovered(topTrackRow.index)
              }
            }

            MouseArea {
              id: topTrackMa
              anchors.fill: parent
              z: -1
              hoverEnabled: true
              cursorShape: topTrackRow.isAvailable ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: if (topTrackRow.isAvailable) root.playTrack(topTrackRow.index)
            }
          }
        }
        }
      }

      // 4. Discography (TIDAL mixes albums, EPs and singles in one feed)
      Column {
        width: parent.width - 2 * Design.pageGutter
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(8)
        visible: root.releases.length > 0
        // Extra air above the section heading.
        topPadding: Style.space(10)

        RowLayout {
          width: parent.width
          spacing: 8

          Text {
            textFormat: Text.PlainText
            text: "Discography"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle || 15
            font.weight: Font.Bold
          }

          Item { Layout.fillWidth: true }

          ViewAllButton {
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.releasesRequested(root.releaseFilter, root.displayArtistId, root.displayArtistName, root.displayArtistArtUrl)
          }
        }

        ReleaseFilters {
          width: parent.width
          foreground: root.foreground
          fontFamily: root.fontFamily
          options: root.releaseFilterOptions
          currentFilter: root.releaseFilter
          disabledKeys: root.emptyReleaseFilters
          onFilterSelected: function(key) { root.releaseFilter = key }
        }

        Grid {
          id: releasesGrid
          // The cards overhang the content line by their own padding, so the
          // artwork inside them lines up with the section heading while the
          // padded card background runs past the line (see Design.pageGutter).
          readonly property int cardPadding: Style.space(6)
          x: -cardPadding
          width: parent.width + 2 * cardPadding
          columns: 2
          // 4 + a 6px card padding on each side leaves 16px between the
          // artworks, the same air the page gutter gives them at either edge.
          spacing: Style.space(4)

          Repeater {
            id: releaseRepeater
            model: root.filteredReleases.slice(0, 4)

            Rectangle {
              id: releaseCard
              required property var modelData
              required property int index
              readonly property bool hasCursor: root.keyboardNav && root.cursorIndex === root.trackCount + releaseCard.index
              readonly property bool hovered: releaseMa.containsMouse && !root.keyboardNav

              width: Math.floor((releasesGrid.width - releasesGrid.spacing) / 2)
              height: width + 42
              radius: 0
              border.color: releaseCard.hasCursor ? Color.accent : "transparent"
              border.width: releaseCard.hasCursor ? 1 : 0
              color: releaseCard.hasCursor
                ? Style.hoverFillFor(root.foreground, Color.accent)
                : "transparent"

              HoverFill {
                anchors.fill: parent
                tint: root.foreground
                strength: 0.1
                active: releaseCard.hovered
                instant: root.keyboardNav
              }

              Column {
                anchors.fill: parent
                anchors.margins: releasesGrid.cardPadding
                spacing: Style.space(3)

                Rectangle {
                  width: parent.width
                  height: width
                  radius: 0
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
                  border.width: 1
                  border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

                  RoundedImage {
                    id: cardArt
                    anchors.fill: parent
                    radius: 0
                    borderWidth: 1
                    borderColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
                    source: releaseCard.modelData.art_url || ""
                    sourceSize.width: 180
                    sourceSize.height: 180
                    visible: source !== ""
                  }

                  TidalLogo {
                    anchors.centerIn: parent
                    size: 32
                    color: root.foreground
                    faint: true
                    visible: !cardArt.showingImage
                  }
                }

                FadeText {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: releaseCard.modelData.title || ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: 11
                  font.weight: Font.DemiBold
                  maximumLineCount: 1
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: Format.releaseSubtitle(releaseCard.modelData, String(releaseCard.modelData.id || "") === root.latestReleaseId)
                  color: root.foreground
                  opacity: 0.6
                  font.family: root.fontFamily
                  font.pixelSize: 10
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                id: releaseMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.rowHovered(root.trackCount + releaseCard.index)
                onExited: root.rowUnhovered(root.trackCount + releaseCard.index)
                onClicked: root.albumSelected(String(releaseCard.modelData.id || ""), String(releaseCard.modelData.title || ""), String(releaseCard.modelData.art_url || ""))
              }
            }
          }
        }
      }
    }
  }
}
