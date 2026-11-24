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
  property real bottomInset: 0
  // Height of the floating PlayerHeader overlay. The page starts below it,
  // then scrolls underneath it like the artist and playlist pages.
  readonly property int topBarHeight: 52

  signal playlistSelected(string id, string title, string artUrl)
  signal mixSelected(string id, string title, string artUrl, string recentSubtitle)
  signal albumSelected(string id, string title, string artUrl)
  signal artistSelected(string id, string title, string artUrl)
  signal topTracksSelected(string id, string title, string artUrl)
  signal artistRadioSelected(string id, string title, string subtitle, string artUrl)
  signal trackSelected(var item)
  signal categorySelected(string category)

  readonly property var recentItems: svc ? svc.recentItems : []
  // The first six of the account's Custom mixes page (Daily Discovery, New
  // Arrivals, My Mix 1-4); the full list lives on the Mixes page.
  property var mixItems: []
  property bool loading: false
  property int requestGeneration: 0

  readonly property var categories: [
    { key: "tracks", title: "Tracks", icon: "tracks.svg" },
    { key: "artists", title: "Artists", icon: "artists.svg" },
    { key: "playlists", title: "Playlists", icon: "playlists.svg" },
    { key: "albums", title: "Albums", icon: "albums.svg" }
  ]

  function refresh() {
    var generation = ++root.requestGeneration
    if (!root.svc) {
      root.loading = false
      return
    }
    if (root.recentItems.length === 0) root.loading = true
    // Two catalogue calls feed the page; the loader clears when both land so
    // the Mixes section cannot pop in after the spinner has gone.
    var pending = 2
    var done = function() {
      if (!root || !root.alive || generation !== root.requestGeneration) return
      pending -= 1
      if (pending <= 0) root.loading = false
    }
    root.svc.fetchRecent(function() { done() })
    root.svc.fetchMixes(function(list) {
      if (!root || !root.alive || generation !== root.requestGeneration) return
      root.mixItems = list || []
      done()
    })
  }

  // Called by MiniPlayer on fresh navigation (push/setFace). Back-navigation
  // leaves the Flickable alone so the user returns to where they were.
  function scrollToTop() {
    scrollHandler.reset()
    if (collectionsFlick.contentY !== 0) collectionsFlick.contentY = 0
  }

  function openRecentItem(item) {
    if (!item) return
    var id = String(item.id || "")
    var title = String(item.title || "")
    var artUrl = String(item.art_url || "")
    var subtitle = String(item.subtitle || "")
    if (item.type === "mix") {
      // A track radio is stored as a mix with the song it was started from as
      // its subtitle, so pass it back or the reopened page loses the label.
      root.mixSelected(id, title, artUrl, subtitle)
    } else if (item.type === "album") {
      root.albumSelected(id, title, artUrl)
    } else if (item.type === "artist") {
      root.artistSelected(id, title, artUrl)
    } else if (item.type === "artistTopTracks") {
      root.topTracksSelected(id, title, artUrl)
    } else if (item.type === "artistRadio") {
      root.artistRadioSelected(id, title || "Artist Radio", subtitle, artUrl)
    } else if (item.type === "favorites") {
      root.categorySelected("tracks")
    } else if (item.type === "track") {
      root.trackSelected(item)
    } else {
      root.playlistSelected(id, title, artUrl)
    }
  }

  function openMixItem(item) {
    if (!item) return
    // A library mix is not a track radio, so it carries no source-song label;
    // the mix page keeps its own subtitle.
    root.mixSelected(String(item.id || ""), String(item.title || ""), String(item.art_url || ""), "")
  }

  // ---- Keyboard cursor --------------------------------------------------------

  property int cursorIndex: -1
  readonly property int categoryCount: root.categories.length
  readonly property int recentCount: Math.min(6, root.recentItems.length)
  readonly property int mixCount: Math.min(6, root.mixItems.length)
  readonly property int cursorCount: root.categoryCount + root.recentCount + root.mixCount

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

  function cursorItem(index) {
    if (index < 0) return null
    if (index < root.categoryCount) return catRepeater.itemAt(index)
    var rest = index - root.categoryCount
    if (rest < root.recentCount) return gridRepeater.itemAt(rest)
    return mixRepeater.itemAt(rest - root.recentCount)
  }

  // Every section is a two-column grid, so the cursor is a list of rows of
  // global slot indices: the four category tiles, then the recent cards, then
  // the mix cards. Deriving it here keeps the sections free to come and go
  // without each one reimplementing the joins.
  function cursorRows() {
    var rows = []
    var next = 0
    function pushRows(count) {
      for (var i = 0; i < count; i += 2) {
        var row = [next + i]
        if (i + 1 < count) row.push(next + i + 1)
        rows.push(row)
      }
      next += count
    }
    pushRows(root.categoryCount)
    pushRows(root.recentCount)
    pushRows(root.mixCount)
    return rows
  }

  function cursorPosition(index, rows) {
    var list = rows || root.cursorRows()
    for (var r = 0; r < list.length; r++) {
      var c = list[r].indexOf(index)
      if (c !== -1) return { row: r, col: c }
    }
    return { row: -1, col: -1 }
  }

  function firstVisibleIndex() {
    var viewTop = collectionsFlick.contentY + root.topBarHeight
    for (var i = 0; i < root.cursorCount; i++) {
      var item = root.cursorItem(i)
      if (item && item.mapToItem(collectionsFlick.contentItem, 0, 0).y + item.height > viewTop + 1) return i
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
    var rows = root.cursorRows()
    var pos = root.cursorPosition(root.cursorIndex, rows)
    if (pos.row < 0) {
      root.cursorIndex = root.firstVisibleIndex()
      root.ensureCursorVisible()
      return
    }
    var row = pos.row
    var col = pos.col
    if (dy !== 0) {
      row = Math.max(0, Math.min(rows.length - 1, row + dy))
      // An odd last row can be shorter than the one the cursor came from.
      col = Math.min(col, rows[row].length - 1)
    } else if (dx !== 0) {
      col = Math.max(0, Math.min(rows[row].length - 1, col + dx))
    }
    root.cursorIndex = rows[row][col]
    root.ensureCursorVisible()
  }

  function pageCursor(direction) {
    if (root.cursorCount === 0) return
    root.beginKeyboardNav()
    if (root.cursorIndex < 0) {
      root.cursorIndex = root.firstVisibleIndex()
      root.ensureCursorVisible()
      return
    }
    var rows = root.cursorRows()
    var pos = root.cursorPosition(root.cursorIndex, rows)
    if (pos.row < 0) return
    var row = Math.max(0, Math.min(rows.length - 1, pos.row + direction * 2))
    root.cursorIndex = rows[row][Math.min(pos.col, rows[row].length - 1)]
    root.ensureCursorVisible()
  }

  function homeEndCursor(toEnd) {
    if (root.cursorCount === 0) return
    root.beginKeyboardNav()
    root.cursorIndex = toEnd ? root.cursorCount - 1 : 0
    root.ensureCursorVisible()
  }

  function activateCursor() {
    if (root.cursorIndex < 0) return
    if (root.cursorIndex < root.categoryCount) {
      root.categorySelected(root.categories[root.cursorIndex].key)
      return
    }
    var rest = root.cursorIndex - root.categoryCount
    if (rest < root.recentCount) root.openRecentItem(root.recentItems[rest])
    else root.openMixItem(root.mixItems[rest - root.recentCount])
  }

  function ensureCursorVisible() {
    var item = root.cursorItem(root.cursorIndex)
    if (!item) return
    var top = item.mapToItem(collectionsFlick.contentItem, 0, 0).y
    var bottom = top + item.height
    var viewTop = collectionsFlick.contentY + root.topBarHeight
    // Keep the row above the collapsed player docked at the bottom.
    var viewBottom = collectionsFlick.contentY + collectionsFlick.height - root.bottomInset
    var margin = Style.space(8)
    var target = collectionsFlick.contentY
    if (top - margin < viewTop) target = top - margin - root.topBarHeight
    else if (bottom + margin > viewBottom) target = bottom + margin - (collectionsFlick.height - root.bottomInset)
    var maxY = Math.max(0, collectionsFlick.contentHeight - collectionsFlick.height)
    target = Math.max(0, Math.min(maxY, target))
    if (Math.abs(target - collectionsFlick.contentY) < 1) return
    scrollHandler.reset()
    collectionsFlick.contentY = target
  }

  onSvcChanged: if (root.svc && visible) root.refresh()
  onVisibleChanged: if (visible && root.svc && (root.recentItems.length === 0 || root.mixItems.length === 0)) root.refresh()
  Component.onCompleted: if (root.visible) root.refresh()

  // Pulsing TIDAL Logo loading indicator
  TidalLogo {
    anchors.centerIn: parent
    size: 40
    color: root.foreground
    pulsing: root.loading && root.recentItems.length === 0
    visible: root.loading && root.recentItems.length === 0
  }

  Flickable {
    id: collectionsFlick
    anchors.fill: parent
    contentHeight: Design.scrollContentHeight(col.y + col.implicitHeight, collectionsFlick.height, root.bottomInset, 16)
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    SmoothScrollHandler { id: scrollHandler }

    Column {
      id: col
      y: root.topBarHeight + Style.space(16)
      // The column is inset; the category rows escape it to the panel edges
      // and the recently played cards overhang it by their own padding (see
      // Design.pageGutter).
      x: Design.pageGutter
      width: collectionsFlick.width - 2 * Design.pageGutter
      spacing: Style.space(16)

      // Section 1: the four collection categories as a 2x2 tile grid, so the
      // page opens on the doorways rather than on a list of them.
      Grid {
        id: catGrid
        width: parent.width
        columns: 2
        spacing: 8

        Repeater {
          id: catRepeater
          model: root.categories

          Rectangle {
            id: catCard
            required property var modelData
            required property int index
            readonly property bool hasCursor: root.keyboardNav && root.cursorIndex === catCard.index
            readonly property bool hovered: catMa.containsMouse && !root.keyboardNav

            width: (col.width - 8) / 2
            height: 54
            radius: 0
            border.color: catCard.hasCursor ? Color.accent : "transparent"
            border.width: catCard.hasCursor ? 1 : 0
            color: catCard.hasCursor
              ? Style.hoverFillFor(root.foreground, Color.accent)
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)

            HoverFill {
              anchors.fill: parent
              tint: root.foreground
              strength: 0.08
              active: catCard.hovered
              instant: root.keyboardNav
            }

            RowLayout {
              anchors.fill: parent
              anchors.margins: 4
              spacing: 8

              // The category's icon takes the recently played card's sleeve.
              Rectangle {
                Layout.preferredWidth: 46
                Layout.preferredHeight: 46
                radius: 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
                border.width: 1
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

                SvgIcon {
                  anchors.centerIn: parent
                  size: 22
                  color: root.foreground
                  source: Qt.resolvedUrl("../../assets/icons/" + catCard.modelData.icon)
                }
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: catCard.modelData.title
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall || 12
                font.weight: Font.DemiBold
                elide: Text.ElideRight
              }
            }

            CursorRules {
              anchors.fill: parent
              shown: catCard.hasCursor
            }

            MouseArea {
              id: catMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.rowHovered(catCard.index)
              onExited: root.rowUnhovered(catCard.index)
              onClicked: root.categorySelected(catCard.modelData.key)
            }
          }
        }
      }

      // Section 2: 2x3 Grid of Recently Played Items
      Column {
        width: parent.width
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          text: "Recently Played"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle || 15
          font.weight: Font.Bold
          visible: root.recentItems.length > 0
        }

        Grid {
          width: parent.width
          columns: 2
          spacing: 8
          visible: root.recentItems.length > 0

          Repeater {
            id: gridRepeater
            model: root.recentItems.slice(0, 6)

            Rectangle {
              id: gridCard
              required property var modelData
              required property int index
              readonly property bool isFavoritesCard: gridCard.modelData.type === "favorites" || gridCard.modelData.id === "favorites"
              // Top-tracks contexts are played from an artist, so their art is
              // artist imagery — shown circular everywhere else (the artists
              // grid, header avatars), so the card sleeve matches.
              readonly property bool isArtistArt: gridCard.modelData.type === "artistTopTracks"
                || gridCard.modelData.type === "artistRadio"
              readonly property bool hasCursor: root.keyboardNav && root.cursorIndex === root.categoryCount + gridCard.index
              readonly property bool hovered: cardMa.containsMouse && !root.keyboardNav

              width: (col.width - 8) / 2
              height: 54
              // Square corners: these read as tiles in a grid, not as rows.
              radius: 0
              border.color: gridCard.hasCursor ? Color.accent : "transparent"
              border.width: gridCard.hasCursor ? 1 : 0
              color: gridCard.hasCursor
                ? Style.hoverFillFor(root.foreground, Color.accent)
                : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)

              HoverFill {
                anchors.fill: parent
                tint: root.foreground
                strength: 0.08
                active: gridCard.hovered
                instant: root.keyboardNav
              }

              RowLayout {
                anchors.fill: parent
                anchors.margins: 4
                spacing: 8

                // Thumbnail
                Rectangle {
                  Layout.preferredWidth: 46
                  Layout.preferredHeight: 46
                  radius: gridCard.isArtistArt ? width / 2 : 2
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
                  border.width: 1
                  border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

                  RoundedImage {
                    id: recentArt
                    anchors.fill: parent
                    radius: gridCard.isArtistArt ? width / 2 : 2
                    borderWidth: 1
                    borderColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
                    source: gridCard.modelData.art_url || ""
                    sourceSize.width: 92
                    sourceSize.height: 92
                    visible: !isFavoritesCard && source !== ""
                  }

                  // TIDAL draws the Tracks sleeve client-side and exposes no
                  // artwork for it, so it wears the Tracks category tile's icon.
                  SvgIcon {
                    anchors.centerIn: parent
                    size: 22
                    color: root.foreground
                    source: Qt.resolvedUrl("../../assets/icons/tracks.svg")
                    visible: isFavoritesCard
                  }

                  TidalLogo {
                    anchors.centerIn: parent
                    size: 18
                    color: root.foreground
                    faint: true
                    visible: !isFavoritesCard && !recentArt.showingImage
                  }
                }

                // Title & Subtitle
                Column {
                  Layout.fillWidth: true
                  Layout.alignment: Qt.AlignVCenter
                  spacing: 2
                  clip: true

                  FadeText {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: gridCard.modelData.type === "artistTopTracks"
                      ? String(gridCard.modelData.title || "").replace(/\s*(?:-\s*)?Top Tracks$/, "")
                      : ((gridCard.modelData.title === "Favorite Tracks" || gridCard.modelData.type === "favorites") ? "Tracks" : (gridCard.modelData.title || ""))
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                    maximumLineCount: 1
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: gridCard.modelData.type === "favorites" ? ""
                      : (gridCard.modelData.subtitle || (gridCard.modelData.type === "playlist" ? "Playlist"
                      : (gridCard.modelData.type === "mix" ? "Mix"
                      : (gridCard.modelData.type === "artistRadio" ? "Radio"
                      : (gridCard.modelData.type === "artistTopTracks" ? "Top Tracks"
                      : (gridCard.modelData.type === "album" ? "Album"
                      : (gridCard.modelData.type === "track" ? "Track" : "Artist")))))))
                    visible: text !== ""
                    color: root.foreground
                    opacity: 0.65
                    font.family: root.fontFamily
                    font.pixelSize: 10
                    elide: Text.ElideRight
                    maximumLineCount: 1
                  }
                }
              }

              MouseArea {
                id: cardMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.rowHovered(root.categoryCount + gridCard.index)
                onExited: root.rowUnhovered(root.categoryCount + gridCard.index)
                onClicked: root.openRecentItem(gridCard.modelData)
              }
            }
          }
        }
      }

      // Section 3: Mixes — the same 2x3 grid as recently played, filled
      // from the Custom mixes page, with the full list one click away.
      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.mixItems.length > 0

        RowLayout {
          width: parent.width

          Text {
            textFormat: Text.PlainText
            text: "Mixes"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle || 15
            font.weight: Font.Bold
          }

          Item { Layout.fillWidth: true }

          ViewAllButton {
            text: "View more"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.categorySelected("mixes")
          }
        }

        Grid {
          width: parent.width
          columns: 2
          spacing: 8

          Repeater {
            id: mixRepeater
            model: root.mixItems.slice(0, 6)

            Rectangle {
              id: mixCard
              required property var modelData
              required property int index
              readonly property bool hasCursor: root.keyboardNav && root.cursorIndex === root.categoryCount + root.recentCount + mixCard.index
              readonly property bool hovered: mixMa.containsMouse && !root.keyboardNav

              width: (col.width - 8) / 2
              height: 54
              radius: 0
              border.color: mixCard.hasCursor ? Color.accent : "transparent"
              border.width: mixCard.hasCursor ? 1 : 0
              color: mixCard.hasCursor
                ? Style.hoverFillFor(root.foreground, Color.accent)
                : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)

              HoverFill {
                anchors.fill: parent
                tint: root.foreground
                strength: 0.08
                active: mixCard.hovered
                instant: root.keyboardNav
              }

              RowLayout {
                anchors.fill: parent
                anchors.margins: 4
                spacing: 8

                Rectangle {
                  Layout.preferredWidth: 46
                  Layout.preferredHeight: 46
                  radius: 2
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
                  border.width: 1
                  border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

                  RoundedImage {
                    id: mixArt
                    anchors.fill: parent
                    radius: 2
                    borderWidth: 1
                    borderColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
                    source: mixCard.modelData.art_url || ""
                    sourceSize.width: 92
                    sourceSize.height: 92
                    visible: source !== ""
                  }

                  TidalLogo {
                    anchors.centerIn: parent
                    size: 18
                    color: root.foreground
                    faint: true
                    visible: !mixArt.showingImage
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
                    text: mixCard.modelData.title || ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                    maximumLineCount: 1
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: mixCard.modelData.subtitle || "Mix"
                    color: root.foreground
                    opacity: 0.65
                    font.family: root.fontFamily
                    font.pixelSize: 10
                    elide: Text.ElideRight
                    maximumLineCount: 1
                  }
                }
              }

              MouseArea {
                id: mixMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.rowHovered(root.categoryCount + root.recentCount + mixCard.index)
                onExited: root.rowUnhovered(root.categoryCount + root.recentCount + mixCard.index)
                onClicked: root.openMixItem(mixCard.modelData)
              }
            }
          }
        }
      }
    }
  }
}
