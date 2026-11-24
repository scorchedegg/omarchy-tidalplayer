import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Artist biography sheet, opened from the artist context menu: rounded top
// corners, slides up from the bottom, scrollable body. Esc and right-click
// close it.
Item {
  id: root

  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  property bool open: false
  property string title: ""
  property string text: ""

  signal closeRequested()

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

  // Scrolling over the open sheet must not reach the page underneath it; the
  // bio's own Flickable sits above this and keeps the wheel.
  WheelShield {}

  // Backdrop that dismisses the sheet on an outside click. Only a click outside
  // the sheet closes it: the sheet swallows clicks on itself, so blank space
  // inside is not a dismiss target.
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

  onOpenChanged: {
    if (root.open && bioFlick) bioFlick.contentY = 0
  }

  // The body is sized from the text and the panel height, so the sheet's own
  // height can follow the column without a binding loop.
  readonly property real bodyMax: Math.max(60, root.height * 0.72 - 120)
  readonly property real bodyHeight: Math.min(bioText.implicitHeight, bodyMax)

  // Keyboard scrolling, routed from MiniPlayer while the sheet is open.
  function scrollBy(delta) {
    if (!bioFlick) return
    var maxY = Math.max(0, bioFlick.contentHeight - bioFlick.height)
    bioFlick.contentY = Math.max(0, Math.min(maxY, bioFlick.contentY + delta * 40))
  }

  function pageBy(direction) {
    if (!bioFlick) return
    var maxY = Math.max(0, bioFlick.contentHeight - bioFlick.height)
    bioFlick.contentY = Math.max(0, Math.min(maxY, bioFlick.contentY + direction * bioFlick.height * 0.8))
  }

  function homeEnd(toEnd) {
    if (!bioFlick) return
    bioFlick.contentY = toEnd ? Math.max(0, bioFlick.contentHeight - bioFlick.height) : 0
  }

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
    // backdrop. Declared before the content, so interactive items sit on top.
    // A right click anywhere on the sheet dismisses it: the content takes the
    // left button only, so a right click over it falls through here.
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
        text: "Biography"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: 15
        font.weight: Font.Bold
        topPadding: 4
      }

      FadeText {
        textFormat: Text.PlainText
        width: parent.width - 32
        anchors.horizontalCenter: parent.horizontalCenter
        visible: text !== ""
        text: root.title
        color: root.foreground
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: 12
        maximumLineCount: 1
        bottomPadding: 4
      }

      Flickable {
        id: bioFlick
        width: parent.width
        height: root.bodyHeight
        contentWidth: width
        contentHeight: bioText.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        Text {
          id: bioText
          width: parent.width - 32
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          text: root.text
          color: root.foreground
          opacity: 0.88
          font.family: root.fontFamily
          font.pixelSize: 13
          lineHeight: 1.3
          wrapMode: Text.Wrap
        }

        SmoothScrollHandler {
          stepSize: 40
          animationDuration: 180
        }
      }

      Item {
        width: parent.width
        height: 10
      }
    }
  }
}
