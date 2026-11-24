import QtQuick
import qs.Commons
import "../lib/Format.js" as Format
import "../lib/Wheel.js" as Wheel

// Full-width seekbar matching TIDAL mobile screenshots:
// Full width seek rail on top, with elapsed time on left,
// audio quality centered in between, and total time on right underneath.
Item {
  id: root

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  property int railHeight: 4
  property real knobSize: 12

  property bool scrubbing: false
  property real scrubFraction: 0

  readonly property real position: scrubbing
    ? scrubFraction * length
    : (svc ? svc.position : 0)
  readonly property real length: svc ? svc.length : 0
  readonly property real progress: length > 0
    ? (scrubbing ? scrubFraction : Math.max(0, Math.min(1, position / length))) : 0

  readonly property string qualityText: {
    var badge = (svc && svc.formatBadge) ? svc.formatBadge : ""
    if (!badge) return ""
    return badge.toUpperCase()
      .replace(/\s*\/\s*/g, " ")
      .replace(/\s*KHZ/g, "KHZ")
      .replace(/-?BIT/g, "-BIT")
  }

  implicitHeight: 38
  width: parent.width

  function fractionToSeconds(fraction) {
    return Math.max(0, Math.min(1, fraction)) * root.length
  }

  function previewFraction(fraction) {
    if (!root.svc || root.length <= 0) return
    var secs = root.fractionToSeconds(fraction)
    if (typeof root.svc.previewSeek === "function") {
      root.svc.previewSeek(secs)
    } else {
      root.svc.position = secs
    }
  }

  function commitFraction(fraction) {
    if (!root.svc || root.length <= 0) return
    var secs = root.fractionToSeconds(fraction)
    if (typeof root.svc.commitSeek === "function") {
      root.svc.commitSeek(secs)
    } else {
      root.svc.seek(secs)
    }
  }

  // A plain wheel over the bar seeks ±10 s per notch, the same step Ctrl+wheel
  // takes over the bar widget. Wheel.js sums a high-resolution wheel's burst
  // into whole notches; the timer flushes a device that reports a partial click.
  property real seekStepSeconds: 10
  property var wheelNotchState: ({ accumulator: 0 })

  function seekBySeconds(seconds) {
    if (!root.svc || typeof root.svc.seekBy !== "function") return
    if (seconds === 0) return
    root.svc.seekBy(seconds)
  }

  function updateScrub(mouseX) {
    var w = seekTrack.width
    if (w <= 0) return
    var f = Math.max(0, Math.min(1, mouseX / w))
    root.scrubFraction = f
    root.previewFraction(f)
  }

  Component.onDestruction: {
    if (root.scrubbing && root.svc && typeof root.svc.endScrub === "function") {
      root.svc.endScrub()
    }
  }

  WheelHandler {
    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: function(event) {
      var delta = event.angleDelta.y
      if (delta === 0) return
      event.accepted = true
      var notches = Wheel.accumulate(root.wheelNotchState, delta)
      if (notches !== 0) {
        wheelNotchTimer.stop()
        root.seekBySeconds(notches * root.seekStepSeconds)
      } else {
        wheelNotchTimer.restart()
      }
    }
  }

  Timer {
    id: wheelNotchTimer
    interval: 180
    onTriggered: root.seekBySeconds(Wheel.leftover(root.wheelNotchState, root.seekStepSeconds))
  }

  // 1. Full-Width Interactive Track Rail
  Item {
    id: seekTrack
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    height: 18

    // Background Rail (Subtle semi-transparent line)
    Rectangle {
      id: rail
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      height: root.railHeight
      radius: height / 2
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22)

      // Active Filled Rail
      Rectangle {
        id: fill
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: parent.width * root.progress
        radius: rail.radius
        color: root.foreground

        Behavior on width {
          enabled: !root.scrubbing
          NumberAnimation { duration: 100; easing.type: Easing.OutCubic }
        }
      }
    }

    // Circular Playhead Thumb
    Rectangle {
      id: knob
      width: root.knobSize
      height: root.knobSize
      radius: width / 2
      color: root.foreground
      anchors.verticalCenter: rail.verticalCenter
      x: Math.max(0, Math.min(rail.width - width, rail.width * root.progress - width / 2))
      visible: root.length > 0
      scale: (seekMouse.containsMouse || root.scrubbing) ? 1.25 : 1.0

      Behavior on x {
        enabled: !root.scrubbing
        NumberAnimation { duration: 100; easing.type: Easing.OutCubic }
      }

      Behavior on scale {
        NumberAnimation { duration: 100; easing.type: Easing.OutCubic }
      }
    }

    MouseArea {
      id: seekMouse
      anchors.fill: parent
      anchors.margins: -4
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      preventStealing: true

      onPressed: function(mouse) {
        root.scrubbing = true
        if (root.svc && typeof root.svc.beginScrub === "function") root.svc.beginScrub()
        root.updateScrub(mouse.x + seekMouse.x)
      }
      onPositionChanged: function(mouse) {
        if (root.scrubbing) root.updateScrub(mouse.x + seekMouse.x)
      }
      onReleased: function(mouse) {
        if (!root.scrubbing) return
        root.scrubbing = false
        if (root.svc && typeof root.svc.endScrub === "function") root.svc.endScrub()
        var w = seekTrack.width
        var f = w > 0 ? Math.max(0, Math.min(1, (mouse.x + seekMouse.x) / w)) : root.scrubFraction
        root.commitFraction(f)
      }
      onCanceled: {
        if (root.scrubbing) {
          root.scrubbing = false
          if (root.svc && typeof root.svc.endScrub === "function") root.svc.endScrub()
        }
      }
    }
  }

  // 2. Underneath Row: Elapsed on Left, Audio Quality in Center, Duration on Right
  Item {
    anchors.top: seekTrack.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: 2
    height: 16

    Text {
      textFormat: Text.PlainText
      id: elapsed
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: Format.formatDuration(root.position)
      color: root.foreground
      opacity: 0.65
      font.family: root.fontFamily
      font.pixelSize: 10
    }

    Text {
      textFormat: Text.PlainText
      id: qualityBadge
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      text: root.qualityText
      color: root.foreground
      opacity: 0.65
      font.family: root.fontFamily
      font.pixelSize: 9
      font.weight: Font.Medium
    }

    Text {
      textFormat: Text.PlainText
      id: total
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: Format.formatDuration(root.length)
      color: root.foreground
      opacity: 0.65
      font.family: root.fontFamily
      font.pixelSize: 10
    }
  }
}
