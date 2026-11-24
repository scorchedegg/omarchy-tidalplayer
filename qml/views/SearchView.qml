import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../components"
import "../lib/Design.js" as Design
import "../lib/Format.js" as Format
import "../lib/Search.js" as Search

Item {
  id: root

  property bool alive: true
  Component.onDestruction: {
    root.alive = false
    searchTimer.stop()
  }

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  property real bottomInset: 0
  property string searchQuery: ""

  signal trackSelected(var track)
  signal currentTrackClicked()
  signal artistSelected(string id, string name, string artUrl)
  signal albumSelected(string id, string title, string artUrl)
  signal playlistSelected(string id, string title, string artUrl)
  signal queryRequested(string query)
  signal cancelClicked()

  property var recentSearches: (svc && svc.recentSearches) ? svc.recentSearches : []

  // One catalogue search per query returns all four types; the pills below
  // the search bar filter that result set client-side.
  property var results: ({ tracks: [], artists: [], albums: [], playlists: [] })
  property bool searching: false
  property int searchGeneration: 0
  // Query `results` belong to, so coming back from a result page keeps them
  // instead of clearing and searching again.
  property string resultsQuery: ""
  // "top" shows the mixed list; the other values show one result type.
  property string filter: "top"

  readonly property int topLimit: 20
  readonly property int filterLimit: 10

  // Filter pills: "All" is the mixed list.
  readonly property var filterPillsModel: [
    { key: "top", label: "All" },
    { key: "tracks", label: "Tracks" },
    { key: "artists", label: "Artists" },
    { key: "albums", label: "Albums" },
    { key: "playlists", label: "Playlists" }
  ]

  function performSearch(query) {
    var q = (query || "").trim()
    var generation = ++root.searchGeneration
    searchTimer.stop()
    if (q === root.resultsQuery && !root.searching) return
    if (!q) {
      root.results = { tracks: [], artists: [], albums: [], playlists: [] }
      root.resultsQuery = ""
      root.searching = false
      return
    }
    if (!root.svc) {
      root.searching = false
      return
    }
    root.searching = true
    root.svc.search(q, function(data) {
      if (!root || !root.alive || generation !== root.searchGeneration || !root.visible || root.searchQuery.trim() !== q) return
      root.results = data || { tracks: [], artists: [], albums: [], playlists: [] }
      root.resultsQuery = q
      root.searching = false
    })
  }

  function artistLabel(track) {
    var names = []
    if (track && track.artists && track.artists.length) {
      for (var i = 0; i < track.artists.length; i++) {
        if (track.artists[i] && track.artists[i].name) names.push(track.artists[i].name)
      }
    }
    if (names.length === 0 && track && track.artist) names.push(track.artist)
    return names.join(", ")
  }

  // One row shape for every result kind, so the mixed list and the per-type
  // filters share the same delegate.
  function makeRow(kind, item, withType) {
    var row = {
      kind: kind,
      id: item.id || "",
      title: item.title || item.name || "",
      artUrl: item.art_url || "",
      available: kind !== "track" || Format.isTrackAvailable(item),
      raw: item
    }
    var parts = []
    if (kind === "track") {
      if (withType) parts.push("Track")
      var artists = root.artistLabel(item)
      if (artists) parts.push(artists)
    } else if (kind === "artist") {
      if (withType) parts.push("Artist")
      if (item.fans) parts.push(item.fans)
    } else if (kind === "album") {
      var releaseType = item.release_type === "SINGLE" ? "Single" : (item.release_type === "EP" ? "EP" : "Album")
      // Singles read artist · Single · year; albums keep the type first.
      if (releaseType === "Album") {
        if (withType) parts.push(releaseType)
        if (item.artist) parts.push(item.artist)
      } else {
        if (item.artist) parts.push(item.artist)
        parts.push(releaseType)
      }
      if (item.year) parts.push(String(item.year))
    } else {
      if (withType) parts.push("Playlist")
      if (item.track_count) {
        parts.push(item.track_count + (item.track_count === 1 ? " track" : " tracks"))
      }
    }
    row.subtitle = parts.join(" · ")
    return row
  }

  // Top view: relevance ranked across the four lists. Matching each item's own
  // name (and an artist credit for tracks/albums) keeps an exact artist hit on
  // top instead of a popular track that only matched through its artist.
  readonly property var resultRows: {
    var out = []
    var max = root.filter === "top" ? root.topLimit : root.filterLimit
    if (root.filter === "top") {
      var entries = Search.rank(root.results, root.resultsQuery, max)
      for (var e = 0; e < entries.length; e++) {
        out.push(root.makeRow(entries[e].kind, entries[e].item, true))
      }
    } else {
      var items = root.results[root.filter] || []
      var kind = root.filter.slice(0, -1)
      for (var n = 0; n < items.length && n < max; n++) {
        out.push(root.makeRow(kind, items[n], false))
      }
    }
    return out
  }

  readonly property bool resultsLoaded: !root.searching && root.resultsQuery === root.searchQuery.trim()

  readonly property string emptyMessage: {
    if (root.filter === "tracks") return "No tracks found"
    if (root.filter === "artists") return "No artists found"
    if (root.filter === "albums") return "No albums found"
    if (root.filter === "playlists") return "No playlists found"
    return "No results"
  }

  function activateRow(row) {
    if (!row) return
    if (row.kind === "track" && row.available === false) return
    if (root.svc && root.searchQuery.trim()) root.svc.addRecentSearch(root.searchQuery.trim())
    if (row.kind === "track") {
      var cur = root.svc ? String(root.svc.currentTrackId || "") : ""
      if (cur !== "" && cur === String(row.id || "")) {
        root.currentTrackClicked()
        return
      }
      if (root.svc) root.svc.playQueue([row.raw], 0)
      root.trackSelected(row.raw)
    } else if (row.kind === "artist") {
      root.artistSelected(row.id, row.title, row.artUrl)
    } else if (row.kind === "album") {
      root.albumSelected(row.id, row.title, row.artUrl)
    } else if (row.kind === "playlist") {
      root.playlistSelected(row.id, row.title, row.artUrl)
    }
  }

  // Called by MiniPlayer on fresh navigation (push/setFace). Back-navigation
  // keeps the results and their scroll position.
  function scrollToTop() {
    scrollHandler.reset()
    if (searchFlickable.contentY !== 0) searchFlickable.contentY = 0
  }

  signal queryFocusRequested()

  // ---- Keyboard cursor --------------------------------------------------------
  // cursorIndex: -1 = none, 0 = filter pills, 1..N = list rows (index - 1).

  property int cursorIndex: -1
  readonly property bool cursorOnPills: cursorIndex === 0
  readonly property bool pillsActive: root.searchQuery !== ""
  readonly property var cursorItems: root.searchQuery === "" ? root.recentSearches : root.resultRows

  function resetCursor() {
    root.cursorIndex = -1
    root.hoveredIndex = -1
    root.keyboardNav = false
  }

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

  function cursorRepeater() {
    return root.searchQuery === "" ? recentRepeater : resultRepeater
  }

  function firstVisibleIndex() {
    var count = root.cursorItems.length
    if (count === 0) return 1
    var repeater = root.cursorRepeater()
    var viewTop = searchFlickable.contentY
    for (var i = 0; i < count; i++) {
      var row = repeater.itemAt(i)
      if (!row) continue
      if (row.mapToItem(searchFlickable.contentItem, 0, 0).y + row.height > viewTop + 1) return i + 1
    }
    return 1
  }

  function moveCursor(dx, dy) {
    var count = root.cursorItems.length
    root.beginKeyboardNav()
    if (dy > 0) {
      if (root.cursorIndex < 0) {
        // From the search field: results when there are any, else the pills.
        root.cursorIndex = count > 0 ? 1 : (root.pillsActive ? 0 : -1)
        root.ensureCursorVisible()
        return
      }
      if (root.cursorIndex === 0) {
        root.cursorIndex = count > 0 ? 1 : 0
        root.ensureCursorVisible()
        return
      }
      if (count === 0) return
      root.cursorIndex = Math.min(count, root.cursorIndex + dy)
      root.ensureCursorVisible()
      return
    }
    if (dy < 0) {
      if (root.cursorIndex <= 0 || (root.cursorIndex === 1 && !root.pillsActive)) {
        // Up from the pills, top recent search, or with no cursor hands focus to the field.
        root.cursorIndex = -1
        root.keyboardNav = false
        root.queryFocusRequested()
        return
      }
      root.cursorIndex = (root.cursorIndex === 1 && root.pillsActive) ? 0 : Math.max(1, root.cursorIndex - 1)
      root.ensureCursorVisible()
      return
    }
    if (dx !== 0 && root.cursorIndex === 0) root.cycleFilter(dx)
  }

  function cycleFilter(direction) {
    var keys = ["top", "tracks", "artists", "albums", "playlists"]
    var idx = keys.indexOf(root.filter)
    if (idx < 0) idx = 0
    root.filter = keys[(idx + direction + keys.length) % keys.length]
  }

  function pageCursor(direction) {
    var count = root.cursorItems.length
    if (count === 0) return
    root.beginKeyboardNav()
    // Recent rows and result rows now carry different absorbed gaps.
    var rowHeight = root.searchQuery === "" ? 52 : 54
    var rows = Math.max(1, Math.floor(searchFlickable.height / rowHeight) - 1)
    if (root.cursorIndex < 1) root.cursorIndex = root.firstVisibleIndex()
    else root.cursorIndex = Math.max(1, Math.min(count, root.cursorIndex + direction * rows))
    root.ensureCursorVisible()
  }

  function homeEndCursor(toEnd) {
    var count = root.cursorItems.length
    if (count === 0) return
    root.beginKeyboardNav()
    root.cursorIndex = toEnd ? count : 1
    root.ensureCursorVisible()
  }

  function activateCursor() {
    var rowIndex = root.cursorIndex - 1
    if (rowIndex < 0 || rowIndex >= root.cursorItems.length) return
    if (root.searchQuery === "") {
      var item = root.recentSearches[rowIndex]
      var q = typeof item === "string" ? item : (item.title || "")
      if (q === "") return
      root.queryRequested(q)
      root.performSearch(q)
    } else {
      root.activateRow(root.resultRows[rowIndex])
    }
  }

  function ensureCursorVisible() {
    var rowIndex = root.cursorIndex - 1
    if (rowIndex < 0) return
    var row = root.cursorRepeater().itemAt(rowIndex)
    if (!row) return
    var top = row.mapToItem(searchFlickable.contentItem, 0, 0).y
    var bottom = top + row.height
    var viewTop = searchFlickable.contentY
    // Keep the row above the collapsed player docked at the bottom.
    var viewHeight = Math.max(0, searchFlickable.height - root.bottomInset)
    var margin = Style.space(8)
    var target = viewTop
    if (top - margin < viewTop) target = top - margin
    else if (bottom + margin > viewTop + viewHeight) target = bottom + margin - viewHeight
    var maxY = Math.max(0, searchFlickable.contentHeight - searchFlickable.height)
    target = Math.max(0, Math.min(maxY, target))
    if (Math.abs(target - viewTop) < 1) return
    scrollHandler.reset()
    searchFlickable.contentY = target
  }

  onFilterChanged: {
    if (root.cursorIndex > 0) root.cursorIndex = -1
    root.scrollToTop()
  }

  onSearchQueryChanged: {
    if (root.searchQuery === "") root.filter = "top"
    root.cursorIndex = -1
    searchTimer.restart()
  }

  Timer {
    id: searchTimer
    interval: 300
    repeat: false
    onTriggered: if (root.alive) root.performSearch(root.searchQuery)
  }

  onVisibleChanged: {
    if (!root.visible) {
      searchTimer.stop()
      root.searchGeneration++
      root.searching = false
      return
    }
    searchTimer.stop()
    var q = root.searchQuery.trim()
    if (!q) {
      root.searchGeneration++
      root.results = { tracks: [], artists: [], albums: [], playlists: [] }
      root.resultsQuery = ""
      root.searching = false
    } else if (root.resultsQuery !== q) {
      root.performSearch(q)
    }
  }

  // Filter pills pinned below the search bar. "All" is the mixed list. The
  // row layout grows each pill from its real label width and shares the
  // leftover space, so padding stays even and the last pill ends flush.
  RowLayout {
    id: filterPills
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Design.pageGutter
    anchors.rightMargin: Design.pageGutter
    anchors.topMargin: 12
    spacing: 8
    visible: root.searchQuery !== ""

    Repeater {
      model: root.filterPillsModel

      Rectangle {
        id: pill
        required property var modelData
        Layout.fillWidth: true
        Layout.preferredWidth: pillText.implicitWidth + 16
        Layout.preferredHeight: 30
        radius: 15
        readonly property bool hasCursor: root.keyboardNav && root.cursorOnPills && root.filter === pill.modelData.key
        border.color: hasCursor ? Color.accent : "transparent"
        border.width: hasCursor ? 1 : 0
        color: root.filter === pill.modelData.key
          ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
          : (pillMa.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.09))

        Text {
          id: pillText
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: pill.modelData.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall || 12
          font.weight: Font.DemiBold
        }

        MouseArea {
          id: pillMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.filter = pill.modelData.key
        }
      }
    }
  }

  Flickable {
    id: searchFlickable
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.top: filterPills.visible ? filterPills.bottom : parent.top
    anchors.topMargin: filterPills.visible ? 12 : 16
    contentHeight: Design.scrollContentHeight(contentCol.implicitHeight, searchFlickable.height, root.bottomInset, 24)
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    SmoothScrollHandler { id: scrollHandler }

    Column {
      id: contentCol
      // Inset so headings and pills sit on the content line; result rows
      // escape it to the panel edges (see Design.pageGutter).
      x: Design.pageGutter
      width: searchFlickable.width - 2 * Design.pageGutter
      spacing: Style.space(14)

      // Case A: Recent Searches
      Column {
        width: parent.width
        // Rows are flush; the 8 px the Column used to put between them is
        // split into 4 px of extra padding above and below each row's content.
        spacing: 0
        visible: root.searchQuery === ""

        RowLayout {
          width: parent.width
          visible: root.recentSearches.length > 0

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            Layout.fillHeight: true
            verticalAlignment: Text.AlignVCenter
            text: "Recent Searches"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle || 15
            font.weight: Font.Bold
          }

          Rectangle {
            Layout.preferredWidth: 28
            Layout.preferredHeight: 28
            Layout.alignment: Qt.AlignVCenter
            radius: 14
            color: clearAllMa.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12) : "transparent"

            SvgIcon {
              anchors.centerIn: parent
              size: 14
              color: root.foreground
              opacity: 0.6
              source: Qt.resolvedUrl("../../assets/icons/close.svg")
            }

            MouseArea {
              id: clearAllMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.svc) root.svc.clearRecentSearches()
            }

            ButtonToolTip {
              host: clearAllMa
              text: "Clear recent searches"
              fontFamily: root.fontFamily
            }
          }
        }

        // Half the removed Column spacing, so the first row's content stays
        // where it was.
        Item {
          width: parent.width
          height: root.recentSearches.length > 0 ? 4 : 0
        }

        Repeater {
          id: recentRepeater
          model: root.recentSearches

          Rectangle {
            id: recentRow
            required property var modelData
            required property int index
            readonly property bool hasCursor: root.keyboardNav && root.cursorIndex === recentRow.index + 1
            readonly property bool hovered: recentMa.containsMouse && !root.keyboardNav

            // Full-bleed band: the fill and the click target reach the panel
            // edges, the row's content stays on Design.pageGutter.
            x: -Design.pageGutter
            width: contentCol.width + 2 * Design.pageGutter
            height: 52
            radius: 0
            color: recentRow.hasCursor
              ? Style.hoverFillFor(root.foreground, Color.accent)
              : "transparent"

            HoverFill {
              anchors.fill: parent
              tint: root.foreground
              strength: 0.08
              active: recentRow.hovered
              instant: root.keyboardNav
            }

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Design.pageGutter
              anchors.rightMargin: Design.pageGutter
              anchors.topMargin: 4
              anchors.bottomMargin: 4
              spacing: 12

              Rectangle {
                Layout.preferredWidth: 34
                Layout.preferredHeight: 34
                radius: 17
                clip: true
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)

                SvgIcon {
                  anchors.centerIn: parent
                  size: 16
                  color: root.foreground
                  opacity: 0.7
                  source: Qt.resolvedUrl("../../assets/icons/search.svg")
                }
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: typeof recentRow.modelData === "string" ? recentRow.modelData : (recentRow.modelData.title || "")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: 13
                font.weight: Font.DemiBold
                elide: Text.ElideRight
              }
            }

            CursorRules {
              anchors.fill: parent
              shown: recentRow.hasCursor
            }

            MouseArea {
              id: recentMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.rowHovered(recentRow.index + 1)
              onExited: root.rowUnhovered(recentRow.index + 1)
              onClicked: {
                var q = typeof recentRow.modelData === "string" ? recentRow.modelData : (recentRow.modelData.title || "")
                root.queryRequested(q)
                root.performSearch(q)
              }
            }
          }
        }
      }

      // Case B: search results (mixed "Top" list or one type from the pills)
      Column {
        width: parent.width
        // Rows are flush; the 6 px the Column used to put between them is
        // split into 3 px of extra padding above and below each row's content.
        spacing: 0
        visible: root.searchQuery !== ""

        // Loading spinner — centered in the blank results area for a fresh
        // search, a small hint above existing results otherwise.
        Item {
          width: parent.width
          readonly property bool hasResults: root.resultRows.length > 0
          height: !root.searching ? 0
            : (hasResults ? 40 : Math.max(40, searchFlickable.height - y - root.bottomInset - Style.space(24)))
          visible: root.searching

          TidalLogo {
            anchors.centerIn: parent
            size: 32
            color: root.foreground
            pulsing: root.searching
          }
        }

        // Half the removed Column spacing, so the first row's content stays
        // where it was.
        Item {
          width: parent.width
          height: root.searching && root.resultRows.length > 0 ? 3 : 0
        }

        Repeater {
          id: resultRepeater
          model: root.resultRows

          Rectangle {
            id: resultRow
            required property var modelData
            required property int index
            readonly property bool isAvailable: resultRow.modelData.available !== false
            readonly property bool hasCursor: root.keyboardNav && root.cursorIndex === resultRow.index + 1
            readonly property bool hovered: rowMa.containsMouse && !root.keyboardNav
            // Full-bleed band: the fill and the click target reach the panel
            // edges, the row's content stays on Design.pageGutter.
            x: -Design.pageGutter
            width: contentCol.width + 2 * Design.pageGutter
            height: 54
            radius: 0
            readonly property bool isCurrent: resultRow.modelData.kind === "track" && root.svc
              && String(root.svc.currentTrackId || "") === String(resultRow.modelData.id || "")
            color: resultRow.hasCursor
              ? Style.hoverFillFor(root.foreground, Color.accent)
              : (resultRow.isCurrent
                ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.15)
                : "transparent")

            HoverFill {
              anchors.fill: parent
              tint: resultRow.isCurrent ? Color.accent : root.foreground
              strength: resultRow.isCurrent ? 0.08 : 0.1
              active: resultRow.hovered && resultRow.isAvailable
              instant: root.keyboardNav
            }

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Design.pageGutter
              anchors.rightMargin: Design.pageGutter
              spacing: 10
              opacity: resultRow.isAvailable ? 1.0 : 0.4

              Rectangle {
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: 36
                Layout.preferredHeight: 36
                radius: resultRow.modelData.kind === "artist" ? 18 : 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
                border.width: resultRow.modelData.kind === "artist" ? 0 : 1
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

                RoundedImage {
                  id: resultArt
                  anchors.fill: parent
                  radius: resultRow.modelData.kind === "artist" ? 18 : 2
                  borderWidth: resultRow.modelData.kind === "artist" ? 0 : 1
                  borderColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
                  source: resultRow.modelData.artUrl || ""
                  sourceSize.width: 80
                  sourceSize.height: 80
                  visible: source !== ""
                }

                TidalLogo {
                  anchors.centerIn: parent
                  size: 16
                  color: root.foreground
                  faint: true
                  visible: !resultArt.showingImage
                }
              }

              Column {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 2
                clip: true

                FadeText {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: resultRow.modelData.title
                  color: resultRow.isCurrent ? Color.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: 12
                  font.weight: Font.DemiBold
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: resultRow.modelData.subtitle || ""
                  visible: text !== ""
                  color: root.foreground
                  opacity: 0.65
                  font.family: root.fontFamily
                  font.pixelSize: 10
                  elide: Text.ElideRight
                }
              }
            }

            CursorRules {
              anchors.fill: parent
              shown: resultRow.hasCursor
            }

            MouseArea {
              id: rowMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: resultRow.isAvailable ? Qt.PointingHandCursor : Qt.ArrowCursor
              onEntered: root.rowHovered(resultRow.index + 1)
              onExited: root.rowUnhovered(resultRow.index + 1)
              onClicked: if (resultRow.isAvailable) root.activateRow(resultRow.modelData)
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.resultsLoaded && root.resultRows.length === 0
          text: root.emptyMessage
          color: root.foreground
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.body || 13
          horizontalAlignment: Text.AlignHCenter
          topPadding: 24
        }
      }
    }
  }
}
