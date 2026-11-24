import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Bottom sheet that adds the given tracks to playlists. Existing playlists
// are listed; "New playlist" reveals a name field. Both paths go through the
// Service playlist helpers, which own the TIDAL API calls and their ETags.
//
// The sheet stays open while it is used: a click files the tracks into that
// playlist and marks the row done (or badges it on failure), so several
// playlists can be filled in one visit.
Item {
  id: root

  property bool alive: true
  Component.onDestruction: root.alive = false

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  property bool open: false
  property var trackIds: []

  signal closeRequested()

  anchors.fill: parent
  // Clips the sheet's hidden bottom-corner overhang so it never pokes past
  // the view while sliding.
  clip: true
  visible: opacity > 0.01
  enabled: open
  opacity: open ? 1.0 : 0.0

  Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

  Shortcut {
    sequence: "Escape"
    enabled: root.open
    onActivated: root.closeRequested()
  }

  property var playlists: []
  property bool loading: false
  property bool creating: false
  property bool createPending: false
  property string newTitle: ""
  // Per-playlist state for this visit: "pending" while the add is in flight,
  // "added" once the track is in (a track already there reads as added too),
  // "error" when TIDAL refused. Reassigned, never mutated, so row bindings
  // re-evaluate.
  property var rowState: ({})

  // Keyboard cursor over the New playlist row (0) and the playlist rows.
  property int cursorIndex: -1
  readonly property int itemCount: 1 + root.playlists.length

  function ensureCursorVisible() {
    if (!playlistFlick || root.cursorIndex <= 0) return
    var rowTop = (root.cursorIndex - 1) * 46
    var rowBottom = rowTop + 46
    if (rowTop < playlistFlick.contentY) playlistFlick.contentY = rowTop
    else if (rowBottom > playlistFlick.contentY + playlistFlick.height) {
      playlistFlick.contentY = Math.max(0, rowBottom - playlistFlick.height)
    }
  }

  function moveCursor(delta) {
    if (root.creating || root.createPending || delta === 0) return
    if (root.cursorIndex < 0) {
      root.cursorIndex = delta > 0 ? 0 : root.itemCount - 1
      root.ensureCursorVisible()
      return
    }
    root.cursorIndex = Math.max(0, Math.min(root.itemCount - 1, root.cursorIndex + delta))
    root.ensureCursorVisible()
  }

  function activateCursor() {
    if (root.creating || root.createPending || root.cursorIndex < 0) return
    if (root.cursorIndex === 0) {
      root.startCreating()
      return
    }
    var playlist = root.playlists[root.cursorIndex - 1]
    if (playlist) root.fileInto(playlist.id, playlist.title || "playlist")
  }

  function startCreating() {
    root.creating = true
    Qt.callLater(function() { if (root && root.alive && newName) newName.forceActiveFocus() })
  }

  function refresh() {
    root.loading = true
    if (!root.svc) {
      root.loading = false
      return
    }
    root.svc.fetchPlaylists(function(list) {
      if (!root || !root.alive) return
      root.playlists = list || []
      root.loading = false
    })
  }

  function stateOf(playlistId) {
    return root.rowState[String(playlistId)] || ""
  }

  function setState(playlistId, state) {
    var next = {}
    for (var key in root.rowState) next[key] = root.rowState[key]
    next[String(playlistId)] = state
    root.rowState = next
  }

  // Filing is per-row: the row marks itself pending, then added (a track that
  // was already in reads as added too) or badged on failure. The sheet stays
  // open so more playlists can be filled in the same visit.
  function fileInto(playlistId, name) {
    if (!root.svc) return
    var id = String(playlistId)
    var state = root.stateOf(id)
    if (state === "added" || state === "pending") return
    root.setState(id, "pending")
    root.svc.addTracksToPlaylist(playlistId, root.trackIds.slice(), function(err, data) {
      if (!root || !root.alive || !root.svc) return
      root.setState(id, err ? "error" : "added")
    })
  }

  function createAndFile() {
    var title = root.newTitle.trim()
    if (!title || root.createPending || !root.svc) return
    root.createPending = true
    root.svc.createPlaylist(title, "", function(err, data) {
      if (!root || !root.alive) return
      root.createPending = false
      if (!root.svc) return
      if (err || !data || !data.id) {
        root.svc.notify("Could not create playlist")
        return
      }
      root.creating = false
      root.newTitle = ""
      if (newName) newName.text = ""
      root.fileInto(data.id, data.title || title)
      // Bring the new playlist into the list; its row keeps the state mark.
      root.refresh()
    })
  }

  onOpenChanged: {
    if (root.open) {
      root.creating = false
      root.newTitle = ""
      if (newName) newName.text = ""
      root.createPending = false
      root.rowState = {}
      root.cursorIndex = -1
      root.refresh()
    }
  }

  PointerHandoff {
    onMoved: if (root.cursorIndex >= 0) root.cursorIndex = -1
  }

  // Scrolling over the open sheet must not reach the page (or the collapsed
  // player's seek bar) underneath it.
  WheelShield {}

  // Backdrop that dismisses the sheet on an outside click. Only a click outside
  // the sheet closes it: the sheet swallows clicks on itself, so blank space
  // inside is not a dismiss target. Accepting the right button here keeps a
  // right-click outside working as a dismiss too.
  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.65)

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      // Taking hover as well as clicks keeps the UI behind the scrim from
      // lighting up under the pointer: hover goes to the topmost item that
      // accepts it, so every row underneath stays unlit while the sheet is open.
      hoverEnabled: true
      onClicked: root.closeRequested()
    }
  }

  Rectangle {
    id: sheet
    readonly property real corner: 14
    width: parent.width
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: -corner
    height: Math.min(parent.height - 20, sheetCol.implicitHeight) + corner
    color: Color.popups.background
    radius: corner
    clip: true

    // Swallows clicks on the sheet so blank space inside it does not reach the
    // backdrop. Declared before the rows, so their own MouseAreas sit on top.
    // A right click anywhere on the sheet dismisses it: the rows take the left
    // button only, so a right click over one falls through here.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) root.closeRequested()
      }
    }

    // Anchors own `y`, so the slide-up is a translate offset instead.
    transform: Translate {
      y: root.open ? 0 : 40
      Behavior on y { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
    }

    Column {
      id: sheetCol
      width: parent.width
      spacing: 4

      Item {
        width: parent.width
        height: 14

        Rectangle {
          anchors.centerIn: parent
          width: 36
          height: 4
          radius: 2
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width - 32
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Add to playlist"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: 15
        font.weight: Font.Bold
        topPadding: 4
        bottomPadding: 8
      }

      // New playlist row (expands into a name field)
      Rectangle {
        id: newRow
        width: parent.width
        height: root.creating ? 84 : 46
        readonly property bool hasCursor: root.cursorIndex === 0
        color: hasCursor
          ? Style.hoverFillFor(root.foreground, Color.accent)
          : (newMa.containsMouse && root.cursorIndex < 0 ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08) : "transparent")

        Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        Column {
          anchors.fill: parent
          anchors.leftMargin: 16
          anchors.rightMargin: 16
          spacing: 6

          RowLayout {
            width: parent.width
            height: 46
            spacing: 14

            SvgIcon {
              size: 18
              color: root.foreground
              source: Qt.resolvedUrl("../../assets/icons/playlists.svg")
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: "New playlist"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: 13
              font.weight: Font.DemiBold
            }

            SvgIcon {
              visible: !root.creating
              size: 14
              color: root.foreground
              opacity: 0.7
              source: Qt.resolvedUrl("../../assets/icons/chevron-right.svg")
            }
          }

          RowLayout {
            width: parent.width
            height: 30
            spacing: 8
            visible: root.creating

            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: 30
              radius: 6
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
              border.color: newName.activeFocus ? Color.popups.border : "transparent"
              border.width: 1

              TextInput {
                id: newName
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: 13
                selectByMouse: true
                onTextChanged: root.newTitle = text
                onAccepted: root.createAndFile()
              }
            }

            Rectangle {
              Layout.preferredWidth: 64
              Layout.preferredHeight: 30
              radius: 6
              color: createMa.containsMouse
                ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
                : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: "Create"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: 12
                font.weight: Font.Bold
              }

              MouseArea {
                id: createMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.createAndFile()
              }
            }
          }
        }

        MouseArea {
          id: newMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          enabled: !root.creating
          onClicked: root.startCreating()
        }

        // Full-bleed row: rules above and below mark the cursor without a
        // side border on the panel edge.
        CursorRules {
          anchors.fill: parent
          shown: newRow.hasCursor
        }
      }

      // Existing playlists
      Flickable {
        id: playlistFlick
        width: parent.width
        height: Math.min(root.playlists.length * 46, Style.space(280))
        contentHeight: playlistCol.implicitHeight
        clip: true
        visible: root.playlists.length > 0

        Column {
          id: playlistCol
          width: parent.width

          Repeater {
            model: root.playlists

            Rectangle {
              id: plRow
              required property var modelData
              required property int index
              readonly property bool hasCursor: root.cursorIndex === 1 + plRow.index

              width: playlistCol.width
              height: 46
              color: plRow.hasCursor
                ? Style.hoverFillFor(root.foreground, Color.accent)
                : (plMa.containsMouse && root.cursorIndex < 0 ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08) : "transparent")

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 12

                Rectangle {
                  Layout.preferredWidth: 30
                  Layout.preferredHeight: 30
                  radius: 2
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
                  border.width: 1
                  border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

                  RoundedImage {
                    id: plArt
                    anchors.fill: parent
                    radius: 2
                    borderWidth: 1
                    borderColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
                    source: plRow.modelData.art_url || ""
                    sourceSize.width: 60
                    sourceSize.height: 60
                    visible: source !== ""
                  }

                  TidalLogo {
                    anchors.centerIn: parent
                    size: 14
                    color: root.foreground
                    faint: true
                    visible: !plArt.showingImage
                  }
                }

                FadeText {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: plRow.modelData.title || ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: 13
                }

                // Right edge: the track count until a click speaks, then
                // the row's own state (working, done, failed).
                Text {
                  textFormat: Text.PlainText
                  text: (plRow.modelData.track_count !== undefined && plRow.modelData.track_count !== null)
                    ? (plRow.modelData.track_count + (Number(plRow.modelData.track_count) === 1 ? " track" : " tracks")) : ""
                  color: root.foreground
                  opacity: 0.5
                  font.family: root.fontFamily
                  font.pixelSize: 10
                  visible: root.stateOf(plRow.modelData.id) === ""
                }

                TidalLogo {
                  size: 12
                  color: root.foreground
                  pulsing: true
                  visible: root.stateOf(plRow.modelData.id) === "pending"
                }

                SvgIcon {
                  size: 16
                  color: Color.accent
                  source: Qt.resolvedUrl("../../assets/icons/check.svg")
                  visible: root.stateOf(plRow.modelData.id) === "added"
                }

                // A failed add reports on the row itself (the sheet stays
                // open); the badge clears on the next attempt.
                Rectangle {
                  width: 14
                  height: 14
                  radius: 7
                  color: Color.urgent
                  visible: root.stateOf(plRow.modelData.id) === "error"

                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: "!"
                    color: Color.popups.background
                    font.family: root.fontFamily
                    font.pixelSize: 9
                    font.weight: Font.Bold
                  }
                }
              }

              CursorRules {
                anchors.fill: parent
                shown: plRow.hasCursor
              }

              MouseArea {
                id: plMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.fileInto(plRow.modelData.id, plRow.modelData.title || "playlist")
              }
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width - 32
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.playlists.length === 0
        text: root.loading ? "Loading playlists…" : "No playlists yet — create one above"
        color: root.foreground
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: 12
        horizontalAlignment: Text.AlignHCenter
        topPadding: 8
        bottomPadding: 8
      }

      Item {
        width: parent.width
        height: 8
      }
    }
  }
}
