import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../components"
import "../lib/Design.js" as Design
import "../lib/Format.js" as Format

Item {
  id: root

  property bool alive: true
  Component.onDestruction: root.alive = false

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  property real bottomInset: 0
  readonly property var queueTracks: svc ? svc.queueTracks : []
  readonly property int currentIndex: svc ? svc.queueIndex : 0
  // Rows before the current one have already been played and render faded.
  readonly property real playedRowOpacity: 0.5
  property bool loading: false

  // The full queue is shown, including already played tracks. The current
  // track row (50 px tall, rows flush) is scrolled to sit two rows below the
  // floating top bar, clamped at the start and end of the queue.
  readonly property int rowHeight: 50
  readonly property int rowSpacing: 0
  readonly property int anchorRowsAbove: 2
  // Height of the floating PlayerHeader overlay. The page content starts
  // below it, then scrolls underneath it like the playlist pages.
  readonly property int topBarHeight: 52

  // Header + rows, excluding the dock padding. A queue that fits above the
  // collapsed player should not scroll at all.
  readonly property real naturalContentHeight: {
    if (!queueFlick || !queueFlick.headerItem) return 0
    return queueFlick.headerItem.height
      + Math.max(0, queueFlick.count) * (root.rowHeight + root.rowSpacing)
  }
  readonly property real footerHeight: {
    if (!queueFlick) return 0
    return root.naturalContentHeight > Math.max(0, queueFlick.height - root.bottomInset)
      ? root.bottomInset + 16 : 0
  }

  readonly property bool hasCurrentTrack: (queueTracks && queueTracks.length > currentIndex && currentIndex >= 0)
    || !!(svc && svc.title)

  signal trackSelected(int index)
  signal artistSelected(string id, string name)
  signal currentTrackClicked()

  // Fresh entry (a push, not a back) anchors the viewport to the current
  // track. Back-navigation keeps `contentY` and only re-anchors when the
  // current track moved while the queue was off screen.
  property bool pendingFreshEntry: false
  // Index the last time the queue was on screen, so a return can tell whether
  // the track advanced while the user was elsewhere.
  property int lastSeenIndex: -1
  // A row click/jump must not auto-scroll the queue to the row that was just
  // clicked; only playback changes initiated elsewhere re-anchor the view.
  property bool suppressAutoScroll: false
  property int refreshGeneration: 0

  function prepareFreshEntry() {
    root.pendingFreshEntry = true
  }

  function jumpTo(index) {
    if (!root.svc) return
    root.suppressAutoScroll = true
    root.svc.jump(index)
    root.suppressAutoScroll = false
  }

  function refresh() {
    var gen = ++root.refreshGeneration
    if (!root.svc) {
      root.loading = false
      return
    }
    root.loading = true
    root.svc.refreshQueue(function() {
      if (!root || !root.alive || gen !== root.refreshGeneration) return
      root.loading = false
    })
  }

  function scrollToCurrent(animated) {
    if (!root.visible || !queueFlick) return
    if (!root.queueTracks || root.queueTracks.length === 0) return
    var idx = Math.max(0, Math.min(root.currentIndex, root.queueTracks.length - 1))
    var stride = root.rowHeight + root.rowSpacing
    var row = queueFlick.itemAtIndex(idx)
    // Fallback for rows outside the ListView's materialised range. Delegates
    // start at content y = 0; the header occupies [originY, 0).
    var rowY = row ? row.mapToItem(queueFlick.contentItem, 0, 0).y : idx * stride
    var maxY = Design.maxScrollY(queueFlick.originY, queueFlick.contentHeight, queueFlick.height)
    // The header now scrolls with the content: the ListView top is the panel
    // top, so keep the two anchor rows below the floating top bar instead.
    var targetY = rowY - root.topBarHeight - root.anchorRowsAbove * stride
    // A partially-scrolled page header looks broken (its heading ends up
    // behind the top-bar buttons), so a fresh anchor either shows the header
    // completely or scrolls it out completely.
    if (targetY < 0) targetY = queueFlick.originY
    targetY = Math.max(queueFlick.originY, Math.min(targetY, maxY))
    scrollHandler.reset()
    currentScrollAnimation.stop()
    if (Math.abs(queueFlick.contentY - targetY) < 1) {
      queueFlick.contentY = targetY
      return
    }
    if (animated) {
      currentScrollAnimation.from = queueFlick.contentY
      currentScrollAnimation.to = targetY
      currentScrollAnimation.start()
    } else {
      queueFlick.contentY = targetY
    }
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

  function cursorDefaultIndex() {
    if (root.queueTracks.length === 0) return -1
    return Math.max(0, Math.min(root.currentIndex, root.queueTracks.length - 1))
  }

  function moveCursor(dx, dy) {
    if (dy === 0 || root.queueTracks.length === 0) return
    root.beginKeyboardNav()
    if (root.cursorIndex < 0) root.cursorIndex = root.cursorDefaultIndex()
    else root.cursorIndex = Math.max(0, Math.min(root.queueTracks.length - 1, root.cursorIndex + dy))
    root.ensureCursorVisible()
  }

  function pageCursor(direction) {
    if (root.queueTracks.length === 0) return
    root.beginKeyboardNav()
    var rows = Math.max(1, Math.floor((queueFlick.height - root.topBarHeight - root.bottomInset) / (root.rowHeight + root.rowSpacing)) - 1)
    if (root.cursorIndex < 0) root.cursorIndex = root.cursorDefaultIndex()
    else root.cursorIndex = Math.max(0, Math.min(root.queueTracks.length - 1, root.cursorIndex + direction * rows))
    root.ensureCursorVisible()
  }

  function homeEndCursor(toEnd) {
    if (root.queueTracks.length === 0) return
    root.beginKeyboardNav()
    root.cursorIndex = toEnd ? root.queueTracks.length - 1 : 0
    root.ensureCursorVisible()
  }

  function activateCursor() {
    if (root.cursorIndex < 0 || root.cursorIndex >= root.queueTracks.length) return
    var idx = root.cursorIndex
    if (!Format.isTrackAvailable(root.queueTracks[idx])) return
    if (idx === root.currentIndex) {
      root.currentTrackClicked()
      return
    }
    root.jumpTo(idx)
    root.trackSelected(idx)
  }

  function ensureCursorVisible() {
    if (root.cursorIndex < 0 || !queueFlick) return
    var stride = root.rowHeight + root.rowSpacing
    var row = queueFlick.itemAtIndex(root.cursorIndex)
    var top = row ? row.mapToItem(queueFlick.contentItem, 0, 0).y : root.cursorIndex * stride
    var bottom = top + root.rowHeight
    // Content scrolls under the floating top bar, so the usable viewport
    // starts below it.
    var viewTop = queueFlick.contentY + root.topBarHeight
    // Keep the row above the collapsed player docked at the bottom.
    var viewBottom = queueFlick.contentY + queueFlick.height - root.bottomInset
    var margin = Style.space(8)
    var target = queueFlick.contentY
    if (top - margin < viewTop) target = top - margin - root.topBarHeight
    else if (bottom + margin > viewBottom) target = bottom + margin - (queueFlick.height - root.bottomInset)
    var maxY = Design.maxScrollY(queueFlick.originY, queueFlick.contentHeight, queueFlick.height)
    target = Math.max(queueFlick.originY, Math.min(maxY, target))
    if (Math.abs(target - queueFlick.contentY) < 1) return
    scrollHandler.reset()
    currentScrollAnimation.stop()
    queueFlick.contentY = target
  }

  onSvcChanged: {
    if (root.svc && visible) {
      root.refresh()
      root.lastSeenIndex = root.currentIndex
      Qt.callLater(function() { if (root && root.alive) root.scrollToCurrent(false) })
    }
  }
  onVisibleChanged: {
    if (visible && root.svc) {
      var fresh = root.pendingFreshEntry
      var moved = root.lastSeenIndex >= 0 && root.lastSeenIndex !== root.currentIndex
      root.pendingFreshEntry = false
      root.lastSeenIndex = root.currentIndex
      root.refresh()
      // Fresh entry lands on the current track; a return keeps the user's
      // position unless the track moved while away, which re-anchors.
      if (fresh || moved) Qt.callLater(function() { if (root && root.alive) root.scrollToCurrent(!fresh) })
    } else if (!visible) {
      root.lastSeenIndex = root.currentIndex
    }
  }
  Component.onCompleted: if (root.visible) root.refresh()

  NumberAnimation {
    id: currentScrollAnimation
    target: queueFlick
    property: "contentY"
    duration: 300
    easing.type: Easing.OutCubic
  }

  Connections {
    target: root.svc
    function onShuffleEnabledChanged() {
      if (root.visible) Qt.callLater(function() { if (root && root.alive) root.scrollToCurrent(false) })
    }
    function onQueueIndexChanged() {
      if (!root.visible) return
      root.lastSeenIndex = root.currentIndex
      if (root.suppressAutoScroll) return
      Qt.callLater(function() { if (root && root.alive) root.scrollToCurrent(true) })
    }
  }

  // Everything scrolls, including the page heading and the "Playing from"
  // banner: the face fills the panel and only the floating PlayerHeader is
  // pinned over it. Like the playlist pages, content passes under the top-bar
  // buttons instead of being clipped below them.
  //
  // A ListView, not a Repeater: starting playback from a list replaces the
  // queue (optimistically, then again when /queue answers) and a Repeater
  // built a delegate for every track even while this face was hidden. At a
  // few hundred tracks that froze the now-playing cross-fade. The list only
  // materialises the visible rows.
  ListView {
    id: queueFlick
    anchors.fill: parent
    // Rows paint their fill over the panel's full width (see Design.pageGutter).
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    spacing: root.rowSpacing
    model: root.queueTracks

    // Manual scrolling takes over from the animated scroll-to-current.
    onMovementStarted: currentScrollAnimation.stop()

    WheelHandler {
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      onWheel: function(event) { currentScrollAnimation.stop() }
    }

    SmoothScrollHandler { id: scrollHandler }

    // Keep the header's top edge under the viewport while it resizes.
    ScrollAnchor { }

    header: Item {
      width: queueFlick.width
      // Rows start below the floating top bar (which carries the queue's
      // "Playing from" pill), then scroll underneath it.
      height: headerColumn.implicitHeight + root.topBarHeight + Style.space(16)

      Column {
        id: headerColumn
        y: root.topBarHeight + Style.space(16)
        width: parent.width - 2 * Design.pageGutter
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(12)

        // Loading indicator — centered in the blank queue area
        Item {
          width: parent.width
          height: root.loading && root.queueTracks.length === 0
            ? Math.max(40, queueFlick.height - root.topBarHeight - root.bottomInset - Style.space(24))
            : 0
          visible: height > 0

          TidalLogo {
            anchors.centerIn: parent
            size: 32
            color: root.foreground
            pulsing: root.loading && root.queueTracks.length === 0
          }
        }

        // Empty queue indicator
        Item {
          width: parent.width
          height: !root.loading && root.queueTracks.length === 0 && !root.hasCurrentTrack ? 96 : 0
          visible: height > 0

          Column {
            anchors.centerIn: parent
            spacing: 6

            TidalLogo {
              anchors.horizontalCenter: parent.horizontalCenter
              size: 28
              color: root.foreground
              faint: true
            }

            Text {
              textFormat: Text.PlainText
              text: "Your queue is empty"
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption || 11
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }

        // The queue's "Playing from" summary lives in the floating top bar
        // (PlayerHeader), so the rows are the first thing under the top bar.
      }
    }

      footer: Item {
        width: queueFlick.width
        height: root.footerHeight
      }

      // Full queue, including previously played tracks
      delegate: Rectangle {
        id: queueRow
        required property var modelData
        required property int index
        readonly property bool isCurrent: root.currentIndex === queueRow.index
        readonly property bool isAvailable: Format.isTrackAvailable(queueRow.modelData)
        readonly property bool isPast: queueRow.index < root.currentIndex
        readonly property bool hasCursor: root.keyboardNav && root.cursorIndex === queueRow.index
        readonly property bool hovered: rowHover.hovered && !root.keyboardNav

        width: ListView.view.width
        height: root.rowHeight
        // Full-bleed band: the fill and the click target reach the panel
        // edges, the row's content stays on Design.pageGutter.
        radius: 0
        color: queueRow.hasCursor
          ? Style.hoverFillFor(root.foreground, Color.accent)
          : (queueRow.isCurrent
            ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.15)
            : "transparent")

        HoverFill {
          anchors.fill: parent
          tint: queueRow.isCurrent ? Color.accent : root.foreground
          strength: 0.08
          active: queueRow.hovered && queueRow.isAvailable
          instant: root.keyboardNav
        }

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Design.pageGutter
          anchors.rightMargin: Design.pageGutter
          spacing: 10
          // Played rows stay faded until hover or the keyboard cursor makes
          // them the active row; unavailable tracks stay dimmed unconditionally.
          opacity: !queueRow.isAvailable
            ? 0.4
            : (queueRow.isPast && !queueRow.hovered && !queueRow.hasCursor
              ? root.playedRowOpacity : 1)

          // Track thumbnail
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
              source: queueRow.modelData.art_url || ""
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

          // Title and Artist
          Column {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 2
            clip: true

            Row {
              width: parent.width
              spacing: 4

              FadeText {
                id: trackTitleText
                textFormat: Text.PlainText
                text: queueRow.modelData.title || ""
                color: queueRow.isCurrent ? Color.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall || 12
                font.weight: queueRow.isCurrent ? Font.Bold : Font.DemiBold
                width: Math.min(implicitWidth, Math.max(0, parent.width - (queueRow.modelData.explicit ? 18 : 0)))
              }

              Rectangle {
                width: 12
                height: 12
                radius: 2
                anchors.verticalCenter: trackTitleText.verticalCenter
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
                visible: !!queueRow.modelData.explicit

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
              enabled: queueRow.isAvailable
              interactive: queueRow.isAvailable
              artists: queueRow.modelData.artists || []
              fallbackText: queueRow.modelData.artist || ""
              fallbackArtistId: queueRow.modelData.artist_id || ""
              foreground: root.foreground
              textOpacity: queueRow.isCurrent ? 0.85 : 0.6
              fontFamily: root.fontFamily
              fontPixelSize: Style.font.caption || 10
              onArtistClicked: function(id, name) { root.artistSelected(id, name) }
            }
          }

          // Playing equalizer bars
          EqualizerBars {
            Layout.alignment: Qt.AlignVCenter
            visible: queueRow.isCurrent && Boolean(root.svc && root.svc.playing)
            playing: Boolean(root.svc && root.svc.playing)
            barColor: Color.accent
            width: 12
            height: 12
          }

          // Duration
          Text {
            Layout.alignment: Qt.AlignVCenter
            textFormat: Text.PlainText
            text: queueRow.modelData.duration ? Format.formatDuration(queueRow.modelData.duration) : ""
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption || 10
            visible: text !== ""
          }
        }

        CursorRules {
          anchors.fill: parent
          shown: queueRow.hasCursor
        }

        // HoverHandler rather than the row MouseArea's containsMouse: an
        // artist link's own hover area would otherwise make the row read as
        // unhovered and leave an already played row dimmed.
        HoverHandler {
          id: rowHover
          acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
          onHoveredChanged: {
            if (hovered) root.rowHovered(queueRow.index)
            else root.rowUnhovered(queueRow.index)
          }
        }

        MouseArea {
          id: rowMa
          anchors.fill: parent
          z: -1
          hoverEnabled: true
          cursorShape: queueRow.isAvailable ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: {
            if (!queueRow.isAvailable) return
            if (queueRow.isCurrent) {
              root.currentTrackClicked()
              return
            }
            root.jumpTo(queueRow.index)
            root.trackSelected(queueRow.index)
          }
        }
      }
    }
}
