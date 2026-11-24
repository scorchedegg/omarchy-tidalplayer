import QtQuick

// Hands a keyboard-driven list back to the mouse on the first real pointer
// movement. Put one on any surface that also serves a keyboard cursor and clear
// that cursor from `onMoved`, so hover highlighting resumes as soon as the user
// reaches for the pointer.
//
// It watches position changes rather than rows' `containsMouse`: after keyboard
// navigation the pointer is often already resting over a row, and no enter
// event fires when it then moves a pixel, so enter/leave alone would leave the
// row unlit. A move only counts when the point actually changed, so rows
// scrolling under a still pointer do not cancel keyboard mode.
HoverHandler {
  id: root

  signal moved()

  property real lastX: -10000
  property real lastY: -10000

  acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

  function note(x, y) {
    if (Math.abs(x - root.lastX) > 0.5 || Math.abs(y - root.lastY) > 0.5) {
      root.lastX = x
      root.lastY = y
      root.moved()
    }
  }

  // Forget the last point when the pointer leaves, so coming back over the
  // list counts as reaching for it again rather than resuming silently.
  function reset() {
    root.lastX = -10000
    root.lastY = -10000
  }

  onPointChanged: root.note(point.position.x, point.position.y)
  onHoveredChanged: if (!root.hovered) root.reset()
}
