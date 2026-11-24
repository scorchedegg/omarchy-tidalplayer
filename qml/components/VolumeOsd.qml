import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Volume toast for wheel changes over the bar widget. Omarchy's own OSD
// answers the system sink and can only draw Nerd Font glyphs, so the player
// shows its own card: the TIDAL mark, the level and its percentage.
//
// The card reuses the stock OSD's metrics so it reads as part of the shell,
// and its surface is a fullscreen, input-transparent overlay on this bar
// instance's own output. An empty mask keeps every click and wheel event on
// whatever is below it.
Item {
  id: root

  // The player's level. Locally it runs to 1.5 (150 %); a cast receiver stops
  // at 1.0. The bar is drawn against `maxVolume`, so a full bar means the
  // active output's ceiling and the readout says which.
  property real volume: 1.0
  property real maxVolume: 1.5

  // The output this bar instance lives on, so the toast answers the monitor
  // whose widget was scrolled rather than whichever one has focus.
  property var targetScreen: null

  property bool opened: false

  readonly property string percentLabel: Math.round(root.volume * 100) + "%"
  readonly property real fill: Math.max(0, Math.min(1, root.volume / root.maxVolume))
  // Local playback reaches 150 %, so a level past unity is real headroom and
  // the fill reports it in the palette's red, the same alarm the footer's bar
  // uses. The rail and the percentage keep their neutral colours, and while
  // casting 100 % is the ceiling, so the state cannot occur.
  readonly property bool overUnity: root.volume > 1.001

  readonly property int pad: Style.space(16)
  readonly property int gap: Style.space(16)
  readonly property int barWidth: Style.space(142)
  readonly property int logoSize: Style.font.displayLarge
  readonly property int valueWidth: Math.ceil(valueMetrics.advanceWidth)
  readonly property int contentWidth: root.logoSize + root.gap + root.barWidth + root.gap + root.valueWidth

  function show(value) {
    var next = Number(value)
    if (isFinite(next)) root.volume = Math.max(0, Math.min(root.maxVolume, next))
    root.opened = true
    hideTimer.restart()
  }

  // One timer for the whole toast: the next notch restarts it, so the card
  // stays up while the wheel is moving and leaves 1.2 s after the last step.
  Timer {
    id: hideTimer
    interval: 1200
    onTriggered: root.opened = false
  }

  // Measured against the widest readout so the digits do not jitter between
  // 9 % and 100 %.
  TextMetrics {
    id: valueMetrics
    font.family: Style.font.family
    font.bold: true
    font.pixelSize: Style.font.title
    text: "100%"
  }

  PanelWindow {
    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "scorchedegg-tidalplayer-osd"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    // Visual-only surface: an empty input region lets every click and wheel
    // pass through to the desktop below.
    mask: Region {}

    BorderSurface {
      id: card
      width: card.borderLeft + root.pad + root.contentWidth + root.pad + card.borderRight
      height: card.borderTop + root.pad + root.logoSize + root.pad + card.borderBottom
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(67)
      color: Util.alpha(Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      opacity: root.opened ? 1 : 0

      Row {
        anchors.fill: parent
        anchors.topMargin: card.borderTop + root.pad
        anchors.rightMargin: card.borderRight + root.pad
        anchors.bottomMargin: card.borderBottom + root.pad
        anchors.leftMargin: card.borderLeft + root.pad
        spacing: root.gap

        Item {
          width: root.logoSize
          height: parent.height

          TidalLogo {
            anchors.verticalCenter: parent.verticalCenter
            size: root.logoSize
            color: Color.popups.text
          }
        }

        Rectangle {
          width: root.barWidth
          height: Math.max(Style.space(6), Style.spacing.sm)
          anchors.verticalCenter: parent.verticalCenter
          color: Util.alpha(Color.popups.text, 0.45)

          Rectangle {
            height: parent.height
            width: parent.width * root.fill
            color: root.overUnity ? Color.urgent : Color.accent

            // Only a change while the toast stays up glides; a fresh open
            // starts at the new level instead of sliding from the old one.
            Behavior on width {
              enabled: root.opened
              NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: root.valueWidth
          horizontalAlignment: Text.AlignRight
          anchors.verticalCenter: parent.verticalCenter
          text: root.percentLabel
          font: valueMetrics.font
          color: Color.popups.text
        }
      }
    }
  }
}
