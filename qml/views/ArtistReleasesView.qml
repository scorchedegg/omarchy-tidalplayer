import QtQuick
import qs.Commons
import "../components"
import "../lib/Design.js" as Design
import "../lib/Format.js" as Format

// The artist's full discography. ArtistView previews four releases; its
// "View all" opens this face on the pill the artist page was showing. The page
// opens with a centered "Discography" heading and the same All / Albums /
// EP & Singles / Live filters; the artist credit sits in the top bar
// (PlayerHeader) like the top tracks page, then every release follows in a
// two-column grid.
Item {
  id: root
  layer.enabled: true

  property bool alive: true
  Component.onDestruction: root.alive = false

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  property real bottomInset: 0
  readonly property int topBarHeight: 52

  property string artistId: ""
  property string artistName: ""
  property string artistArtUrl: ""
  // "popular", "albums", "eps" or "live"; carried over from the artist page.
  // `requestedFilter` stays bound to the face params, while `filter` is the
  // page's own state so a pill click does not break that binding.
  property string requestedFilter: "popular"
  property string filter: "popular"
  property var artistData: null
  property int requestGeneration: 0
  property bool loading: false

  readonly property var releases: root.artistData ? (root.artistData.releases || []) : []
  readonly property var filteredReleases: Format.filterReleases(root.releases, root.filter)
  readonly property var filterOptions: Format.releaseFilterOptions()
  readonly property var emptyFilters: Format.emptyReleaseFilters(root.releases)
  readonly property string latestReleaseId: root.releases.length > 0 ? String(root.releases[0].id || "") : ""
  readonly property string pageTitle: "Discography"
  readonly property string displayArtistId: root.artistId
  readonly property string displayArtistName: root.artistData && root.artistData.name
    ? String(root.artistData.name) : (root.artistName || "Artist")
  readonly property string displayArtistArtUrl: root.artistData && root.artistData.art_url
    ? root.artistData.art_url : root.artistArtUrl

  signal albumSelected(string id, string title, string artUrl)

  function loadReleases() {
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

  onArtistIdChanged: root.loadReleases()
  onSvcChanged: if (root.svc && visible) root.loadReleases()
  onVisibleChanged: {
    if (visible && root.svc && !root.artistData && root.artistId !== "" && !root.loading) {
      root.loadReleases()
    }
  }
  Component.onCompleted: {
    root.resetFilter()
    if (root.visible) root.loadReleases()
  }

  // Called by MiniPlayer on fresh navigation (push/setFace). Back-navigation
  // leaves the Flickable alone so the user returns to where they were.
  function scrollToTop() {
    scrollHandler.reset()
    if (releasesFlickable.contentY !== 0) releasesFlickable.contentY = 0
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

  // A filter can shorten the grid under the cursor, so start over.
  onFilterChanged: root.resetCursor()

  // Adopt the pill navigation came in with. MiniPlayer calls this on a fresh
  // push/set so reopening the page on the artist's current pill works even when
  // the key itself did not change.
  function resetFilter() {
    root.filter = root.requestedFilter
    root.resetCursor()
  }

  onRequestedFilterChanged: root.resetFilter()

  function firstVisibleIndex() {
    if (root.filteredReleases.length === 0) return -1
    var viewTop = releasesFlickable.contentY + root.topBarHeight
    for (var i = 0; i < root.filteredReleases.length; i++) {
      var card = cardRepeater.itemAt(i)
      if (!card) continue
      if (card.mapToItem(releasesFlickable.contentItem, 0, 0).y + card.height > viewTop + 1) return i
    }
    return 0
  }

  function moveCursor(dx, dy) {
    if (root.filteredReleases.length === 0) return
    root.beginKeyboardNav()
    if (root.cursorIndex < 0) {
      root.cursorIndex = root.firstVisibleIndex()
      root.ensureCursorVisible()
      return
    }
    var count = root.filteredReleases.length
    var idx = root.cursorIndex
    if (dy !== 0) {
      // Two columns, so vertical movement is two slots.
      idx = Math.max(0, Math.min(count - 1, idx + dy * 2))
    } else if (dx < 0) {
      if (idx % 2 === 1) idx -= 1
    } else if (dx > 0) {
      if (idx % 2 === 0 && idx + 1 < count) idx += 1
    }
    root.cursorIndex = idx
    root.ensureCursorVisible()
  }

  function pageCursor(direction) {
    if (root.filteredReleases.length === 0) return
    root.beginKeyboardNav()
    if (root.cursorIndex < 0) root.cursorIndex = root.firstVisibleIndex()
    else root.cursorIndex = Math.max(0, Math.min(root.filteredReleases.length - 1, root.cursorIndex + direction * 4))
    root.ensureCursorVisible()
  }

  function homeEndCursor(toEnd) {
    if (root.filteredReleases.length === 0) return
    root.beginKeyboardNav()
    root.cursorIndex = toEnd ? root.filteredReleases.length - 1 : 0
    root.ensureCursorVisible()
  }

  function activateCursor() {
    if (root.cursorIndex < 0 || root.cursorIndex >= root.filteredReleases.length) return
    var release = root.filteredReleases[root.cursorIndex]
    if (release) root.albumSelected(String(release.id || ""), String(release.title || ""), String(release.art_url || ""))
  }

  function ensureCursorVisible() {
    var card = cardRepeater.itemAt(root.cursorIndex)
    if (!card) return
    var top = card.mapToItem(releasesFlickable.contentItem, 0, 0).y
    var bottom = top + card.height
    var viewTop = releasesFlickable.contentY + root.topBarHeight
    // Keep the row above the collapsed player docked at the bottom.
    var viewBottom = releasesFlickable.contentY + releasesFlickable.height - root.bottomInset
    var margin = Style.space(8)
    var target = releasesFlickable.contentY
    if (top - margin < viewTop) target = top - margin - root.topBarHeight
    else if (bottom + margin > viewBottom) target = bottom + margin - (releasesFlickable.height - root.bottomInset)
    var maxY = Math.max(0, releasesFlickable.contentHeight - releasesFlickable.height)
    target = Math.max(0, Math.min(maxY, target))
    if (Math.abs(target - releasesFlickable.contentY) < 1) return
    scrollHandler.reset()
    releasesFlickable.contentY = target
  }

  Flickable {
    id: releasesFlickable
    anchors.fill: parent
    contentWidth: width
    contentHeight: Design.scrollContentHeight(mainCol.implicitHeight, releasesFlickable.height, root.bottomInset, 16)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick

    SmoothScrollHandler { id: scrollHandler }

    Column {
      id: mainCol
      width: releasesFlickable.width - 2 * Design.pageGutter
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
        text: root.pageTitle
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading + 4
        font.weight: Font.Bold
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }

      ReleaseFilters {
        width: parent.width
        foreground: root.foreground
        fontFamily: root.fontFamily
        options: root.filterOptions
        currentFilter: root.filter
        disabledKeys: root.emptyFilters
        onFilterSelected: function(key) { root.filter = key }
      }

      // Loading indicator, centered in the blank area below the header.
      Item {
        width: parent.width
        height: root.loading
          ? Math.max(40, releasesFlickable.height - y - root.bottomInset - Style.space(24))
          : 0
        visible: height > 0

        TidalLogo {
          anchors.centerIn: parent
          size: 32
          color: root.foreground
          pulsing: root.loading
        }
      }

      Grid {
        id: releasesGrid
        // The cards overhang the content line by their own padding, so the
        // artwork inside them lines up with the filters above while the padded
        // card background runs past the line (see Design.pageGutter).
        readonly property int cardPadding: Style.space(6)
        x: -cardPadding
        width: parent.width + 2 * cardPadding
        columns: 2
        // 4 + a 6px card padding on each side leaves 16px between the
        // artworks, the same air the page gutter gives them at either edge.
        spacing: Style.space(4)

        Repeater {
          id: cardRepeater
          model: root.filteredReleases

          Rectangle {
            id: releaseCard
            required property var modelData
            required property int index
            readonly property bool hasCursor: root.keyboardNav && root.cursorIndex === releaseCard.index
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
              onEntered: root.rowHovered(releaseCard.index)
              onExited: root.rowUnhovered(releaseCard.index)
              onClicked: root.albumSelected(String(releaseCard.modelData.id || ""), String(releaseCard.modelData.title || ""), String(releaseCard.modelData.art_url || ""))
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: !root.loading && root.filteredReleases.length === 0
        text: "No releases found"
        color: root.foreground
        opacity: 0.55
        font.family: root.fontFamily
        font.pixelSize: Style.font.body || 13
        horizontalAlignment: Text.AlignHCenter
        topPadding: 28
      }
    }
  }
}
