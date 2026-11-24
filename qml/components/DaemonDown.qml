import QtQuick
import qs.Commons

// Full-panel offline state. It owns the page while the daemon is settled
// down, so no stale artwork or controls remain clickable behind it.
Item {
  id: root

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily

  readonly property bool busy: root.svc ? root.svc.daemonStarting : false
  readonly property string errorText: root.svc ? root.svc.daemonStartError : ""

  Rectangle {
    anchors.fill: parent
    color: Color.popups.background
  }

  // Swallow clicks and wheel events so the page underneath cannot move or
  // play while it is hidden by the offline state.
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

    DisconnectedIcon {
      anchors.horizontalCenter: parent.horizontalCenter
      size: Style.space(54)
      color: Color.urgent
    }

    Column {
      width: parent.width
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "Daemon offline"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: 20
        font.weight: Font.Bold
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "The background service that streams TIDAL is not running."
        color: root.foreground
        opacity: 0.7
        font.family: root.fontFamily
        font.pixelSize: Style.font.body || 13
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }
    }

    Rectangle {
      id: startButton
      width: parent.width
      height: Style.space(44)
      radius: height / 2
      color: root.busy
        ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)
        : (startArea.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.88) : root.foreground)

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: root.busy ? "Starting daemon\u2026" : "Start daemon"
        color: Color.popups.background
        font.family: root.fontFamily
        font.pixelSize: Style.font.body || 13
        font.weight: Font.Bold
      }

      MouseArea {
        id: startArea
        anchors.fill: parent
        enabled: !root.busy
        hoverEnabled: true
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: if (root.svc) root.svc.startDaemon(true)
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: text !== ""
      text: root.errorText
      color: Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall || 11
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: "Your queue and playhead are saved."
      color: root.foreground
      opacity: 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption || 11
      horizontalAlignment: Text.AlignHCenter
    }
  }
}
