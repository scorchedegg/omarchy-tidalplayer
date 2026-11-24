import QtQuick

Item {
  id: root

  implicitWidth: 12
  implicitHeight: 12

  property bool playing: false
  property color barColor: "#ffffff"

  // Three centered flat-capped bars with staggered starting heights and
  // coprime cycle lengths (1590 / 1830 / 1470 ms; ratios 53:61:49) so each bar
  // moves independently without locking into a loop. Positioning via
  // floating-point `y` (instead of `anchors.centerIn`, which rounds to integer
  // pixels every frame) lets top and bottom glide symmetrically with smooth
  // subpixel antialiasing while keeping the vertical sides razor-sharp.
  readonly property var startLevels: [0.26, 0.86, 0.58]
  readonly property var kf1: [0.90, 0.24, 0.20]
  readonly property var kf2: [0.22, 1.00, 0.92]
  readonly property var kf3: [0.64, 0.30, 0.32]
  readonly property var kf4: [0.26, 0.86, 0.58]
  readonly property var d1: [380, 480, 340]
  readonly property var d2: [450, 430, 410]
  readonly property var d3: [340, 510, 370]
  readonly property var d4: [420, 410, 350]

  Row {
    x: Math.round((parent.width - width) / 2)
    y: 0
    height: Math.floor(root.height)
    spacing: 2

    Repeater {
      model: 3

      delegate: Item {
        id: barSlot
        required property int index
        width: 2
        height: parent.height

        property real level: root.startLevels[index]

        Rectangle {
          width: parent.width
          height: Math.max(2, barSlot.height * barSlot.level)
          y: (parent.height - height) / 2
          radius: 0
          color: root.barColor
          antialiasing: true
        }

        SequentialAnimation on level {
          running: root.playing && root.visible
          loops: Animation.Infinite
          onStopped: if (!root.playing) barSlot.level = root.startLevels[barSlot.index]
          NumberAnimation { to: root.kf1[barSlot.index]; duration: root.d1[barSlot.index]; easing.type: Easing.InOutSine }
          NumberAnimation { to: root.kf2[barSlot.index]; duration: root.d2[barSlot.index]; easing.type: Easing.InOutSine }
          NumberAnimation { to: root.kf3[barSlot.index]; duration: root.d3[barSlot.index]; easing.type: Easing.InOutSine }
          NumberAnimation { to: root.kf4[barSlot.index]; duration: root.d4[barSlot.index]; easing.type: Easing.InOutSine }
        }
      }
    }
  }
}
