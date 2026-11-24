import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../lib/Cast.js" as Cast

// Cast panel: a device list, with the refresh and stop controls in the header
// and a blocking-firewall notice above the list. Picking a device hands the
// current track to it; the daemon owns discovery and the session.
Item {
  id: root

  property bool alive: true
  Component.onDestruction: root.alive = false

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  property bool open: false

  signal closeRequested()

  anchors.fill: parent
  // Clips the sheet's hidden bottom-corner overhang so it never pokes past
  // the view while sliding.
  clip: true
  visible: opacity > 0.01
  enabled: open
  opacity: open ? 1.0 : 0.0

  Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

  Shortcut {
    sequence: "Escape"
    enabled: root.open
    onActivated: root.closeRequested()
  }

  readonly property var devices: root.svc ? (root.svc.castDevices || []) : []
  readonly property bool loading: root.svc ? root.svc.castLoading : false
  readonly property bool busy: root.svc ? root.svc.castBusy : false
  readonly property bool casting: root.svc ? root.svc.castActive : false
  readonly property bool blocked: root.svc ? root.svc.castStreamBlocked : false
  readonly property string activeId: root.svc ? root.svc.castDeviceId : ""
  // Which device a connect is currently being attempted against, so its row
  // can show "Connecting" instead of claiming it is already casting.
  readonly property string connectingId: root.svc ? root.svc.castConnectingId : ""
  // The device used last, remembered by the daemon across restarts.
  readonly property string lastUsedId: root.svc ? root.svc.castLastUsedId : ""
  // The device whose last connect attempt failed; its row carries a red
  // "Failed" badge instead of a notification.
  readonly property string failedId: root.svc ? root.svc.castFailedId : ""
  // The hint is worth showing only while nothing is casting: the connected
  // device is by definition the last one used.
  readonly property bool lastUsedSlot: !root.casting && root.lastUsedId !== ""
  // The badge itself also stays off mid-connect: the remembered device is
  // about to be superseded, and the row the attempt is running on already
  // says "Connecting...". Its head slot is *not* given up, though — see
  // `availableDevices`.
  readonly property bool showLastUsedBadge: root.lastUsedSlot
    && root.connectingId === ""
  // The active device floats to the top of the reachable list: the list scrolls
  // once there are enough devices, so the one in use must never be scrolled out
  // of view. The last used device takes the next slot for the same reason, but
  // only while it is actually reachable. Everything else stays alphabetical;
  // and because the last used slot survives a connect attempt, clicking a
  // device never re-sorts the rows under the pointer.
  readonly property var availableDevices: {
    var all = root.devices
    if (!all || all.length === 0) return []
    var active = null
    var lastUsed = null
    var rest = []
    for (var i = 0; i < all.length; i++) {
      if (all[i].available === false) continue
      var id = String(all[i].id)
      if (root.casting && root.activeId !== "" && id === root.activeId) active = all[i]
      else if (root.lastUsedSlot && id === root.lastUsedId) lastUsed = all[i]
      else rest.push(all[i])
    }
    var head = []
    if (active) head.push(active)
    if (lastUsed) head.push(lastUsed)
    return head.concat(rest)
  }

  // Devices whose Cast port did not answer. They get their own heading at the
  // bottom, dimmed and inert, so they can never be mistaken for targets.
  readonly property var unavailableDevices: {
    var all = root.devices
    if (!all || all.length === 0) return []
    var out = []
    for (var i = 0; i < all.length; i++)
      if (all[i].available === false) out.push(all[i])
    return out
  }

  // Keyboard order: the firewall action (when present), then the reachable
  // devices. Unavailable rows are inert, so the cursor never lands on one.
  readonly property int deviceOffset: root.blocked ? 1 : 0
  readonly property int itemCount: root.deviceOffset + root.availableDevices.length
  property int cursorIndex: -1

  // The daemon classifies each device from the `ca` capability bits in its
  // mDNS record (the same rule Chrome's Cast dialog uses): video out is a
  // display, the multizone bit is a speaker group, audio out alone is a
  // speaker. A device that advertises no capabilities keeps the generic Cast
  // glyph instead of being guessed at. The active device's class also drives
  // the header's Cast button, so both read it from `Cast.js`.
  function deviceIcon(kind) {
    return Cast.iconForKind(kind)
  }

  function ensureCursorVisible() {
    if (!deviceFlick || root.cursorIndex < root.deviceOffset) return
    var idx = root.cursorIndex - root.deviceOffset
    var headerH = root.availableDevices.length > 0 ? 26 : 0
    var rowTop = headerH + idx * 52
    var rowBottom = rowTop + 52
    if (rowTop < deviceFlick.contentY) deviceFlick.contentY = rowTop
    else if (rowBottom > deviceFlick.contentY + deviceFlick.height) {
      deviceFlick.contentY = Math.max(0, rowBottom - deviceFlick.height)
    }
  }

  function moveCursor(delta) {
    if (root.busy || delta === 0 || root.itemCount === 0) return
    if (root.cursorIndex < 0) {
      root.cursorIndex = delta > 0 ? 0 : root.itemCount - 1
      root.ensureCursorVisible()
      return
    }
    root.cursorIndex = Math.max(0, Math.min(root.itemCount - 1, root.cursorIndex + delta))
    root.ensureCursorVisible()
  }

  function activateCursor() {
    if (root.busy || root.cursorIndex < 0) return
    if (root.blocked && root.cursorIndex === 0) {
      root.allowFirewall()
      return
    }
    var device = root.availableDevices[root.cursorIndex - root.deviceOffset]
    if (device) root.pick(device)
  }

  function pick(device) {
    if (!device || root.busy || !root.svc) return
    // Unavailable rows are inert: wait for the probe to see the device again
    // rather than firing a connect that can only time out.
    if (device.available === false) return
    // Re-picking the active device just closes the sheet.
    if (root.casting && String(device.id) === root.activeId) {
      root.closeRequested()
      return
    }
    root.svc.connectCast(device.id, function(err) {
      if (!root || !root.alive || !root.svc) return
      // A failure is reported on the row (red "Failed" badge); only a success
      // closes the sheet, so the badge stays visible.
      if (!err) root.closeRequested()
    })
  }

  function stopCasting() {
    if (!root.svc || root.busy) return
    root.svc.disconnectCast(function(err) {
      if (!root || !root.alive || !root.svc) return
      if (err) root.svc.notify("Could not stop casting")
      else root.closeRequested()
    })
  }

  function refresh() {
    if (root.svc) root.svc.refreshCastDevices(true)
  }

  // The daemon can serve the stream, but the receiver never reached it: an
  // inbound firewall rule is missing. Run the CLI in Omarchy's floating
  // terminal so the sudo prompt is visible.
  function allowFirewall() {
    if (!root.svc) return
    var dir = String(root.svc.pluginDir || "")
    var cli = dir !== "" ? (dir + "/bin/omarchy-tidalplayer") : "omarchy-tidalplayer"
    allowProcess.command = [
      "omarchy-launch-floating-terminal-with-presentation",
      Util.shellQuote(cli) + " cast allow"
    ]
    allowProcess.running = true
    root.svc.notify("Allow casting in the terminal, then tap the device again")
  }

  onOpenChanged: {
    if (root.open) root.cursorIndex = -1
    else if (root.svc) root.svc.clearCastFailure()
  }

  // The list reorders as the cast state changes (a device becoming active or
  // remembered floats to the top) and as devices drop out of the reachable
  // group, so an index from the old order would point at a different device.
  // Drop the cursor and let the next arrow key reseat it.
  onAvailableDevicesChanged: root.cursorIndex = -1

  PointerHandoff {
    onMoved: if (root.cursorIndex >= 0) root.cursorIndex = -1
  }

  // Scrolling over the open sheet must not reach the page (or the collapsed
  // player's seek bar) underneath it.
  WheelShield {}

  // Backdrop that dismisses the sheet. Only a click outside the sheet closes
  // it: the sheet swallows clicks on itself so blank space inside does not
  // dismiss it. Accepting the right button here keeps a right-click outside
  // working as a dismiss too.
  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.65)

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      // Taking hover as well as clicks keeps the UI behind the scrim from
      // lighting up under the pointer: hover goes to the topmost item that
      // accepts it, so every row underneath stays unlit while the sheet is open.
      hoverEnabled: true
      onClicked: root.closeRequested()
    }
  }

  Rectangle {
    id: sheet
    readonly property real corner: 14
    width: parent.width
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: -corner
    height: Math.min(parent.height - 20, sheetCol.implicitHeight) + corner
    color: Color.popups.background
    radius: corner
    clip: true

    // Blank space inside the sheet is not a left-click dismiss target.
    // Declared before the content, so row and button MouseAreas (added later,
    // thus on top) still take their own clicks first. A right click anywhere
    // on the sheet dismisses it: the rows and buttons take the left button
    // only, so a right click over one falls through here.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) root.closeRequested()
      }
    }

    // Anchors own `y`, so the slide-up is a translate offset instead.
    transform: Translate {
      y: root.open ? 0 : 40
      Behavior on y { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
    }

    Column {
      id: sheetCol
      width: parent.width
      spacing: 4

      Item {
        width: parent.width
        height: 14

        Rectangle {
          anchors.centerIn: parent
          width: 36
          height: 4
          radius: 2
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
        }
      }

      // Title bar with the two panel actions.
      Item {
        width: parent.width
        height: 44

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.leftMargin: 16
          anchors.verticalCenter: parent.verticalCenter
          text: "Cast to"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: 16
          font.weight: Font.Bold
          width: parent.width - 120
          elide: Text.ElideRight
        }

        RowLayout {
          anchors.right: parent.right
          anchors.rightMargin: 14
          anchors.verticalCenter: parent.verticalCenter
          spacing: 6

          // Refresh: re-scans the network.
          Rectangle {
            id: refreshBtn
            width: 34
            height: 34
            radius: 17
            antialiasing: true
            enabled: !root.loading && !root.busy
            opacity: enabled ? 1.0 : 0.45
            color: refreshMa.containsMouse
              ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)

            Item {
              id: refreshIcon
              anchors.centerIn: parent
              width: 18
              height: 18

              SvgIcon {
                anchors.fill: parent
                size: 18
                // Rasterise at the display's density. The shared default is a
                // 2x supersample, which is downscaled again on a 1x screen and
                // makes an 18 px glyph look soft.
                renderScale: Screen.devicePixelRatio
                color: root.foreground
                source: Qt.resolvedUrl("../../assets/icons/refresh.svg")
              }

              NumberAnimation on rotation {
                running: root.loading
                loops: Animation.Infinite
                from: 0
                to: 360
                // One turn per second, the same second `Service` holds
                // `castLoading` for (`castSpinMinimumMs`). A scan answered from
                // the daemon's cache still shows exactly one full rotation:
                // the animation and the hold start together, so the glyph
                // reaches 0° again as the hold expires rather than being cut
                // at an arbitrary angle.
                duration: root.svc && root.svc.castSpinMinimumMs
                  ? root.svc.castSpinMinimumMs : 1000
                // Snap back the moment the refresh lands, so the glyph never
                // freezes tilted at an arbitrary angle.
                onStopped: refreshIcon.rotation = 0
              }
            }

            MouseArea {
              id: refreshMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.refresh()
            }

            ButtonToolTip {
              host: refreshMa
              text: "Refresh devices"
              fontFamily: root.fontFamily
            }
          }

          // Stop casting: disconnects and returns playback to the speakers.
          Rectangle {
            id: stopBtn
            width: 34
            height: 34
            radius: 17
            antialiasing: true
            visible: root.casting
            enabled: !root.busy
            opacity: enabled ? 1.0 : 0.45
            color: stopMa.containsMouse
              ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.2)
              : Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.12)

            SvgIcon {
              anchors.centerIn: parent
              // A 16 px box in a 34 px button centres on integer pixels; 15 px
              // sat on a half pixel and rendered soft.
              size: 16
              color: Color.urgent
              // A stop square, not the panels' close X: this ends the cast
              // session and does not dismiss the sheet.
              source: Qt.resolvedUrl("../../assets/icons/stop.svg")
            }

            MouseArea {
              id: stopMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.stopCasting()
            }

            ButtonToolTip {
              host: stopMa
              text: "Stop casting"
              fontFamily: root.fontFamily
            }
          }
        }
      }

      // Blocking-firewall notice: the most important thing on the panel when
      // it applies, so it sits above the devices rather than inside the list.
      Rectangle {
        width: parent.width - 32
        anchors.horizontalCenter: parent.horizontalCenter
        height: noticeCol.implicitHeight + 20
        radius: 10
        visible: root.blocked
        color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12)
        border.width: 1
        border.color: (root.cursorIndex === 0)
          ? Color.accent
          : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45)

        Column {
          id: noticeCol
          anchors.fill: parent
          anchors.margins: 10
          spacing: 6

          RowLayout {
            width: parent.width
            spacing: 8

            SvgIcon {
              size: 16
              color: Color.accent
              source: Qt.resolvedUrl("../../assets/icons/lock.svg")
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: "The device can't reach this computer"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: 13
              font.weight: Font.Bold
              elide: Text.ElideRight
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Allow port 27823 through the firewall so the device can fetch the audio."
            color: root.foreground
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: 11
            wrapMode: Text.WordWrap
          }

          RowLayout {
            width: parent.width

            Item { Layout.fillWidth: true }

            Rectangle {
              id: allowBtn
              Layout.preferredWidth: allowLabel.implicitWidth + 22
              Layout.preferredHeight: 28
              radius: 14
              color: allowMa.containsMouse
                ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.32)
                : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.2)
              border.width: 1
              border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.6)

              Text {
                id: allowLabel
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: "Allow port 27823"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: 11
                font.weight: Font.DemiBold
              }

              MouseArea {
                id: allowMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.allowFirewall()
              }
            }
          }
        }
      }

      // Device lists. A section label makes the scroll area read as a list even
      // when several devices are present. Devices whose Cast port did not
      // answer are dimmed, inert and grouped under their own heading below, so
      // they never read as targets.
      Flickable {
        id: deviceFlick
        width: parent.width
        height: Math.min(deviceColumn.implicitHeight, Style.space(300))
        contentHeight: deviceColumn.implicitHeight
        clip: true
        visible: root.devices.length > 0

        Column {
          id: deviceColumn
          width: parent.width

          Item {
            width: parent.width
            height: 26
            visible: root.availableDevices.length > 0

            Text {
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.leftMargin: 16
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 4
              text: "DEVICES"
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: 10
              font.weight: Font.Bold
              font.letterSpacing: 0.8
            }

            Text {
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.rightMargin: 16
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 4
              text: root.availableDevices.length
                + (root.availableDevices.length === 1 ? " device" : " devices")
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: 10
            }
          }

          Repeater {
            model: root.availableDevices
            delegate: deviceRowComponent
          }

          Item {
            width: parent.width
            height: 34
            visible: root.unavailableDevices.length > 0

            Text {
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.leftMargin: 16
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 4
              text: "UNAVAILABLE"
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: 10
              font.weight: Font.Bold
              font.letterSpacing: 0.8
            }

            Text {
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.rightMargin: 16
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 4
              text: root.unavailableDevices.length
                + (root.unavailableDevices.length === 1 ? " device" : " devices")
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: 10
            }
          }

          Repeater {
            model: root.unavailableDevices
            delegate: deviceRowComponent
          }
        }
      }

      // One row, used by both sections. Its `index` is the repeater index; the
      // keyboard cursor only counts reachable rows, so an unavailable row can
      // never take the cursor (`isAvailable` is part of `hasCursor`).
      Component {
        id: deviceRowComponent

        Rectangle {
          id: deviceRow
          required property var modelData
          required property int index
          readonly property bool hasCursor: deviceRow.isAvailable
            && root.cursorIndex === root.deviceOffset + deviceRow.index
          readonly property bool isActive: root.casting && String(deviceRow.modelData.id) === root.activeId
          readonly property bool isConnecting: root.connectingId !== ""
            && String(deviceRow.modelData.id) === root.connectingId
          // The daemon probes the Cast port on every list request. A
          // failed probe keeps the row for a minute, dimmed as
          // Unavailable, so a Wi-Fi hiccup cannot make the list jump.
          readonly property bool isAvailable: deviceRow.modelData.available !== false
          // The row the last connect attempt failed on. Cleared by the
          // next attempt, a disconnect, or closing the sheet.
          readonly property bool isFailed: root.failedId !== ""
            && String(deviceRow.modelData.id) === root.failedId
            && !deviceRow.isConnecting && !deviceRow.isActive
          width: deviceColumn.width
          height: 52
          color: deviceRow.hasCursor
            ? Style.hoverFillFor(root.foreground, Color.accent)
            : (deviceMa.containsMouse && root.cursorIndex < 0 && !deviceRow.isConnecting
              && deviceRow.isAvailable
              ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
              : "transparent")

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            spacing: 12
            opacity: deviceRow.isAvailable ? 1.0 : 0.45

            SvgIcon {
              size: 20
              // Only a live cast is accented: a row that is still
              // connecting keeps the default text colour, so the accent
              // stays on the "Connecting..." line alone.
              color: deviceRow.isActive ? Color.accent : root.foreground
              source: Qt.resolvedUrl(
                "../../assets/icons/" + root.deviceIcon(deviceRow.modelData.kind))
            }

            Column {
              Layout.fillWidth: true
              spacing: 2

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: String(deviceRow.modelData.name || "Cast device")
                color: deviceRow.isActive ? Color.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: 13
                font.weight: Font.DemiBold
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: deviceRow.isConnecting
                  ? "Connecting..."
                  : String(deviceRow.modelData.model || "Chromecast")
                color: deviceRow.isConnecting ? Color.accent : root.foreground
                opacity: deviceRow.isConnecting ? 1.0 : 0.65
                font.family: root.fontFamily
                font.pixelSize: 11
                elide: Text.ElideRight
              }
            }

            Rectangle {
              visible: deviceRow.isActive && !deviceRow.isConnecting
              width: activeLabel.implicitWidth + 14
              height: 20
              radius: 10
              color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)

              Text {
                id: activeLabel
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: "Casting"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: 10
                font.weight: Font.DemiBold
              }
            }

            // Neutral badge for the remembered device. It never competes
            // with the accent "Casting" badge.
            Rectangle {
              visible: root.showLastUsedBadge && String(deviceRow.modelData.id) === root.lastUsedId
                && !deviceRow.isActive && !deviceRow.isConnecting && deviceRow.isAvailable
                && !deviceRow.isFailed
              width: lastUsedLabel.implicitWidth + 14
              height: 20
              radius: 10
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)

              Text {
                id: lastUsedLabel
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: "Last used"
                color: root.foreground
                opacity: 0.75
                font.family: root.fontFamily
                font.pixelSize: 10
                font.weight: Font.DemiBold
              }
            }

            // The last connect attempt to this device failed. The panel
            // reports it here; no system notification is sent.
            Rectangle {
              visible: deviceRow.isFailed
              width: failedLabel.implicitWidth + 14
              height: 20
              radius: 10
              color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.16)

              Text {
                id: failedLabel
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: "Failed"
                color: Color.urgent
                font.family: root.fontFamily
                font.pixelSize: 10
                font.weight: Font.DemiBold
              }
            }
          }

          CursorRules {
            anchors.fill: parent
            shown: deviceRow.hasCursor
          }

          MouseArea {
            id: deviceMa
            anchors.fill: parent
            hoverEnabled: true
            // Unavailable rows are informational: no click, no hover, and
            // the default cursor, so they never look connectable.
            enabled: deviceRow.isAvailable && !deviceRow.isConnecting
            cursorShape: deviceRow.isAvailable && !deviceRow.isConnecting
              ? Qt.PointingHandCursor
              : Qt.ArrowCursor
            onClicked: root.pick(deviceRow.modelData)
          }
        }
      }

      // Empty / scanning state. Kept out of the list so a scan does not jump
      // the layout when the first device arrives.
      Column {
        width: parent.width
        visible: root.devices.length === 0
        spacing: 6
        topPadding: 8
        bottomPadding: 14

        Text {
          textFormat: Text.PlainText
          width: parent.width - 32
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.loading ? "Looking for cast devices…" : "No cast devices found"
          color: root.foreground
          opacity: 0.75
          font.family: root.fontFamily
          font.pixelSize: 13
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width - 32
          anchors.horizontalCenter: parent.horizontalCenter
          visible: !root.loading
          text: "Make sure the device is on the same network, then refresh."
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: 11
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
      }

      Item {
        width: parent.width
        height: 10
      }
    }
  }

  // Runs `cast allow` in Omarchy's floating presentation terminal, where the
  // sudo prompt is visible and themed.
  Process {
    id: allowProcess
    command: []
  }
}
