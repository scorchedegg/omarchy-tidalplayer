import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../components"
import "../lib/Design.js" as Design
import "../lib/Format.js" as Format

// The artist's full "Top Tracks" list. Other song list pages open with a
// centered square cover; this one opens with the "Top Tracks" heading and the
// artist credit in the top bar (PlayerHeader), so it is obvious whose tracks
// these are and one tap leads back to the artist page.
Item {
  id: root
  layer.enabled: true

  property bool alive: true
  Component.onDestruction: root.alive = false

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  property real bottomInset: 0
  // Floating PlayerHeader height and the fixed track-row rhythm.
  readonly property int topBarHeight: 52
  // 50 px of content with the old 1 px seam split into 1 px above and below.
  readonly property int rowHeight: 52
  readonly property int rowSpacing: 0

  // Header + rows, excluding the dock padding. The footer only appears when
  // the list actually overflows the area above the collapsed player.
  readonly property real naturalContentHeight: {
    if (!topTracksFlickable || !topTracksFlickable.headerItem) return 0
    return topTracksFlickable.headerItem.height
      + Math.max(0, topTracksFlickable.count) * (root.rowHeight + root.rowSpacing)
  }
  readonly property real footerHeight: {
    if (!topTracksFlickable) return 0
    return root.naturalContentHeight > Math.max(0, topTracksFlickable.height - root.bottomInset)
      ? root.bottomInset + Style.space(16) : 0
  }

  property string artistId: ""
  property string artistName: ""
  property string artistArtUrl: ""
  property var artistData: null
  property int requestGeneration: 0
  property bool loading: false

  readonly property var tracks: root.artistData && root.artistData.top_tracks
    ? root.artistData.top_tracks : []
  readonly property string displayArtistId: root.artistId
  // The face can be opened from the artist page (a clean name) or from an
  // older queue context / recent item, where the title carries a
  // "Top Tracks" suffix. Strip it until the artist response lands.
  readonly property string displayArtistName: {
    if (root.artistData && root.artistData.name) return String(root.artistData.name)
    var name = String(root.artistName || "")
    return name.replace(/\s*(?:-\s*)?Top Tracks$/, "") || "Artist"
  }
  readonly property string displayArtistArtUrl: root.artistData && root.artistData.art_url
    ? root.artistData.art_url : root.artistArtUrl

  signal artistSelected(string id, string name, string artUrl)
  signal playbackStarted()
  signal trackSelected(var track, int index)
  signal currentTrackClicked()

  function topTracksContext() {
    return {
      type: "artistTopTracks",
      id: root.displayArtistId,
      title: "Top Tracks: " + root.displayArtistName,
      // The recent-items card wants just the artist, with the type label
      // "Top Tracks" underneath; the playing-from string keeps both.
      recentTitle: root.displayArtistName,
      artUrl: root.displayArtistArtUrl
    }
  }

  function loadTracks() {
    var generation = ++root.requestGeneration
    var requestedId = root.artistId
    var isCurrentRequest = function() {
      return root && root.alive && generation === root.requestGeneration && requestedId === root.artistId
    }
    if (!root.svc) {
      root.loading = false
      return
    }
    root.artistData = null
    if (!requestedId) {
      root.loading = false
      return
    }
    root.loading = true
    root.svc.fetchArtist(requestedId, function(data) {
      if (!isCurrentRequest()) return
      if (data) root.artistData = data
      root.loading = false
    })
  }

  onArtistIdChanged: root.loadTracks()
  onSvcChanged: if (root.svc && visible) root.loadTracks()
  onVisibleChanged: {
    if (visible && root.svc && !root.artistData && root.artistId !== "" && !root.loading) {
      root.loadTracks()
    }
  }
  Component.onCompleted: if (root.visible) root.loadTracks()

  // Called by MiniPlayer on fresh navigation (push/setFace). Back-navigation
  // leaves the Flickable alone so the user returns to where they were.
  function scrollToTop() {
    scrollHandler.reset()
    // ListView headers sit above contentY 0, so positionViewAtBeginning()
    // includes the header where a plain contentY = 0 would skip it.
    topTracksFlickable.positionViewAtBeginning()
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
    var playable = Format.playableTracks(root.tracks, 0).tracks
    if (playable.length === 0) return
    var ctxObj = root.topTracksContext()
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
    root.svc.playContext(root.tracks, index, root.topTracksContext())
    root.trackSelected(track, index)
  }

  function firstVisibleIndex() {
    if (root.tracks.length === 0) return -1
    var stride = root.rowHeight + root.rowSpacing
    // ListView rows start at content y = 0; the header sits above at the
    // negative origin. Pick the row under the floating top bar, or the first
    // row while the header is still on screen.
    var viewTop = topTracksFlickable.contentY + root.topBarHeight
    return Math.max(0, Math.min(root.tracks.length - 1, Math.floor(Math.max(0, viewTop) / stride)))
  }

  function moveCursor(dx, dy) {
    if (dy === 0 || root.tracks.length === 0) return
    root.beginKeyboardNav()
    if (root.cursorIndex < 0) {
      root.cursorIndex = root.firstVisibleIndex()
      root.ensureCursorVisible()
      return
    }
    root.cursorIndex = Math.max(0, Math.min(root.tracks.length - 1, root.cursorIndex + dy))
    root.ensureCursorVisible()
  }

  function pageCursor(direction) {
    if (root.tracks.length === 0) return
    root.beginKeyboardNav()
    var rows = Math.max(1, Math.floor((topTracksFlickable.height - root.topBarHeight - root.bottomInset) / (root.rowHeight + root.rowSpacing)) - 1)
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
    if (root.cursorIndex < 0 || root.cursorIndex >= root.tracks.length) {
      // No selection: Enter plays the list, Shift+Enter shuffles it.
      root.playAll(shift)
      return
    }
    root.playTrack(root.cursorIndex)
  }

  function ensureCursorVisible() {
    if (root.cursorIndex < 0) return
    var stride = root.rowHeight + root.rowSpacing
    var row = topTracksFlickable.itemAtIndex(root.cursorIndex)
    var top = row ? row.mapToItem(topTracksFlickable.contentItem, 0, 0).y : root.cursorIndex * stride
    var bottom = top + root.rowHeight
    // Content scrolls under the floating top bar, so the usable viewport
    // starts below it.
    var viewTop = topTracksFlickable.contentY + root.topBarHeight
    // Keep the row above the collapsed player docked at the bottom.
    var viewBottom = topTracksFlickable.contentY + topTracksFlickable.height - root.bottomInset
    var margin = Style.space(8)
    var target = topTracksFlickable.contentY
    if (top - margin < viewTop) target = top - margin - root.topBarHeight
    else if (bottom + margin > viewBottom) target = bottom + margin - (topTracksFlickable.height - root.bottomInset)
    var maxY = Design.maxScrollY(topTracksFlickable.originY, topTracksFlickable.contentHeight, topTracksFlickable.height)
    target = Math.max(topTracksFlickable.originY, Math.min(maxY, target))
    if (Math.abs(target - topTracksFlickable.contentY) < 1) return
    scrollHandler.reset()
    topTracksFlickable.contentY = target
  }

  ListView {
    id: topTracksFlickable
    anchors.fill: parent
    // Rows paint their fill over the panel's full width (see Design.pageGutter).
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    spacing: 0
    model: root.tracks
    cacheBuffer: Style.space(320)

    SmoothScrollHandler { id: scrollHandler }

    // Header rows settle a frame after the page opens; keep the top pinned.
    ScrollAnchor { }

    header: Item {
      width: topTracksFlickable.width
      // Leave the same 14 px visual gap before the first row that the old
      // Column placed between the page header and the track list; the row's
      // own 1 px top padding supplies the rest.
      height: mainCol.implicitHeight + Style.space(14) - 1

      Column {
        id: mainCol
        width: topTracksFlickable.width - 2 * Design.pageGutter
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(14)

        // Clear the floating header.
        Item {
          width: parent.width
          height: Design.headerClearance
        }

        // Page heading. The artist credit lives in the top bar (PlayerHeader) on
        // artist sub-pages, beside the back button.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "Top Tracks"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading + 4
          font.weight: Font.Bold
          horizontalAlignment: Text.AlignHCenter
          // The Play / Shuffle pills carry no margin of their own, while the
          // discography page's filter pills bring Style.space(8) inside
          // ReleaseFilters -- give the heading the same air for free.
          bottomPadding: Style.space(8)
          elide: Text.ElideRight
        }

        // Play / Shuffle pills.
        RowLayout {
          width: parent.width
          spacing: 12

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

        // Loading indicator, centered in the blank area below the pills.
        Item {
          width: parent.width
          height: root.loading
            ? Math.max(40, topTracksFlickable.height - y - root.bottomInset - Style.space(24))
            : 0
          visible: height > 0

          TidalLogo {
            anchors.centerIn: parent
            size: 32
            color: root.foreground
            pulsing: root.loading
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: !root.loading && root.tracks.length === 0
          text: "No top tracks available"
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

      readonly property bool isCurrent: root.svc && String(root.svc.currentTrackId || "") === String(trackRow.modelData.id || "")
      readonly property bool isAvailable: Format.isTrackAvailable(trackRow.modelData)
      readonly property bool hasCursor: root.keyboardNav && root.cursorIndex === trackRow.index
      readonly property bool hovered: trackRowHover.hovered && !root.keyboardNav
      width: topTracksFlickable.width
      height: root.rowHeight
      // Full-bleed band: the fill and the click target reach the panel edges,
      // the row's content stays on Design.pageGutter.
      radius: 0
      color: trackRow.hasCursor
        ? Style.hoverFillFor(root.foreground, Color.accent)
        : (trackRow.isCurrent
          ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.15)
          : "transparent")

      HoverFill {
        anchors.fill: parent
        tint: trackRow.isCurrent ? Color.accent : root.foreground
        strength: 0.08
        active: trackRow.hovered && trackRow.isAvailable
        instant: root.keyboardNav
      }

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Design.pageGutter
        anchors.rightMargin: Design.pageGutter
        spacing: 10
        opacity: trackRow.isAvailable ? 1.0 : 0.4

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
              id: trackTitle
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
              anchors.verticalCenter: trackTitle.verticalCenter
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
            enabled: trackRow.isAvailable
            interactive: trackRow.isAvailable
            artists: trackRow.modelData.artists || []
            fallbackText: trackRow.modelData.artist || root.displayArtistName
            fallbackArtistId: trackRow.modelData.artist_id || root.displayArtistId
            foreground: root.foreground
            textOpacity: trackRow.isCurrent ? 0.85 : 0.6
            fontFamily: root.fontFamily
            fontPixelSize: Style.font.caption || 10
            onArtistClicked: function(id, name) { root.artistSelected(id, name, "") }
          }
        }

        EqualizerBars {
          Layout.alignment: Qt.AlignVCenter
          visible: trackRow.isCurrent && Boolean(root.svc && root.svc.playing)
          playing: Boolean(root.svc && root.svc.playing)
          barColor: Color.accent
          width: 12
          height: 12
        }

        Text {
          Layout.alignment: Qt.AlignVCenter
          Layout.preferredWidth: implicitWidth
          textFormat: Text.PlainText
          text: trackRow.modelData.duration ? Format.formatDuration(trackRow.modelData.duration) : ""
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption || 10
          visible: text !== ""
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
        cursorShape: trackRow.isAvailable ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: if (trackRow.isAvailable) root.playTrack(trackRow.index)
      }
    }

    footer: Item {
      width: topTracksFlickable.width
      height: root.footerHeight
    }
  }

}
