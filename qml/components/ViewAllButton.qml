import QtQuick
import QtQuick.Layouts
import qs.Commons

// Text link that sits at the right of a section heading and opens the
// section's full page (artist top tracks, albums or singles). Plain text
// rather than a pill; it underlines and brightens on hover.
Item {
  id: root

  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  // The section can call its full page something other than "View all"
  // (e.g. "View more"); the weight stays the link's own.
  property string text: "View all"

  signal clicked()

  implicitWidth: label.implicitWidth
  implicitHeight: label.implicitHeight
  Layout.alignment: Qt.AlignVCenter

  Text {
    id: label
    textFormat: Text.PlainText
    anchors.centerIn: parent
    text: root.text
    color: root.foreground
    opacity: buttonMa.containsMouse ? 1.0 : 0.75
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption || 11
    font.weight: Font.DemiBold
    font.underline: buttonMa.containsMouse
  }

  MouseArea {
    id: buttonMa
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
