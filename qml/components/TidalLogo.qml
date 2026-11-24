import QtQuick

Item {
  id: root

  property real size: 24
  property color color: "#ffffff"
  property bool pulsing: false
  // `faint` marks a logo standing in for missing artwork: an image
  // placeholder is a watermark on an empty slot, not an icon asking for
  // attention, so it renders at the one placeholder strength every slot
  // shares. Loading spinners and brand marks (bar, header, OSD, login)
  // stay at full strength and never set this.
  property bool faint: false

  implicitWidth: size
  implicitHeight: size
  width: implicitWidth
  height: implicitHeight
  opacity: root.faint ? 0.4 : 1.0

  SvgIcon {
    id: logoIcon
    anchors.fill: parent
    size: root.size
    color: root.color
    source: Qt.resolvedUrl("../../assets/tidal-logo.svg")
  }

  SequentialAnimation on opacity {
    running: root.pulsing && root.visible
    loops: Animation.Infinite
    onStopped: root.opacity = Qt.binding(function() { return root.faint ? 0.4 : 1.0 })

    NumberAnimation {
      from: 1.0
      to: 0.35
      duration: 1000
      easing.type: Easing.InOutQuad
    }

    NumberAnimation {
      from: 0.35
      to: 1.0
      duration: 1000
      easing.type: Easing.InOutQuad
    }
  }
}
