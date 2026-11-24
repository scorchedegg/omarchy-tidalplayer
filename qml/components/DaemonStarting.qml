import QtQuick
import qs.Commons

// Shown only when an automatic setup is still running after the reconnect
// grace period. A fresh install passes through here instead of the offline
// page; the offline page is reserved for a start that actually failed.
Item {
  id: root

  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily

  Rectangle {
    anchors.fill: parent
    color: Color.popups.background
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.AllButtons
    onWheel: function(wheel) { wheel.accepted = true }
  }

  Column {
    anchors.centerIn: parent
    width: Math.min(parent.width - Style.space(56), Style.space(320))
    spacing: Style.space(18)

    TidalLogo {
      anchors.horizontalCenter: parent.horizontalCenter
      size: Style.space(54)
      color: root.foreground
      pulsing: true
    }

    Column {
      width: parent.width
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "Starting TIDAL\u2026"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: 20
        font.weight: Font.Bold
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "The background service is starting. This only takes a moment."
        color: root.foreground
        opacity: 0.7
        font.family: root.fontFamily
        font.pixelSize: Style.font.body || 13
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }
    }
  }
}
