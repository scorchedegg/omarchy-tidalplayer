import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Icon-over-label action tile, used in the quick-action row under the
// Play/Shuffle pills on the artist and playlist pages. Fills one slot of its
// parent RowLayout.
Item {
  id: action

  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  property string label: ""
  property string iconSource: ""
  property color iconColor: foreground
  signal triggered()

  Layout.fillWidth: true
  implicitHeight: 52

  Rectangle {
    anchors.fill: parent
    radius: 6
    color: actionMa.containsMouse
      ? Qt.rgba(action.foreground.r, action.foreground.g, action.foreground.b, 0.08)
      : "transparent"
  }

  Column {
    anchors.centerIn: parent
    spacing: 4

    SvgIcon {
      anchors.horizontalCenter: parent.horizontalCenter
      size: 20
      color: action.iconColor
      source: action.iconSource
    }

    Text {
      textFormat: Text.PlainText
      anchors.horizontalCenter: parent.horizontalCenter
      text: action.label
      color: action.iconColor
      font.family: action.fontFamily
      font.pixelSize: 10
      font.weight: Font.DemiBold
    }
  }

  MouseArea {
    id: actionMa
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: action.triggered()
  }
}
