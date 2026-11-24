import QtQuick
import "../lib/Design.js" as Design
import "../lib/Wheel.js" as Wheel

Item {
  id: root
  anchors.fill: parent

  readonly property var flickable: {
    if (parent && typeof parent.contentY !== "undefined") return parent
    if (parent && parent.parent && typeof parent.parent.contentY !== "undefined") return parent.parent
    return null
  }

  // One mouse notch moves the content this far. Qt's own Flickable scrolls
  // `wheelScrollLines * 24` pixels per notch (see QQuickFlickable's wheel
  // handler), so following the same style hint keeps this panel in step with
  // every other application on the system.
  property real stepSize: Qt.styleHints.wheelScrollLines * 24
  property real animationDuration: 150
  property real targetScrollY: -1

  // Queued sub-notch wheel units (see Wheel.js), one per scroll surface.
  property var notchState: ({ accumulator: 0 })

  WheelHandler {
    id: wheel
    parent: root.flickable
    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: function(event) {
      var angle = event.angleDelta.y
      var pixel = event.pixelDelta.y
      if (angle === 0 && pixel === 0) return

      // Continuous scrolling (touchpads) arrives in begin/update/end phases
      // and carries its own pixels: track those 1:1. A mouse wheel click has
      // no phase and carries a whole 120-unit notch. This is the same rule
      // Qt's own Flickable uses to pick a delta; device identity is
      // deliberately not consulted, because seat pointer devices are often
      // mislabelled as touchpads (which sent every click down the pixel path
      // and scrolled a bare 15 px per notch).
      var continuous = event.phase !== undefined && event.phase !== null
        && event.phase !== Qt.NoScrollPhase
      if (!continuous && angle === 0 && pixel !== 0) continuous = true

      if (continuous) {
        root.flushNotch()
        if (root.scrollBy(pixel !== 0 ? pixel : angle, true)) event.accepted = true
        return
      }

      var notches = Wheel.accumulate(root.notchState, angle)
      if (notches !== 0) {
        notchTimer.stop()
        if (root.scrollBy(notches * root.stepSize, false)) event.accepted = true
      } else {
        // A partial notch: applied by the timer once the burst goes quiet.
        notchTimer.restart()
        event.accepted = true
      }
    }
  }

  Timer {
    id: notchTimer
    interval: 180
    onTriggered: root.flushNotch()
  }

  NumberAnimation {
    id: scrollAnimation
    property: "contentY"
    alwaysRunToEnd: false
    duration: root.animationDuration
    easing.type: Easing.OutQuad
    onStopped: root.targetScrollY = -1
  }

  function reset() {
    scrollAnimation.stop()
    root.targetScrollY = -1
    root.notchState.accumulator = 0
    notchTimer.stop()
  }

  // Apply the units still queued for a notch that never completed.
  function flushNotch() {
    notchTimer.stop()
    var delta = Wheel.leftover(root.notchState, root.stepSize)
    if (delta === 0) return false
    return root.scrollBy(delta, false)
  }

  Connections {
    target: root.flickable
    ignoreUnknownSignals: true
    function onMovementStarted() {
      root.reset()
    }
    function onVisibleChanged() {
      if (root.flickable && !root.flickable.visible) {
        root.reset()
      }
    }
  }

  function scrollBy(delta, isPixelDelta) {
    var view = root.flickable
    if (!view) return false
    // A ListView's inline header sits above contentY 0, so its originY is
    // negative by the header height. Scrolling has to reach that origin or a
    // wheel cannot bring a header that scrolled away back into view.
    var minY = Math.min(0, view.originY || 0)
    var maxY = Design.maxScrollY(view.originY, view.contentHeight, view.height)
    if (maxY <= minY) return false

    if (isPixelDelta) {
      root.reset()
      view.contentY = Math.max(minY, Math.min(maxY, view.contentY - delta))
      return true
    }

    var isReversing = false
    if (scrollAnimation.running) {
      var movingDiff = root.targetScrollY - view.contentY
      // delta > 0 is scrolling up (contentY decreasing)
      // delta < 0 is scrolling down (contentY increasing)
      if ((movingDiff > 0 && delta > 0) || (movingDiff < 0 && delta < 0)) {
        isReversing = true
      }
    }

    // Queue notches on top of the animation's target. The old test here was
    // `targetScrollY >= 0`, which broke inside a ListView header: its scroll
    // range starts at a negative originY, so every notch re-based on the
    // current contentY and a fast spin from the top collapsed into one step.
    var base = (scrollAnimation.running && !isReversing)
      ? root.targetScrollY
      : view.contentY

    var newTarget = Math.max(minY, Math.min(maxY, base - delta))

    scrollAnimation.stop()
    root.targetScrollY = newTarget
    scrollAnimation.target = view
    scrollAnimation.from = view.contentY
    scrollAnimation.to = newTarget
    scrollAnimation.duration = root.animationDuration
    scrollAnimation.start()
    return true
  }
}
