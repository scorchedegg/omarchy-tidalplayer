import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Entity action menu: a bottom sheet with rounded top corners that slides up
// from the bottom. Items are plain objects:
//   { action, label, icon, destructive, enabled }
// `header` is an optional preview row:
//   { artUrl, title, subtitle, roundArt }
//
// Esc and right-click (anywhere, backdrop or sheet) close the menu; there is
// deliberately no close row.
Item {
  id: root

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  property bool open: false
  property var items: []
  property var header: null
  property color destructiveColor: Color.urgent

  signal actionTriggered(string action)
  signal closeRequested()

  // Keyboard cursor over the enabled rows.
  property int cursorIndex: -1
  // Row under the pointer, so a first arrow key can continue from where the
  // eye already is instead of jumping to the top of the menu — the same rule
  // the list views follow.
  property int hoveredIndex: -1

  function rowHovered(index) { root.hoveredIndex = index }
  function rowUnhovered(index) { if (root.hoveredIndex === index) root.hoveredIndex = -1 }

  readonly property var enabledIndices: {
    var out = []
    for (var i = 0; i < root.items.length; i++) {
      if (root.items[i] && root.items[i].enabled !== false) out.push(i)
    }
    return out
  }

  onOpenChanged: {
    if (root.open) {
      root.cursorIndex = -1
      root.hoveredIndex = -1
    } else {
      root.hoveredIndex = -1
    }
  }

  function moveCursor(delta) {
    var indices = root.enabledIndices
    if (delta === 0 || indices.length === 0) return
    var pos = indices.indexOf(root.cursorIndex)
    if (pos < 0) {
      var hovered = indices.indexOf(root.hoveredIndex)
      if (hovered >= 0) {
        root.cursorIndex = indices[Math.max(0, Math.min(indices.length - 1, hovered + delta))]
        return
      }
      root.cursorIndex = delta > 0 ? indices[0] : indices[indices.length - 1]
      return
    }
    root.cursorIndex = indices[Math.max(0, Math.min(indices.length - 1, pos + delta))]
  }

  function activateCursor() {
    if (root.cursorIndex < 0) return
    var item = root.items[root.cursorIndex]
    if (!item || item.enabled === false) return
    root.actionTriggered(item.action || "")
    root.closeRequested()
  }

  anchors.fill: parent
  // Clips the sheet's hidden bottom-corner overhang so it never pokes past
  // the panel while sliding.
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
    onMoved: if (root.cursorIndex >= 0) root.cursorIndex = -1
  }

  // Scrolling over the open sheet must not reach the page (or the collapsed
  // player's seek bar) underneath it.
  WheelShield {}

  // Backdrop. Only a click outside the sheet closes it: the sheet swallows
  // clicks on itself, so blank space inside is not a dismiss target.
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

  // Bottom sheet. A uniform radius plus a negative bottom margin hides the
  // bottom pair of corners off-screen, leaving the top two rounded.
  Rectangle {
    id: sheet
    readonly property real corner: 14
    width: parent.width
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.bottomMargin: -corner
    height: Math.min(parent.height - 20, sheetCol.implicitHeight) + corner
    radius: corner
    color: Color.popups.background
    clip: true

    // Swallows clicks on the sheet so blank space inside it does not reach the
    // backdrop. Declared before the rows, so their own MouseAreas sit on top.
    // A right click anywhere on the sheet dismisses it: the rows and buttons
    // take the left button only, so a right click over one falls through here.
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

      // Preview row (art, title, subtitle)
      RowLayout {
        width: parent.width - 32
        height: 64
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 12
        visible: root.header !== null && root.header !== undefined

        Rectangle {
          id: headerArt
          Layout.preferredWidth: 48
          Layout.preferredHeight: 48
          radius: (root.header && root.header.roundArt) ? 24 : 2
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
          border.width: 1
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

          RoundedImage {
            id: menuArt
            anchors.fill: parent
            radius: headerArt.radius
            borderWidth: 1
            borderColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
            source: root.header ? String(root.header.artUrl || "") : ""
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
            text: root.header ? String(root.header.title || "") : ""
            font.family: root.fontFamily
            font.pixelSize: 14
            font.weight: Font.DemiBold
            color: root.foreground
            maximumLineCount: 1
          }

          FadeText {
            textFormat: Text.PlainText
            width: parent.width
            visible: text !== ""
            text: root.header ? String(root.header.subtitle || "") : ""
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

      // Breathing room below the preview, balancing the gap above the first
      // action row.
      Item {
        width: parent.width
        height: 4
        visible: root.header !== null && root.header !== undefined
      }

      // Divider between the preview and the actions
      Rectangle {
        width: parent.width
        height: (root.header !== null && root.header !== undefined) ? 1 : 0
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
      }

      // Space above the first action, matching the padding after the last one.
      Item {
        width: parent.width
        height: (root.header !== null && root.header !== undefined) ? 4 : 0
      }

      // Actions
      Repeater {
        model: root.items

        Rectangle {
          id: itemRow
          required property var modelData
          required property int index

          readonly property color itemColor: modelData.destructive ? root.destructiveColor : root.foreground
          readonly property bool itemEnabled: modelData.enabled !== false
          readonly property bool hasCursor: root.cursorIndex === itemRow.index

          width: sheetCol.width
          height: 46
          color: itemRow.hasCursor
            ? Style.hoverFillFor(root.foreground, Color.accent)
            : (itemMa.containsMouse && itemEnabled && root.cursorIndex < 0
              ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
              : "transparent")
          opacity: itemEnabled ? 1.0 : 0.4

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            spacing: 16

            SvgIcon {
              size: 18
              color: itemRow.itemColor
              source: modelData.icon || ""
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: modelData.label || ""
              font.family: root.fontFamily
              font.pixelSize: 13
              color: itemRow.itemColor
              elide: Text.ElideRight
            }
          }

          // Full-bleed row: rules above and below mark the cursor without a
          // side border on the panel edge.
          CursorRules {
            anchors.fill: parent
            shown: itemRow.hasCursor
          }

          MouseArea {
            id: itemMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: itemRow.itemEnabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            enabled: itemRow.itemEnabled
            onEntered: root.rowHovered(itemRow.index)
            onExited: root.rowUnhovered(itemRow.index)
            onClicked: {
              root.actionTriggered(itemRow.modelData.action || "")
              root.closeRequested()
            }
          }
        }
      }

      Item {
        width: parent.width
        height: 8
      }
    }
  }
}
