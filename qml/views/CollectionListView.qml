import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../components"
import "../lib/Design.js" as Design

Item {
  id: root

  property bool alive: true
  Component.onDestruction: root.alive = false

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  // "playlists", "albums", "artists", "mixes"
  property string listType: "playlists"
  property real bottomInset: 0
  property int requestGeneration: 0

  signal playlistSelected(string id, string title, string artUrl)
  signal albumSelected(string id, string title, string artUrl)
  signal artistSelected(string id, string name, string artUrl)
  signal mixSelected(string id, string title, string artUrl)

  property var items: []
  property string filterText: ""
  property bool loading: false

  onFilterTextChanged: root.resetCursor()

  function clearFilter() {
    root.filterText = ""
    if (filterInput && filterInput.text !== "") filterInput.text = ""
  }

  readonly property var filteredItems: {
    if (!root.filterText.trim()) return root.items
    var term = root.filterText.trim().toLowerCase()
    return root.items.filter(function(it) {
      var t = String(it.title || it.name || "").toLowerCase()
      var s = String(it.subtitle || "").toLowerCase()
      var a = String(it.artist || "").toLowerCase()
      return t.indexOf(term) !== -1 || s.indexOf(term) !== -1 || a.indexOf(term) !== -1
    })
  }

  // The artists page lays out as a fixed 3-column grid of circular cards;
  // playlists, albums and mixes stay a row list.
  readonly property int gridColumns: 3

  function areListsEqual(a, b) {
    if (!a || !b) return false
    if (a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) {
      var x = a[i]
      var y = b[i]
      if (!x || !y) return false
      if (String(x.id || "") !== String(y.id || "")
          || String(x.title || "") !== String(y.title || "")
          || String(x.name || "") !== String(y.name || "")
          || String(x.subtitle || "") !== String(y.subtitle || "")
          || String(x.artist || "") !== String(y.artist || "")
          || String(x.year || "") !== String(y.year || "")
          || Number(x.track_count || 0) !== Number(y.track_count || 0)
          || String(x.art_url || "") !== String(y.art_url || "")) {
        return false
      }
    }
    return true
  }

  function refresh() {
    if (!root.svc) {
      root.loading = false
      return
    }
    var generation = ++root.requestGeneration
    var requestedType = root.listType
    if (root.items.length === 0) root.loading = true
    var cb = function(list) {
      if (!root || !root.alive || generation !== root.requestGeneration || requestedType !== root.listType) return
      var next = list || []
      if (!root.areListsEqual(root.items, next)) {
        root.items = next
      }
      root.loading = false
    }

    if (root.listType === "playlists") {
      root.svc.fetchPlaylists(cb)
    } else if (root.listType === "albums") {
      root.svc.fetchAlbums(cb)
    } else if (root.listType === "artists") {
      root.svc.fetchArtists(cb)
    } else if (root.listType === "mixes") {
      root.svc.fetchMixes(cb)
    } else {
      root.loading = false
    }
  }

  function focusFilter() {
    if (filterInput) {
      filterInput.forceActiveFocus()
    }
  }

  // Called by MiniPlayer on fresh navigation (push/setFace). Back-navigation
  // leaves the Flickable alone so the user returns to where they were.
  function scrollToTop() {
    scrollHandler.reset()
    if (listFlick.contentY !== 0) listFlick.contentY = 0
  }

  signal filterFocusRequested()
  signal filterDownRequested()

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

  // Artists walk a grid, everything else a row list; the cursor indexes the
  // same filteredItems either way and only needs the delegate under it.
  function cursorItem(index) {
    if (index < 0) return null
    return root.listType === "artists" ? gridRepeater.itemAt(index) : rowRepeater.itemAt(index)
  }

  function firstVisibleIndex() {
    if (root.filteredItems.length === 0) return -1
    var viewTop = listFlick.contentY
    for (var i = 0; i < root.filteredItems.length; i++) {
      var row = root.cursorItem(i)
      if (!row) continue
      if (row.mapToItem(listFlick.contentItem, 0, 0).y + row.height > viewTop + 1) return i
    }
    return 0
  }

  function moveCursor(dx, dy) {
    var isGrid = root.listType === "artists"
    // Rows only move vertically; the grid also steps within a row.
    if (dy === 0 && (!isGrid || dx === 0)) return
    root.beginKeyboardNav()
    // Up from the top of the content hands focus back to the filter field.
    var topEdge = isGrid ? root.gridColumns : 1
    if (dy < 0 && (root.cursorIndex < 0 || root.cursorIndex < topEdge)) {
      root.cursorIndex = -1
      root.keyboardNav = false
      root.filterFocusRequested()
      return
    }
    if (root.filteredItems.length === 0) return
    if (root.cursorIndex < 0) {
      root.cursorIndex = root.firstVisibleIndex()
      root.ensureCursorVisible()
      return
    }
    var idx = root.cursorIndex
    if (isGrid) {
      // Three columns, so vertical movement is three slots and horizontal
      // movement stays inside the row.
      if (dy !== 0) idx = idx + dy * root.gridColumns
      else if (dx < 0) {
        if (idx % root.gridColumns !== 0) idx -= 1
      } else if (dx > 0) {
        if (idx % root.gridColumns !== root.gridColumns - 1) idx += 1
      }
    } else {
      idx = idx + dy
    }
    root.cursorIndex = Math.max(0, Math.min(root.filteredItems.length - 1, idx))
    root.ensureCursorVisible()
  }

  function pageCursor(direction) {
    if (root.filteredItems.length === 0) return
    root.beginKeyboardNav()
    var step
    if (root.listType === "artists") {
      var cell = gridRepeater.itemAt(0)
      var cellHeight = cell ? cell.height + artistsGrid.spacing : 120
      var pageRows = Math.max(1, Math.floor(listFlick.height / cellHeight) - 1)
      step = direction * pageRows * root.gridColumns
    } else {
      var rows = Math.max(1, Math.floor(listFlick.height / 48) - 1)
      step = direction * rows
    }
    if (root.cursorIndex < 0) root.cursorIndex = root.firstVisibleIndex()
    else root.cursorIndex = Math.max(0, Math.min(root.filteredItems.length - 1, root.cursorIndex + step))
    root.ensureCursorVisible()
  }

  function homeEndCursor(toEnd) {
    if (root.filteredItems.length === 0) return
    root.beginKeyboardNav()
    root.cursorIndex = toEnd ? root.filteredItems.length - 1 : 0
    root.ensureCursorVisible()
  }

  function activateCursor() {
    if (root.cursorIndex < 0 || root.cursorIndex >= root.filteredItems.length) return
    var d = root.filteredItems[root.cursorIndex]
    if (!d) return
    var id = String(d.id || "")
    var art = String(d.art_url || "")
    if (root.listType === "playlists") {
      root.playlistSelected(id, String(d.title || ""), art)
    } else if (root.listType === "albums") {
      root.albumSelected(id, String(d.title || ""), art)
    } else if (root.listType === "artists") {
      root.artistSelected(id, String(d.name || d.title || ""), art)
    } else if (root.listType === "mixes") {
      root.mixSelected(id, String(d.title || ""), art)
    }
  }

  function ensureCursorVisible() {
    if (root.cursorIndex < 0) return
    var row = root.cursorItem(root.cursorIndex)
    if (!row) return
    var top = row.mapToItem(listFlick.contentItem, 0, 0).y
    var bottom = top + row.height
    var viewTop = listFlick.contentY
    // Keep the row above the collapsed player docked at the bottom.
    var viewHeight = Math.max(0, listFlick.height - root.bottomInset)
    var margin = Style.space(8)
    var target = viewTop
    if (top - margin < viewTop) target = top - margin
    else if (bottom + margin > viewTop + viewHeight) target = bottom + margin - viewHeight
    var maxY = Math.max(0, listFlick.contentHeight - listFlick.height)
    target = Math.max(0, Math.min(maxY, target))
    if (Math.abs(target - viewTop) < 1) return
    scrollHandler.reset()
    listFlick.contentY = target
  }

  onListTypeChanged: {
    root.clearFilter()
    root.items = []
    root.refresh()
    if (visible) Qt.callLater(function() { if (root && root.alive && root.visible) root.focusFilter() })
  }
  onSvcChanged: if (root.svc && visible) root.refresh()
  onVisibleChanged: {
    // Refresh every visit: playlists can change elsewhere (e.g. Add on a
    // public playlist) and the list must pick that up when it is shown again.
    if (visible && root.svc) root.refresh()
    if (!visible) root.clearFilter()
    if (visible) Qt.callLater(function() { if (root && root.alive && root.visible) root.focusFilter() })
  }
  onEnabledChanged: {
    if (enabled && visible) Qt.callLater(function() { if (root && root.alive && root.visible) root.focusFilter() })
  }
  Component.onCompleted: {
    if (root.visible) {
      root.refresh()
      Qt.callLater(function() { if (root && root.alive && root.visible) root.focusFilter() })
    }
  }

  // Pulsing loader while fetching
  TidalLogo {
    anchors.centerIn: parent
    size: 40
    color: root.foreground
    pulsing: root.loading && root.items.length === 0
    visible: root.loading && root.items.length === 0
  }

  Flickable {
    id: listFlick
    anchors.fill: parent
    anchors.topMargin: 16
    contentHeight: Design.scrollContentHeight(listCol.implicitHeight, listFlick.height, root.bottomInset, 16)
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    SmoothScrollHandler { id: scrollHandler }

    Column {
      id: listCol
      // The list column is inset so headings and the filter bar sit on the
      // content line; rows escape it to the panel edges (see Design.pageGutter).
      x: Design.pageGutter
      width: listFlick.width - 2 * Design.pageGutter
      spacing: 8

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: {
          if (root.listType === "playlists") return "Playlists"
          if (root.listType === "albums") return "Albums"
          if (root.listType === "artists") return "Artists"
          if (root.listType === "mixes") return "Mixes"
          return "Music"
        }
        color: root.foreground
        font.family: root.fontFamily
        // The page heading style: same size and centring as the Tracks page.
        font.pixelSize: Style.font.heading + 4
        font.weight: Font.Bold
        horizontalAlignment: Text.AlignHCenter
        topPadding: 4
      }

      // Filter Bar
      Rectangle {
        id: filterBar
        width: parent.width
        height: 36
        radius: 6
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.IBeamCursor
          onClicked: filterInput.forceActiveFocus()
        }

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: 10
          anchors.rightMargin: 10
          spacing: 8

          SvgIcon {
            size: 16
            color: root.foreground
            opacity: 0.5
            source: Qt.resolvedUrl("../../assets/icons/search.svg")
          }

          TextInput {
            id: filterInput
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            verticalAlignment: TextInput.AlignVCenter
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body || 13
            clip: true
            selectByMouse: true
            activeFocusOnPress: true
            onTextChanged: root.filterText = text

            Keys.onDownPressed: function(event) {
              root.filterDownRequested()
              event.accepted = true
            }

            Text {
              textFormat: Text.PlainText
              anchors.fill: parent
              verticalAlignment: Text.AlignVCenter
              text: {
                if (root.listType === "playlists") return "Filter playlists..."
                if (root.listType === "albums") return "Filter albums..."
                if (root.listType === "artists") return "Filter artists..."
                if (root.listType === "mixes") return "Filter mixes..."
                return "Filter collection..."
              }
              color: root.foreground
              opacity: 0.4
              font.family: root.fontFamily
              font.pixelSize: Style.font.body || 13
              visible: !filterInput.text && !filterInput.inputMethodComposing
            }
          }

          // Clear button
          Rectangle {
            width: 20
            height: 20
            radius: 10
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
            visible: filterInput.text.length > 0

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: "×"
              color: root.foreground
              font.pixelSize: 14
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.clearFilter()
                filterInput.forceActiveFocus()
              }
            }
          }
        }
      }

      Column {
        width: parent.width
        spacing: 0

        Repeater {
          id: rowRepeater
          model: root.listType === "artists" ? [] : root.filteredItems

          Rectangle {
            id: rowItem
            required property var modelData
            required property int index
            readonly property bool hasCursor: root.keyboardNav && root.cursorIndex === rowItem.index
            readonly property bool hovered: itemMa.containsMouse && !root.keyboardNav

            height: 50
            // Full-bleed band: the fill and the click target reach the panel
            // edges, the row's content stays on Design.pageGutter.
            x: -Design.pageGutter
            width: listCol.width + 2 * Design.pageGutter
            radius: 0
            color: rowItem.hasCursor
              ? Style.hoverFillFor(root.foreground, Color.accent)
              : "transparent"

            HoverFill {
              anchors.fill: parent
              tint: root.foreground
              strength: 0.08
              active: rowItem.hovered
              instant: root.keyboardNav
            }

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Design.pageGutter
              anchors.rightMargin: Design.pageGutter
              spacing: 10

              // Thumbnail (square for albums/playlists/mixes)
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
                  source: rowItem.modelData.art_url || ""
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

              // Title & Subtitle / Details
              Column {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 2
                clip: true

                FadeText {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: rowItem.modelData.name || rowItem.modelData.title || ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall || 12
                  font.weight: Font.DemiBold
                  maximumLineCount: 1
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: {
                    if (root.listType === "playlists") {
                      var count = rowItem.modelData.track_count
                      return (count !== undefined && count !== null)
                        ? (count + (Number(count) === 1 ? " track" : " tracks"))
                        : "Playlist"
                    } else if (root.listType === "albums") {
                      var art = rowItem.modelData.artist || ""
                      var yr = rowItem.modelData.year
                      return yr ? (art + " • " + yr) : art
                    } else if (root.listType === "mixes") {
                      return rowItem.modelData.subtitle || "Mix"
                    }
                    return ""
                  }
                  color: root.foreground
                  opacity: 0.6
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption || 10
                  elide: Text.ElideRight
                  maximumLineCount: 1
                }
              }

              // Chevron Right Indicator
              SvgIcon {
                Layout.alignment: Qt.AlignVCenter
                size: 16
                color: root.foreground
                opacity: 0.35
                source: Qt.resolvedUrl("../../assets/icons/chevron-right.svg")
              }
            }

            CursorRules {
              anchors.fill: parent
              shown: rowItem.hasCursor
            }

            MouseArea {
              id: itemMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.rowHovered(rowItem.index)
              onExited: root.rowUnhovered(rowItem.index)
              onClicked: {
                var d = rowItem.modelData
                if (!d) return
                var id = String(d.id || "")
                var art = String(d.art_url || "")
                if (root.listType === "playlists") {
                  root.playlistSelected(id, String(d.title || ""), art)
                } else if (root.listType === "albums") {
                  root.albumSelected(id, String(d.title || ""), art)
                } else if (root.listType === "mixes") {
                  root.mixSelected(id, String(d.title || ""), art)
                }
              }
            }
          }
        }
      }

      // Artists: a 3-column grid of circular cards. The cards overhang the
      // content line by their own padding, so the circles inside them line up
      // with the filter bar above while the padded card background runs past
      // the line (see Design.pageGutter).
      Grid {
        id: artistsGrid
        readonly property int cardPadding: Style.space(6)
        x: -cardPadding
        width: parent.width + 2 * cardPadding
        columns: root.gridColumns
        // 4 + a 6px card padding on each side leaves 16px between the
        // circles, the same air the page gutter gives them at either edge.
        spacing: Style.space(4)
        visible: root.listType === "artists"

        Repeater {
          id: gridRepeater
          model: root.listType === "artists" ? root.filteredItems : []

          Rectangle {
            id: artistCard
            required property var modelData
            required property int index
            readonly property bool hasCursor: root.keyboardNav && root.cursorIndex === artistCard.index
            readonly property bool hovered: artistMa.containsMouse && !root.keyboardNav

            width: Design.cardWidth(artistsGrid.width, artistsGrid.spacing, artistsGrid.columns)
            height: artistCol.implicitHeight + 2 * artistsGrid.cardPadding
            radius: 0
            border.color: artistCard.hasCursor ? Color.accent : "transparent"
            border.width: artistCard.hasCursor ? 1 : 0
            color: artistCard.hasCursor
              ? Style.hoverFillFor(root.foreground, Color.accent)
              : "transparent"

            HoverFill {
              anchors.fill: parent
              tint: root.foreground
              strength: 0.1
              active: artistCard.hovered
              instant: root.keyboardNav
            }

            Column {
              id: artistCol
              anchors.fill: parent
              anchors.margins: artistsGrid.cardPadding
              spacing: Style.space(3)

              // Circular artist image.
              Rectangle {
                width: parent.width
                height: width
                radius: width / 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
                border.width: 1
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

                RoundedImage {
                  id: circleArt
                  anchors.fill: parent
                  radius: width / 2
                  borderWidth: 1
                  borderColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
                  source: artistCard.modelData.art_url || ""
                  sourceSize.width: 220
                  sourceSize.height: 220
                  visible: source !== ""
                }

                TidalLogo {
                  anchors.centerIn: parent
                  size: 28
                  color: root.foreground
                  faint: true
                  visible: !circleArt.showingImage
                }
              }

              // Artist name underneath the circle.
              FadeText {
                textFormat: Text.PlainText
                width: parent.width
                text: artistCard.modelData.name || artistCard.modelData.title || ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall || 12
                font.weight: Font.DemiBold
                horizontalAlignment: Text.AlignHCenter
                maximumLineCount: 1
              }
            }

            CursorRules {
              anchors.fill: parent
              shown: artistCard.hasCursor
            }

            MouseArea {
              id: artistMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.rowHovered(artistCard.index)
              onExited: root.rowUnhovered(artistCard.index)
              onClicked: root.artistSelected(String(artistCard.modelData.id || ""), String(artistCard.modelData.name || artistCard.modelData.title || ""), String(artistCard.modelData.art_url || ""))
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: !root.loading && root.filteredItems.length === 0
        text: root.filterText.trim() !== ""
          ? "No matching " + root.listType
          : "No " + root.listType + " yet"
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
