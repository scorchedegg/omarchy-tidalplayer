import QtQuick
import "../lib/Design.js" as Design

// The mouse-hover fill for a row or card.
//
// It paints instantly under the pointer and fades out over `Design.fast` when
// the pointer leaves, so sweeping down a list leaves a short trail of decaying
// bands. Keyboard state never animates: `instant` clears the trail at once,
// before the keyboard cursor's own fill appears.
Rectangle {
  id: root

  property color tint: "#ffffff"
  property real strength: 0.08
  property bool active: false
  property bool instant: false

  color: root.tint
  opacity: 0
  visible: opacity > 0

  NumberAnimation {
    id: fade
    target: root
    property: "opacity"
    to: 0
    duration: Design.fast
    easing.type: Easing.OutCubic
  }

  onActiveChanged: {
    if (active) {
      fade.stop()
      opacity = strength
    } else if (instant) {
      fade.stop()
      opacity = 0
    } else {
      fade.start()
    }
  }

  onInstantChanged: {
    if (instant) {
      fade.stop()
      opacity = 0
    } else if (active) {
      // Returning from keyboard to mouse with the pointer already on the row.
      fade.stop()
      opacity = strength
    }
  }
}
