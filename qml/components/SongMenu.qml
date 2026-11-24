import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Item {
  id: root

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  property bool open: false
  property bool isCurrentTrack: true

  signal playNextRequested()
  signal favoriteToggled()
  signal addToPlaylistRequested()
  signal removeFromPlaylistRequested()
  signal shareRequested()
  signal trackRadioRequested()
  signal goToAlbumRequested()
  signal goToArtistRequested()
  signal closeRequested()

  // "Remove from …" applies only while the playing context is a playlist the
  // signed-in user created. Triggering it flips the row to a tick and
  // "Removed from …" for the rest of this open — no notification — and the
  // removal is remembered, so the row is gone the next time the menu opens
  // for the same track and playlist.
  readonly property bool canRemoveFromPlaylist: root.svc && root.svc.currentContext
    && root.svc.currentContext.type === "playlist"
    && root.svc.currentContext.own === true
    && !!root.svc.currentContext.id
  // The tick state lives only for the open that triggered the removal.
  property bool removedShown: false
  readonly property string playlistKey: (root.svc && root.svc.currentContext
    && root.svc.currentContext.id && root.svc.currentTrackId)
    ? String(root.svc.currentContext.id) + ":" + String(root.svc.currentTrackId) : ""
  readonly property bool alreadyRemoved: root.svc && root.playlistKey !== ""
    && root.svc.removedPlaylistKey === root.playlistKey
  readonly property bool showRemoveFromPlaylist: root.removedShown
    || (root.canRemoveFromPlaylist && !root.alreadyRemoved)
  readonly property string removeFromPlaylistLabel: {
    if (!root.showRemoveFromPlaylist) return ""
    var name = String((root.svc && root.svc.currentContext && root.svc.currentContext.title) || "playlist")
    if (name.length > 24) name = name.slice(0, 23) + "\u2026"
    return (root.removedShown ? "Removed from \u201C" : "Remove from \u201C") + name + "\u201D"
  }

  // Optimistic: the row flips to its tick on click and the host rolls it back
  // with revertRemove() if the removal fails. The row is a confirmation once
  // flipped, so it cannot re-trigger.
  function triggerRemoveFromPlaylist() {
    if (root.removedShown) return
    root.removedShown = true
    root.removeFromPlaylistRequested()
  }
  function revertRemove() { root.removedShown = false }

  // Keyboard cursor over the visible actions. Slots: 0 play next, 1 favourite,
  // 2 add to playlist, 3 remove from the playing playlist, 4 share, 5 track
  // radio, 6 go to album, 7 go to artist.
  property int cursorSlot: -1
  // Slot under the pointer, so a first arrow key continues from the row the
  // mouse is already on instead of jumping to the top of the menu.
  property int hoveredSlot: -1
  readonly property var activeSlots: {
    var slots = []
    for (var slot = 0; slot <= 7; slot++) {
      if (slot === 0 && root.isCurrentTrack) continue
      if (slot === 3 && !root.showRemoveFromPlaylist) continue
      slots.push(slot)
    }
    return slots
  }

  function rowHovered(slot) { root.hoveredSlot = slot }
  function rowUnhovered(slot) { if (root.hoveredSlot === slot) root.hoveredSlot = -1 }

  onOpenChanged: {
    if (root.open) {
      root.cursorSlot = -1
      root.hoveredSlot = -1
      root.removedShown = false
    } else {
      root.hoveredSlot = -1
    }
  }

  function moveCursor(delta) {
    var slots = root.activeSlots
    if (delta === 0 || slots.length === 0) return
    var pos = slots.indexOf(root.cursorSlot)
    if (pos < 0) {
      var hovered = slots.indexOf(root.hoveredSlot)
      if (hovered >= 0) {
        root.cursorSlot = slots[Math.max(0, Math.min(slots.length - 1, hovered + delta))]
        return
      }
      root.cursorSlot = delta > 0 ? slots[0] : slots[slots.length - 1]
      return
    }
    root.cursorSlot = slots[Math.max(0, Math.min(slots.length - 1, pos + delta))]
  }

  function activateCursor() {
    if (root.cursorSlot < 0) return
    if (root.cursorSlot === 0) root.playNextRequested()
    else if (root.cursorSlot === 1) root.favoriteToggled()
    else if (root.cursorSlot === 2) root.addToPlaylistRequested()
    else if (root.cursorSlot === 3) {
      // The row flips to its "Removed from …" tick and the menu stays open,
      // exactly like the mouse path.
      root.triggerRemoveFromPlaylist()
      return
    }
    else if (root.cursorSlot === 4) root.shareRequested()
    else if (root.cursorSlot === 5) root.trackRadioRequested()
    else if (root.cursorSlot === 6) root.goToAlbumRequested()
    else root.goToArtistRequested()
    root.closeRequested()
  }

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

  // Reaching for the pointer hands the menu back to the mouse: the keyboard
  // cursor clears, and the row under the pointer lights up again.
  PointerHandoff {
    onMoved: if (root.cursorSlot >= 0) root.cursorSlot = -1
  }

  // Scrolling over the open sheet must not reach the page (or the collapsed
  // player's seek bar) underneath it.
  WheelShield {}

  // Backdrop overlay that dismisses the menu on an outside click. Only a click
  // outside the sheet closes it: the sheet swallows clicks on itself, so blank
  // space inside is not a dismiss target.
  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.65)

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      // Taking hover as well as clicks keeps the UI behind the scrim from
      // lighting up under the pointer: hover goes to the topmost item that
      // accepts it, so every row underneath stays unlit while the menu is open.
      hoverEnabled: true
      onClicked: root.closeRequested()
    }
  }

  // Bottom Sheet Drawer. A uniform radius plus a negative bottom margin
  // hides the bottom pair of corners off-screen, leaving the top rounded.
  Rectangle {
    id: sheet
    readonly property real corner: 14
    width: parent.width
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
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

      // Drag pill row, above the preview header. Same compact height as the
      // picker and cast sheets, so the header starts 18 px in, not 36.
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

      // Track Info Header Row
      RowLayout {
        width: parent.width - 32
        height: 64
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 12

        Rectangle {
          Layout.preferredWidth: 48
          Layout.preferredHeight: 48
          radius: 2
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
          border.width: 1
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

          RoundedImage {
            id: menuArt
            anchors.fill: parent
            radius: 2
            borderWidth: 1
            borderColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
            source: root.svc ? root.svc.artUrl : ""
            sourceSize.width: 96
            sourceSize.height: 96
            visible: source !== ""
          }

          TidalLogo {
            anchors.centerIn: parent
            size: 20
            color: root.foreground
            faint: true
            visible: !menuArt.showingImage
          }
        }

        Column {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          spacing: 2

          FadeText {
            textFormat: Text.PlainText
            width: parent.width
            text: root.svc ? root.svc.title : ""
            font.family: root.fontFamily
            font.pixelSize: 14
            font.weight: Font.DemiBold
            color: root.foreground
            maximumLineCount: 1
          }

          FadeText {
            textFormat: Text.PlainText
            width: parent.width
            text: root.svc ? root.svc.artist : ""
            font.family: root.fontFamily
            font.pixelSize: 12
            color: root.foreground
            opacity: 0.7
            maximumLineCount: 1
          }
        }

        // Close button, centred on the preview row so it reads as part of the
        // header rather than the drag strip above it.
        Rectangle {
          id: closeBtn
          Layout.preferredWidth: 36
          Layout.preferredHeight: 36
          Layout.alignment: Qt.AlignVCenter
          radius: 18
          color: closeMa.containsMouse
            ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
            : "transparent"

          SvgIcon {
            anchors.centerIn: parent
            size: 18
            color: root.foreground
            opacity: closeMa.containsMouse ? 1.0 : 0.7
            source: Qt.resolvedUrl("../../assets/icons/close.svg")
          }

          MouseArea {
            id: closeMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.closeRequested()
          }

          ButtonToolTip {
            host: closeMa
            text: "Close"
            fontFamily: root.fontFamily
          }
        }
      }

      // Breathing room below the track preview, balancing the gap above the
      // first action.
      Item {
        width: parent.width
        height: 4
      }

      // Subtle Divider
      Rectangle {
        width: parent.width
        height: 1
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
      }

      // Space above the first action, matching the padding after the last one.
      Item {
        width: parent.width
        height: 4
      }

      // Menu Actions List
      Column {
        id: actionsColumn
        width: parent.width

        // 1. Play Next
        MenuActionItem {
          slot: 0
          hasCursor: root.cursorSlot === 0
          label: "Play next"
          iconSource: Qt.resolvedUrl("../../assets/icons/play-next.svg")
          foreground: root.foreground
          fontFamily: root.fontFamily
          visible: !root.isCurrentTrack
          onTriggered: {
            root.playNextRequested()
            root.closeRequested()
          }
        }

        // 2. Add / Remove from Collection
        MenuActionItem {
          slot: 1
          hasCursor: root.cursorSlot === 1
          label: (root.svc && root.svc.favorite) ? "Remove from tracks" : "Add to tracks"
          iconSource: (root.svc && root.svc.favorite)
            ? Qt.resolvedUrl("../../assets/icons/heart-filled.svg")
            : Qt.resolvedUrl("../../assets/icons/heart.svg")
          foreground: root.foreground
          fontFamily: root.fontFamily
          onTriggered: {
            root.favoriteToggled()
            root.closeRequested()
          }
        }

        // 3. Add to Playlist
        MenuActionItem {
          slot: 2
          hasCursor: root.cursorSlot === 2
          label: "Add to playlist"
          iconSource: Qt.resolvedUrl("../../assets/icons/playlists.svg")
          foreground: root.foreground
          fontFamily: root.fontFamily
          onTriggered: {
            root.addToPlaylistRequested()
            root.closeRequested()
          }
        }

        // 4. Remove from the playing playlist (own playlists only). The row
        // becomes the confirmation instead of closing the menu.
        MenuActionItem {
          slot: 3
          hasCursor: root.cursorSlot === 3
          label: root.removeFromPlaylistLabel
          iconSource: root.removedShown
            ? Qt.resolvedUrl("../../assets/icons/check.svg")
            : Qt.resolvedUrl("../../assets/icons/close.svg")
          foreground: root.foreground
          fontFamily: root.fontFamily
          visible: root.showRemoveFromPlaylist
          onTriggered: root.triggerRemoveFromPlaylist()
        }

        // 5. Share
        MenuActionItem {
          slot: 4
          hasCursor: root.cursorSlot === 4
          label: "Share"
          iconSource: Qt.resolvedUrl("../../assets/icons/share.svg")
          foreground: root.foreground
          fontFamily: root.fontFamily
          onTriggered: {
            root.shareRequested()
            root.closeRequested()
          }
        }

        // 6. Track Radio
        MenuActionItem {
          slot: 5
          hasCursor: root.cursorSlot === 5
          label: "Go to track radio"
          iconSource: Qt.resolvedUrl("../../assets/icons/mixes.svg")
          foreground: root.foreground
          fontFamily: root.fontFamily
          onTriggered: {
            root.trackRadioRequested()
            root.closeRequested()
          }
        }

        // 7. Go to Album
        MenuActionItem {
          slot: 6
          hasCursor: root.cursorSlot === 6
          label: "Go to album"
          iconSource: Qt.resolvedUrl("../../assets/icons/albums.svg")
          foreground: root.foreground
          fontFamily: root.fontFamily
          onTriggered: {
            root.goToAlbumRequested()
            root.closeRequested()
          }
        }

        // 8. Go to Artist
        MenuActionItem {
          slot: 7
          hasCursor: root.cursorSlot === 7
          label: "Go to artist"
          iconSource: Qt.resolvedUrl("../../assets/icons/artists.svg")
          foreground: root.foreground
          fontFamily: root.fontFamily
          onTriggered: {
            root.goToArtistRequested()
            root.closeRequested()
          }
        }
      }

      // Bottom breathing room, matching the other bottom sheets
      Item {
        width: parent.width
        height: 8
      }
    }
  }

  // Component definition for each menu item
  component MenuActionItem: Rectangle {
    id: actionItem
    property string label: ""
    property string iconSource: ""
    property color foreground: "#ffffff"
    property string fontFamily: ""
    property int slot: -1
    property bool hasCursor: false
    signal triggered()

    width: parent.width
    height: 42
    color: hasCursor
      ? Style.hoverFillFor(foreground, Color.accent)
      : (itemMa.containsMouse && root.cursorSlot < 0 ? Qt.rgba(foreground.r, foreground.g, foreground.b, 0.08) : "transparent")

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: 16
      anchors.rightMargin: 16
      spacing: 16

      SvgIcon {
        size: 18
        color: foreground
        source: iconSource
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: label
        font.family: fontFamily
        font.pixelSize: 13
        font.weight: Font.Normal
        color: foreground
      }
    }

    // Full-bleed row: mark the cursor with rules above and below instead of a
    // closed border, whose sides would run down the panel's own edges.
    CursorRules {
      anchors.fill: parent
      shown: actionItem.hasCursor
    }

    MouseArea {
      id: itemMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.rowHovered(actionItem.slot)
      onExited: root.rowUnhovered(actionItem.slot)
      onClicked: parent.triggered()
    }
  }
}
