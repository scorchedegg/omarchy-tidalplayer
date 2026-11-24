import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "../lib/Design.js" as Design
import "../lib/Wheel.js" as Wheel

// The now-playing footer's volume control.
//
// Collapsed it is the same 36 px circle as the queue and more buttons, with a
// speaker glyph that changes with the level. Hovering it (or dragging the bar)
// grows it leftwards into a slider: the speaker stays put at the right end,
// the bar arrives from the left and the "Playing from" column makes room. The
// glyph is clicked to mute and middle-clicked to return to 100 %, the bar is
// clicked or dragged to set a level, and a wheel over either nudges it like the
// bar widget does.
Rectangle {
  id: root

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  // The rail is drawn against the active output's ceiling: the local player
  // allows 150 %, a cast receiver stops at 100 %. Service owns the value so
  // the bar toast and the wheel agree with this control.
  property real maxVolume: (root.svc && root.svc.maxVolume !== undefined) ? root.svc.maxVolume : 1.5
  // Width of the expanded pill, chosen by the view so its left edge lands on
  // the panel's halfway mark.
  property real expandedWidth: collapsedWidth

  readonly property real collapsedWidth: 36
  readonly property int iconSize: 18
  readonly property real volume: (root.svc && root.svc.volume !== undefined) ? root.svc.volume : 1.0
  readonly property real fraction: Math.max(0, Math.min(1, root.volume / root.maxVolume))
  readonly property bool muted: root.volume <= 0.001
  // Local playback runs to 150 %, so a fill that has climbed past unity is
  // real headroom and worth calling out: the bar and its knob turn the
  // palette's red there, while the rail keeps its neutral wash so the end of
  // the fill stays readable. The level is quantised to whole percent, so 1.0
  // itself is still an ordinary level.
  readonly property bool overUnity: root.volume > 1.001
  readonly property color fillColor: root.overUnity ? Color.urgent : root.foreground

  // Hover and drag both hold the pill open; dragging keeps it from folding
  // away when the pointer leaves the bar during a fast scrub.
  property bool dragging: false
  readonly property bool hovered: pillHover.hovered
  readonly property bool expanded: root.hovered || root.dragging

  // The width is animated on a plain property rather than through a Behavior
  // on Layout.preferredWidth: the layout needs a new preferred width every
  // frame, and an animated binding gives it one.
  property real expandProgress: root.expanded ? 1 : 0
  Behavior on expandProgress {
    NumberAnimation { duration: Design.base; easing.type: Easing.OutCubic }
  }

  implicitWidth: Math.round(root.collapsedWidth + root.expandProgress
    * Math.max(0, root.expandedWidth - root.collapsedWidth))
  implicitHeight: root.collapsedWidth
  Layout.preferredWidth: root.implicitWidth

  radius: height / 2
  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
    root.hovered ? 0.16 : 0.08)

  HoverHandler {
    id: pillHover
  }

  // Five glyph steps, cut at the absolute 25 / 50 / 75 % marks: the level
  // itself, not the rail, so 100 % is always the top step even while the
  // local ceiling runs to 150 %. Mute is a true zero only — every audible
  // level, however low, gets a wave.
  readonly property int level: root.muted ? 0
    : (root.volume < 0.25 ? 1
    : (root.volume < 0.5 ? 2
    : (root.volume < 0.75 ? 3 : 4)))

  // The glyph is layered — cone, inner wave, outer wave — so one wave can be
  // dimmed or tinted on its own. Past unity the headroom turns the palette's
  // red, the same Color.urgent as the rail's fill: the inner wave above
  // 100 %, both waves above 125 %.
  readonly property real glyphOpacity: 0.9
  readonly property real dimWaveOpacity: root.glyphOpacity * 0.38
  readonly property color smallWaveColor: root.volume > 1.001 ? Color.urgent : root.foreground
  readonly property color largeWaveColor: root.volume > 1.25 ? Color.urgent : root.foreground

  function setVolumeFromX(px) {
    if (!root.svc || rail.width <= 0) return
    var f = Math.max(0, Math.min(1, px / rail.width))
    // While the pointer is down the level is a preview: the bar follows it
    // directly, and the single commit on release tells the daemon.
    if (typeof root.svc.previewVolume === "function") {
      root.svc.previewVolume(f * root.maxVolume)
    } else {
      root.svc.setVolume(f * root.maxVolume)
    }
  }

  function endDrag() {
    if (!root.dragging) return
    root.dragging = false
    if (root.svc && typeof root.svc.endVolumeScrub === "function") root.svc.endVolumeScrub()
  }

  Component.onDestruction: {
    if (root.dragging) root.endDrag()
  }

  // A wheel notch walks the same 5 % boundary grid as the bar widget and the
  // keyboard. Wheel.js sums a high-resolution wheel's burst into whole
  // notches; the timer flushes a partial click as one step.
  property var wheelNotchState: ({ accumulator: 0 })

  function nudge(notches) {
    if (!root.svc || notches === 0) return
    root.svc.stepVolume(notches)
  }

  function handleWheel(event) {
    var delta = event.angleDelta.y
    if (delta === 0) return
    event.accepted = true
    var notches = Wheel.accumulate(root.wheelNotchState, delta)
    if (notches !== 0) {
      wheelNotchTimer.stop()
      root.nudge(notches)
    } else {
      wheelNotchTimer.restart()
    }
  }

  WheelHandler {
    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: function(event) {
      root.handleWheel(event)
    }
  }

  Timer {
    id: wheelNotchTimer
    interval: 180
    onTriggered: root.nudge(Wheel.leftover(root.wheelNotchState, 1))
  }

  // Speaker: the pill's click target and the only part that is visible while
  // collapsed. Right-anchored so it does not move when the bar grows, and
  // declared before the slider because the slider's width reads its x (a
  // binding to an id declared later evaluates once while the id is missing).
  Item {
    id: iconZone
    z: 1
    width: root.collapsedWidth
    height: root.collapsedWidth
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter

    // Three layers sharing one 24 px box: the cone (with the X when muted),
    // then each wave separately so it can dim or turn red on its own.
    SvgIcon {
      anchors.centerIn: parent
      size: root.iconSize
      color: root.foreground
      opacity: root.glyphOpacity
      source: root.muted
        ? Qt.resolvedUrl("../../assets/icons/volume-mute.svg")
        : Qt.resolvedUrl("../../assets/icons/volume-body.svg")
    }

    SvgIcon {
      anchors.centerIn: parent
      size: root.iconSize
      visible: !root.muted
      color: root.smallWaveColor
      opacity: root.level === 1 ? root.dimWaveOpacity : root.glyphOpacity
      source: Qt.resolvedUrl("../../assets/icons/volume-wave-small.svg")
    }

    SvgIcon {
      anchors.centerIn: parent
      size: root.iconSize
      visible: !root.muted && root.level >= 3
      color: root.largeWaveColor
      opacity: root.level === 3 ? root.dimWaveOpacity : root.glyphOpacity
      source: Qt.resolvedUrl("../../assets/icons/volume-wave-large.svg")
    }

    MouseArea {
      id: speakerMa
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        if (!root.svc) return
        // Middle click drops the local 150 % headroom back to the reference
        // level; while casting 100 % is already the ceiling, so it is a no-op
        // there rather than a write past what the receiver accepts.
        if (mouse.button === Qt.MiddleButton) {
          root.svc.setVolume(1.0)
          return
        }
        if (typeof root.svc.toggleMute === "function") root.svc.toggleMute()
      }
    }

    ButtonToolTip {
      host: speakerMa
      text: root.muted ? "Unmute" : "Mute"
      fontFamily: root.fontFamily
    }
  }

  // Slider: the rail is inset from the pill's left edge and stops clear of the
  // speaker's 36 px hit area. Its width follows the pill, so it is zero while
  // collapsed and needs no separate show/hide. Nothing here eases its own
  // position: the rail grows with the pill and the knob follows the pointer,
  // so a drag is 1:1 instead of chasing a moving target.
  Item {
    id: slider
    x: 14
    width: Math.max(0, iconZone.x - 4 - x)
    height: root.height

    Rectangle {
      id: rail
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      height: 4
      radius: height / 2
      color: Util.alpha(root.foreground, 0.22)

      Rectangle {
        id: fill
        anchors.left: rail.left
        anchors.verticalCenter: rail.verticalCenter
        width: rail.width * root.fraction
        height: rail.height
        radius: rail.radius
        color: root.fillColor
      }
    }

    Rectangle {
      id: knob
      // Even size and an explicit y: a 9 px knob centred by anchors rounds to
      // a half pixel inside the 36 px pill, which reads as sitting high.
      width: 10
      height: 10
      radius: width / 2
      y: Math.round((root.height - height) / 2)
      // The knob's edge travels the rail plus 1 px at each end instead of
      // being clamped inside it: at mute its left edge sits 13 px from the
      // pill's edge — the same inset it has above and below — and at the top
      // its right edge reaches 1 px past the rail's end. No clamping means
      // every 5 % step moves it; the clamped mapping held still for the first
      // and last ~7 %, so the wheel's end notches looked dead.
      x: -1 + (rail.width - width + 2) * root.fraction
      color: root.fillColor
      // On the way in and out the rail is narrower than the knob, and the knob
      // would hang outside the collapsing pill's edge.
      visible: rail.width > width
      scale: (sliderMa.containsMouse || root.dragging) ? 1.2 : 1.0
    }

    MouseArea {
      id: sliderMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      preventStealing: true

      onPressed: function(mouse) {
        if (!root.svc) return
        if (typeof root.svc.beginVolumeScrub === "function") root.svc.beginVolumeScrub()
        root.dragging = true
        root.setVolumeFromX(mouse.x)
      }
      onPositionChanged: function(mouse) {
        if (root.dragging) root.setVolumeFromX(mouse.x)
      }
      onReleased: root.endDrag()
      onCanceled: root.endDrag()
    }
  }
}
