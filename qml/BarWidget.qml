import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Ui
import qs.Commons
import "components"
import "lib/Format.js" as Format
import "lib/Wheel.js" as Wheel

// BarWidget: Sleek TIDAL now-playing presence for the Omarchy bar.
BarWidget {
  id: root
  moduleName: "scorchedegg.tidalplayer"

  property bool alive: true

  readonly property var svc: bar?.shell?.serviceFor("scorchedegg.tidalplayer") ?? null

  readonly property bool hasTrack: svc ? (svc.title !== "" || svc.playing) : false
  readonly property bool playing: svc ? svc.playing : false
  readonly property bool daemonDown: svc ? svc.daemonState === "down" : false
  readonly property bool daemonStarting: svc ? svc.daemonState === "starting" : false
  // One "daemon not here" look for both states. While a start is still running
  // there is nothing to play, so the red mark, the dimmed sleeve and the
  // full-strength labels stay up until the socket connects; only the tooltip
  // distinguishes the two.
  readonly property bool daemonOffline: root.daemonDown || root.daemonStarting
  readonly property string title: svc ? svc.title : ""
  readonly property string artist: svc ? svc.artist : ""
  readonly property string artUrl: svc ? svc.artUrl : ""
  readonly property string qualityLabel: svc ? Format.formatBadge(svc.formatBadge) : ""
  readonly property bool isHiRes: svc ? svc.isHiRes : false

  readonly property bool showQuality: setting("showQualityBadge", false) && qualityLabel !== ""
  readonly property int minMaxLabelWidth: 60
  readonly property int maxMaxLabelWidth: 400
  readonly property int maxLabelWidthStep: 5
  readonly property int maxLabelWidthWheelStep: 10
  readonly property real maxLabelWidth: setting("maxLabelWidth", 180)
  // Live override while the context menu's width slider is being dragged so
  // the bar resizes smoothly without writing shell.json on every pointer move.
  property real previewMaxLabelWidth: -1
  readonly property real effectiveMaxLabelWidth: root.previewMaxLabelWidth >= 0
    ? root.previewMaxLabelWidth
    : root.maxLabelWidth
  readonly property bool showLabel: setting("showLabel", true)
  readonly property bool hideWhenPaused: setting("hideWhenPaused", false)
  readonly property bool animatedArtwork: setting("animatedArtwork", true)

  function clampMaxLabelWidth(px) {
    var snapped = Math.round(Number(px) / root.maxLabelWidthStep) * root.maxLabelWidthStep
    return Math.max(root.minMaxLabelWidth, Math.min(root.maxMaxLabelWidth, snapped))
  }

  // Apply locally first so the bar updates on the same frame; shell.json then
  // persists the entry and syncs any other monitor's instance of this widget.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) {
      if (existing !== "id") entry[existing] = root.settings[existing]
    }
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    }
  }

  // Per-monitor visibility: comma-separated output names this instance may
  // show on. Empty (the default) shows everywhere. The bar builds one
  // instance per screen, so each copy filters against its own output.
  readonly property var monitorFilter: {
    var names = []
    var parts = String(setting("monitors", "")).split(",")
    for (var i = 0; i < parts.length; i++) {
      var name = parts[i].trim()
      if (name !== "") names.push(name)
    }
    return names
  }

  property bool menuOpen: false
  onMenuOpenChanged: if (!menuOpen) root.previewMaxLabelWidth = -1

  // Art or TIDAL Logo mark:
  readonly property bool hasArt: artUrl !== ""
  readonly property bool showArt: !root.vertical && hasArt && hasTrack
  readonly property bool showLogo: !showArt

  // Cover size tracks the bar height, clamped so it stays legible in both
  // compact and roomy bars. Tall bars (>= 32 px) stack title and artist
  // pinned to the cover's top and bottom edges; compact bars (< 32 px,
  // including the 26 px default) switch to a single inline line.
  readonly property real barPixelHeight: root.height > 0 ? root.height : root.barSize
  readonly property bool compactBar: root.barPixelHeight < 32
  readonly property real artSize: Math.max(18, Math.min(32, Math.round(root.barPixelHeight - 12)))
  readonly property real titleFontPixel: Math.max(9, Math.min(14, Math.round(root.artSize * 0.45)))
  readonly property real artistFontPixel: Math.max(8, Math.min(12, Math.round(root.artSize * 0.38)))

  // Hide where we're not wanted: `hideWhenPaused` while nothing plays, and
  // the `monitors` filter against this instance's output. A slot whose widget
  // is invisible collapses to zero width, so the filtered-out monitors' bars
  // just show nothing here. Unknown output (no bar window, e.g. settings
  // previews) keeps the widget visible.
  readonly property bool allowedOnMonitor: monitorFilter.length === 0 || screenName === ""
    || monitorFilter.indexOf(screenName) !== -1
  visible: (!hideWhenPaused || playing) && allowedOnMonitor
  implicitWidth: root.hasTrack
    ? Math.ceil(contentRow.implicitWidth + (typeof Style !== "undefined" && Style.space ? Style.space(14) : 14))
    : Math.ceil(Math.max(38, contentRow.implicitWidth + (typeof Style !== "undefined" && Style.space ? Style.space(12) : 12)))
  implicitHeight: root.barSize
  readonly property real openPanelIndicatorWidth: contentRow.implicitWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  // Popup lifecycle
  property bool popupOpen: false
  readonly property bool opened: popupOpen

  // The panel is centred over this widget, and the widget's width follows the
  // track title. Re-anchoring live would slide the open panel around on every
  // song change, so the rect used by the panel is captured on open and held
  // until the panel has closed again.
  property real frozenAnchorX: 0
  property real frozenAnchorY: 0
  property real frozenAnchorW: 0
  property real frozenAnchorH: 0

  // This widget's live position in the bar content surface. `transform` from
  // the watcher is the reactive dependency: mapToItem on its own is a
  // one-shot.
  readonly property var barContentItem: root.QsWindow.window ? root.QsWindow.window.contentItem : null
  TransformWatcher {
    id: barAnchorWatcher
    a: root.barContentItem
    b: root
  }
  readonly property point liveBarPos: {
    barAnchorWatcher.transform
    if (!root.barContentItem) return Qt.point(0, 0)
    return root.mapToItem(root.barContentItem, 0, 0)
  }

  // Stationary stand-in for this widget used as the panel's anchor. It stays
  // a child of the widget (so it shares the bar surface) and offsets itself by
  // however far the widget has moved since the rect was captured.
  Item {
    id: frozenAnchor
    visible: false
    width: root.frozenAnchorW
    height: root.frozenAnchorH
    x: root.frozenAnchorX - root.liveBarPos.x
    y: root.frozenAnchorY - root.liveBarPos.y
  }

  // Separate frozen rect for the right-click context menu so toggling the
  // track label or dragging the max-width slider resizes the bar widget
  // underneath without sliding the menu sideways under the pointer.
  property real menuAnchorX: 0
  property real menuAnchorY: 0
  property real menuAnchorW: 0
  property real menuAnchorH: 0

  Item {
    id: menuFrozenAnchor
    visible: false
    width: root.menuAnchorW
    height: root.menuAnchorH
    x: root.menuAnchorX - root.liveBarPos.x
    y: root.menuAnchorY - root.liveBarPos.y
  }

  // This widget's live rect in screen coordinates while the popup is open.
  // Feeds the cutout in the popup's full-screen dismiss mask (below) so the
  // bar keeps receiving wheel and mouse events instead of the overlay above
  // it — over the widget's *current* position, not the frozen anchor's.
  readonly property real widgetScreenX: popup
    ? (popup.barPos === "right" ? popup.screenW - popup.barW + root.liveBarPos.x : root.liveBarPos.x)
    : 0
  readonly property real widgetScreenY: popup
    ? (popup.barPos === "bottom" ? popup.screenH - popup.barH + root.liveBarPos.y : root.liveBarPos.y)
    : 0
  readonly property real widgetScreenW: root.width
  readonly property real widgetScreenH: root.height

  readonly property bool popoutSwitchClosing: popup ? popup.popoutSwitchClosing : false
  function closeForPopoutSwitch() {
    if (popup) popup.popoutSwitchClosing = true
    root.close()
    Qt.callLater(function() { if (root && root.alive && popup) popup.popoutSwitchClosing = false })
  }

  function open() {
    root.menuOpen = false
    if (root.popupOpen) {
      if (root.svc) root.svc.activeMiniPlayer = root
      return
    }
    if (root.svc && root.svc.activeMiniPlayer !== root && typeof root.svc.closeMini === "function") root.svc.closeMini()
    // Capture the rect before opening: the panel anchors to it for its whole
    // lifetime, so a track change cannot recentre it mid-flight. Measure
    // directly rather than reading `liveBarPos`, whose watcher may lag.
    var pos = root.barContentItem ? root.mapToItem(root.barContentItem, 0, 0) : Qt.point(0, 0)
    root.frozenAnchorX = pos.x
    root.frozenAnchorY = pos.y
    root.frozenAnchorW = root.width
    root.frozenAnchorH = root.height
    root.popupOpen = true
    if (root.svc) root.svc.activeMiniPlayer = root
  }
  function close() {
    root.popupOpen = false
    if (root.svc && root.svc.activeMiniPlayer === root) root.svc.activeMiniPlayer = null
  }
  function toggle() {
    if (root.popupOpen) {
      root.close()
    } else {
      if (root.svc && typeof root.svc.closeMini === "function") root.svc.closeMini()
      root.open()
    }
  }

  function toggleMenu() {
    if (root.menuOpen) {
      root.closeMenu()
      return
    }
    // Opening the menu must not fight the main panel for the bar's popout
    // slot; requestPopout would close the panel too, but doing it here keeps
    // the widget's own state in step immediately.
    if (root.popupOpen) root.close()
    var pos = root.barContentItem ? root.mapToItem(root.barContentItem, 0, 0) : Qt.point(0, 0)
    root.menuAnchorX = pos.x
    root.menuAnchorY = pos.y
    root.menuAnchorW = root.width
    root.menuAnchorH = root.height
    root.menuOpen = true
  }

  function closeMenu() {
    root.previewMaxLabelWidth = -1
    root.menuOpen = false
  }

  // The bar is a layer-shell surface with keyboard focus disabled, so Wayland
  // never delivers it the keyboard's modifier state: a wheel event over the
  // bar always reports Qt.NoModifier and Ctrl+wheel looks like a plain wheel.
  // While the panel is closed, ask Hyprland for the live key state
  // (hl.is_key_down); with the panel open it holds keyboard focus and its
  // event modifiers are reliable.
  readonly property bool hyprlandAvailable: (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "") !== ""
  readonly property string modStatePath: {
    var dir = Quickshell.env("XDG_RUNTIME_DIR")
    if (!dir) return ""
    var screen = String(root.screenName || "default").replace(/[^A-Za-z0-9_-]/g, "_")
    return dir + "/scorchedegg.tidalplayer/modstate-" + screen
  }
  property int wheelModifiers: 0
  property real pendingWheelNotches: 0
  property bool wheelProbeRunning: false
  property var wheelNotchState: ({ accumulator: 0 })

  function handleWheelEvent(angleDeltaY, modifiers) {
    if (!root.svc || angleDeltaY === 0) return
    root.wheelModifiers = modifiers
    root.pendingWheelNotches += Wheel.accumulate(root.wheelNotchState, angleDeltaY)
    if (root.pendingWheelNotches === 0) {
      wheelFlushTimer.restart()
      return
    }
    wheelFlushTimer.stop()
    root.resolveWheel()
  }

  function resolveWheel() {
    if (root.pendingWheelNotches === 0) return
    if (!root.popupOpen && root.hyprlandAvailable && root.modStatePath !== "") {
      root.probeWheelModifiers()
      return
    }
    root.applyWheel((root.wheelModifiers & Qt.ControlModifier) !== 0)
  }

  function applyWheel(seek) {
    var notches = root.pendingWheelNotches
    if (notches === 0) return
    root.pendingWheelNotches = 0
    if (seek) {
      if (root.svc && typeof root.svc.seekBy === "function") root.svc.seekBy(notches * 10)
      return
    }
    if (!root.svc || typeof root.svc.stepVolume !== "function") return
    root.svc.stepVolume(notches)
    volumeOsd.show(root.svc.volume)
  }

  // The output this widget's bar instance sits on, so the volume toast appears
  // on the monitor that was scrolled rather than on the focused one.
  readonly property var osdScreen: {
    var all = Quickshell.screens
    for (var i = 0; i < all.length; i++) {
      if (String(all[i].name) === root.screenName) return all[i]
    }
    return null
  }

  VolumeOsd {
    id: volumeOsd
    targetScreen: root.osdScreen
    maxVolume: (root.svc && root.svc.maxVolume !== undefined) ? root.svc.maxVolume : 1.5
  }

  function probeWheelModifiers() {
    if (root.wheelProbeRunning) return
    root.wheelProbeRunning = true
    var escapedPath = root.modStatePath.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
    var lua = 'local f=io.open("' + escapedPath + '","w") '
      + 'if f then f:write((hl.is_key_down("Control_L") or hl.is_key_down("Control_R")) and "1" or "0") f:close() end'
    wheelProbe.command = ["sh", "-c",
      "p=$1; mkdir -p \"${p%/*}\"; rm -f \"$p\"; "
      + "hyprctl eval " + Util.shellQuote(lua) + " >/dev/null 2>&1; "
      + "cat \"$p\" 2>/dev/null; rm -f \"$p\"", "sh", root.modStatePath]
    wheelProbe.running = true
  }

  Process {
    id: wheelProbe
    stdout: StdioCollector {
      id: wheelProbeOutput
      waitForEnd: true
      onStreamFinished: {
        if (!root || !root.alive) return
        root.wheelProbeRunning = false
        root.applyWheel(wheelProbeOutput.text.trim() === "1")
      }
    }
    onExited: {
      if (!root || !root.alive) return
      root.wheelProbeRunning = false
    }
  }

  Timer {
    id: wheelFlushTimer
    interval: 180
    onTriggered: {
      if (!root || !root.alive) return
      root.pendingWheelNotches += Wheel.leftover(root.wheelNotchState, 1)
      root.resolveWheel()
    }
  }

  function setFace(name, params) {
    root.open()
    if (mini) mini.setFace(name, params)
  }

  function pushFace(name, params) {
    root.open()
    if (mini) mini.pushFace(name, params)
  }

  function openSheet(name) {
    root.open()
    if (mini) mini.openSheet(name)
  }

  function back() {
    if (mini) mini.back()
  }

  function forward() {
    if (mini) mini.forward()
  }

  function openTrackMenu() {
    if (mini) mini.openTrackMenu()
  }

  function toggleLyrics() {
    if (mini) mini.toggleLyrics()
  }

  function triggerPress(button) {
    if (button === Qt.LeftButton) {
      root.toggle()
    } else if (button === Qt.RightButton) {
      root.toggleMenu()
    } else if (button === Qt.MiddleButton) {
      if (root.svc) root.svc.playPause()
    } else if (button === Qt.BackButton) {
      if (root.svc) root.svc.previous()
    } else if (button === Qt.ForwardButton) {
      if (root.svc) root.svc.next()
    }
  }

  property var registeredBar: null
  function syncBarClickTarget() {
    if (root.registeredBar && typeof root.registeredBar.unregisterClickTarget === "function") {
      root.registeredBar.unregisterClickTarget(root)
    }
    root.registeredBar = root.bar
    if (root.registeredBar && typeof root.registeredBar.registerClickTarget === "function") {
      root.registeredBar.registerClickTarget(root)
    }
  }

  onBarChanged: root.syncBarClickTarget()

  readonly property string screenName: {
    var window = root.QsWindow.window
    return window && window.screen ? String(window.screen.name) : ""
  }

  function toggleIfFocused() {
    if (!root.allowedOnMonitor) return false
    var focused = (typeof Hyprland !== "undefined" && Hyprland.focusedMonitor)
      ? String(Hyprland.focusedMonitor.name || "")
      : (root.bar && typeof root.bar.focusedScreenName === "function" ? String(root.bar.focusedScreenName() || "") : "")
    if (focused !== "" && focused !== root.screenName) return false
    root.toggle()
    return true
  }

  function openIfFocused() {
    if (!root.allowedOnMonitor) return false
    var focused = (typeof Hyprland !== "undefined" && Hyprland.focusedMonitor)
      ? String(Hyprland.focusedMonitor.name || "")
      : (root.bar && typeof root.bar.focusedScreenName === "function" ? String(root.bar.focusedScreenName() || "") : "")
    if (focused !== "" && focused !== root.screenName) return false
    root.open()
    return true
  }

  // Sync registration with service for IPC summoning
  property var registeredWith: null
  function syncRegistration() {
    root.syncBarClickTarget()
    if (root.registeredWith === root.svc) return
    if (root.registeredWith && typeof root.registeredWith.unregisterMiniPlayer === "function") {
      root.registeredWith.unregisterMiniPlayer(root)
    }
    root.registeredWith = root.svc
    if (root.svc && typeof root.svc.registerMiniPlayer === "function") {
      root.svc.registerMiniPlayer(root)
    }
  }

  onSvcChanged: root.syncRegistration()
  Component.onCompleted: root.syncRegistration()
  Component.onDestruction: {
    root.alive = false
    wheelFlushTimer.stop()
    wheelProbe.running = false
    if (root.registeredBar && typeof root.registeredBar.unregisterClickTarget === "function") {
      root.registeredBar.unregisterClickTarget(root)
    }
    if (root.registeredWith && typeof root.registeredWith.unregisterMiniPlayer === "function") {
      root.registeredWith.unregisterMiniPlayer(root)
    }
  }

  // The bar lays widgets out at fractional x positions, which puts the cover's
  // 1 px edge halfway between device pixels and makes it look blurry. Snap the
  // whole content row to the window's pixel grid (the layout slot is
  // unchanged; only the drawing offset moves by <1 px).
  readonly property real contentSnapX: {
    var x = root.liveBarPos.x + contentRow.x
    return Math.round(x) - x
  }
  readonly property real contentSnapY: {
    var y = root.liveBarPos.y + contentRow.y
    return Math.round(y) - y
  }

  RowLayout {
    id: contentRow
    width: implicitWidth
    height: implicitHeight
    // Round the centred position to whole pixels so the artwork's rounded
    // mask is not resampled between pixels (text is unaffected either way).
    x: Math.round((root.width - width) / 2)
    y: Math.round((root.height - height) / 2)
    transform: Translate {
      x: root.contentSnapX
      y: root.contentSnapY
    }
    spacing: Style.space(2 + root.artSize * 0.2)

    // Artwork sleeve, dimmed while paused
    Item {
      Layout.preferredWidth: root.artSize
      Layout.preferredHeight: root.artSize
      visible: root.showArt

      Rectangle {
        id: coverFrame
        anchors.fill: parent
        radius: 2
        color: "transparent"
        // Dim the artwork itself while paused or while the daemon is away:
        // stale art behind a red mark gets the same halted-playback weight as
        // a paused track. The border is drawn as a separate overlay so it
        // stays crisp and does not fade with the cover.
        opacity: root.hasTrack && (!root.playing || root.daemonOffline) ? 0.45 : 1.0

        Behavior on opacity {
          NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }

        RoundedImage {
          anchors.fill: parent
          radius: 2
          borderWidth: 1
          borderColor: Qt.rgba(root.bar ? root.bar.barForeground.r : Color.foreground.r,
                               root.bar ? root.bar.barForeground.g : Color.foreground.g,
                               root.bar ? root.bar.barForeground.b : Color.foreground.b, 0.14)
          source: root.artUrl
          // A 2x source whose first mip level matches the drawn cover keeps
          // the tiny sleeve crisp instead of double-downscaling a 64 px
          // texture to ~22 px.
          sourceSize.width: Math.ceil(root.artSize * 2)
          sourceSize.height: Math.ceil(root.artSize * 2)
        }
      }

      // Paused indicator over the cover. Two rectangles, not an icon: at
      // this size an SVG rasterises blurry, while these stay pixel-sharp.
      Item {
        id: pauseBadge
        // Centre on whole pixels: a half-pixel origin softens every edge.
        x: Math.round((parent.width - width) / 2)
        y: Math.round((parent.height - height) / 2)
        width: Math.max(7, Math.round(parent.width * 0.42))
        height: width
        visible: root.hasTrack && !root.playing && !root.daemonOffline

        // Whole-pixel, square-ended geometry: fractional radii rasterise
        // the tiny bars with soft edges.
        readonly property int barWidth: Math.max(2, Math.round(width * 0.22))
        readonly property int barHeight: Math.round(height * 0.62)
        readonly property color badgeColor: root.bar ? root.bar.barForeground : (Color.bar ? Color.bar.text : Color.menu.text)

        Rectangle {
          width: pauseBadge.barWidth
          height: pauseBadge.barHeight
          color: pauseBadge.badgeColor
          antialiasing: false
          y: Math.round((pauseBadge.height - height) / 2)
          x: Math.round(pauseBadge.width * 0.3 - width / 2)
        }

        Rectangle {
          width: pauseBadge.barWidth
          height: pauseBadge.barHeight
          color: pauseBadge.badgeColor
          antialiasing: false
          y: Math.round((pauseBadge.height - height) / 2)
          x: Math.round(pauseBadge.width * 0.7 - width / 2)
        }
      }

      // Offline mark. A dark disc behind the red ring keeps it legible over
      // both light and dark covers.
      Item {
        id: daemonBadge
        x: Math.round((parent.width - width) / 2)
        y: Math.round((parent.height - height) / 2)
        width: Math.max(10, Math.round(parent.width * 0.5))
        height: width
        visible: root.hasTrack && root.daemonOffline

        Rectangle {
          anchors.fill: parent
          radius: width / 2
          color: Qt.rgba(Color.popups.background.r, Color.popups.background.g,
                         Color.popups.background.b, 0.72)
        }

        DisconnectedIcon {
          anchors.fill: parent
          size: parent.width
          color: Color.urgent
        }
      }
    }

    // TIDAL Vector Logo when idle or no artwork. The offline mark only takes
    // this slot when there is a track to pair it with: with no current track
    // the widget keeps the plain logo in every daemon state, because a red
    // mark alone in an otherwise empty slot is an alarm with nothing to
    // explain itself.
    DisconnectedIcon {
      Layout.alignment: Qt.AlignVCenter
      visible: root.showLogo && root.daemonOffline && root.hasTrack
      size: Math.max(18, Math.round(Style.font.body * 1.35))
      color: Color.urgent
    }

    TidalLogo {
      Layout.alignment: Qt.AlignVCenter
      visible: root.showLogo && !(root.daemonOffline && root.hasTrack)
      size: Math.max(18, Math.round(Style.font.body * 1.35))
      color: root.bar ? root.bar.barForeground : (Color.bar ? Color.bar.text : Color.menu.text)
    }

    // Title & artist. Tall bars (>= 32 px) stack both lines pinned to the
    // cover's top and bottom edges; compact bars (< 32 px, including the
    // 26 px default) switch to a single inline "Title · Artist" line at the
    // bar's native body font size so glyphs aren't crushed into 18 px.
    Item {
      id: textCol
      Layout.alignment: Qt.AlignVCenter
      Layout.preferredWidth: root.hasTrack
        ? Math.ceil(Math.min(root.effectiveMaxLabelWidth,
            root.compactBar
              ? inlineText.implicitWidth
              : Math.max(titleText.implicitWidth, artistText.implicitWidth)))
        : 0
      Layout.preferredHeight: root.compactBar
        ? Math.max(root.artSize, Math.ceil(inlineText.implicitHeight))
        : root.artSize
      visible: root.hasTrack && root.showLabel && !root.vertical
      clip: false

      readonly property string labelFontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      readonly property color labelColor: root.bar ? root.bar.barForeground : (Color.bar ? Color.bar.text : Color.menu.text)
      readonly property real titleCapHeight: titleMetrics.capitalHeight > 0 ? titleMetrics.capitalHeight : titleMetrics.ascent * 0.75
      readonly property real titleTopInset: Math.max(0, titleText.baselineOffset - textCol.titleCapHeight)
      // Half the descender: names without descenders (AURORA) still meet the
      // cover's bottom edge, while "Kygo"-style names only dip half way past
      // it. Both offsets round to whole pixels so the glyphs stay sharp.
      readonly property real artistBottomInset: Math.max(0, artistText.baselineOffset + artistMetrics.descent * 0.5)

      FontMetrics {
        id: titleMetrics
        font: titleText.font
      }

      FontMetrics {
        id: artistMetrics
        font: artistText.font
      }

      Text {
        id: titleText
        textFormat: Text.PlainText
        visible: !root.compactBar
        width: parent.width
        height: implicitHeight
        y: -Math.round(textCol.titleTopInset) + 1
        text: root.title
        font.family: textCol.labelFontFamily
        font.pixelSize: root.titleFontPixel
        font.weight: Font.Normal
        color: textCol.labelColor
        maximumLineCount: 1
        clip: true
      }

      Text {
        id: artistText
        textFormat: Text.PlainText
        visible: !root.compactBar && text !== ""
        width: parent.width
        height: implicitHeight
        y: Math.round(parent.height - textCol.artistBottomInset)
        text: root.artist
        font.family: textCol.labelFontFamily
        font.pixelSize: root.artistFontPixel
        font.weight: Font.Normal
        color: textCol.labelColor
        opacity: 0.7
        maximumLineCount: 1
        clip: true
      }

      Text {
        id: inlineText
        textFormat: Text.PlainText
        visible: root.compactBar
        width: parent.width
        height: implicitHeight
        y: Math.round((parent.height - implicitHeight) / 2)
        text: root.title !== "" && root.artist !== ""
          ? root.title + " · " + root.artist
          : (root.title !== "" ? root.title : root.artist)
        font.family: textCol.labelFontFamily
        font.pixelSize: Style.font.body
        font.weight: Font.Normal
        color: textCol.labelColor
        maximumLineCount: 1
        clip: true
      }

      // The bar has a flat theme background, so fade the clipped text with a
      // real gradient instead of a layer effect. A text layer is resampled at
      // these tiny sizes and made overflowing labels look blurry.
      Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Math.max(Style.space(12), Math.round(parent.width * 0.1))
        visible: root.bar && !root.bar.transparent
          && (root.compactBar
            ? inlineText.contentWidth > inlineText.width + 0.5
            : (titleText.contentWidth > titleText.width + 0.5
              || (artistText.visible && artistText.contentWidth > artistText.width + 0.5)))
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: "transparent" }
          GradientStop {
            position: 1.0
            color: root.bar ? root.bar.background : Color.popups.background
          }
        }
      }
    }

    // Optional Audio Quality Badge
    Rectangle {
      Layout.preferredHeight: Math.ceil(qualityBadgeText.implicitHeight + Style.space(2))
      Layout.preferredWidth: Math.ceil(qualityBadgeText.implicitWidth + Style.space(8))
      radius: 0
      color: Qt.rgba(root.bar ? root.bar.barForeground.r : Color.foreground.r,
                     root.bar ? root.bar.barForeground.g : Color.foreground.g,
                     root.bar ? root.bar.barForeground.b : Color.foreground.b, 0.12)
      visible: root.showQuality && root.hasTrack && root.showLabel && !root.vertical && !root.daemonOffline

      Text {
        textFormat: Text.PlainText
        id: qualityBadgeText
        anchors.centerIn: parent
        text: root.qualityLabel
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        font.weight: Font.Normal
        color: root.bar ? root.bar.barForeground : (Color.bar ? Color.bar.text : Color.menu.text)
        opacity: 0.85
      }
    }

  }

  MouseArea {
    id: barMa
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton | Qt.BackButton | Qt.ForwardButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    onEntered: if (root.bar) root.bar.showTooltip(root, root.daemonDown
      ? "TIDAL Player — daemon offline"
      : (root.daemonStarting
        ? "TIDAL Player — starting daemon"
        : (root.hasTrack ? (root.title + (root.artist ? " — " + root.artist : "")) : "TIDAL Player")))
    onExited: if (root.bar) root.bar.hideTooltip(root)

    onClicked: function(mouse) {
      root.triggerPress(mouse.button)
    }

    onWheel: function(wheel) {
      wheel.accepted = true
      root.handleWheelEvent(wheel.angleDelta.y, wheel.modifiers)
    }
  }

  KeyboardPanel {
    id: popup
    // Anchored to the frozen rect while the panel is up (and while it fades
    // out, so closing does not snap it to the widget's new position).
    anchorItem: root.popupOpen || popup.visible ? frozenAnchor : root
    bar: root.bar
    owner: root
    open: root.popupOpen
    padding: 0
    // Focus is owned by MiniPlayer: on open it focuses the face's editor
    // (search/filter) or the key catcher, so reopening onto search keeps
    // typing working.
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(Style.space(580))

    // KeyboardPanel's dismiss overlay spans the whole screen above the bar,
    // so it swallows scroll wheel and back/forward button events aimed at
    // the widget while the panel is open. Cut this widget out of the
    // overlay's input region: events over it then hit the bar surface and
    // the widget's own MouseArea handles them exactly as when the panel is
    // closed. Clicks elsewhere on the bar still route through the overlay.
    mask: Region {
      width: popup.screenW
      height: popup.screenH

      Region {
        x: Math.round(root.widgetScreenX)
        y: Math.round(root.widgetScreenY)
        width: Math.max(1, Math.round(root.widgetScreenW))
        height: Math.max(1, Math.round(root.widgetScreenH))
        intersection: Intersection.Subtract
      }
    }

    MiniPlayer {
      id: mini
      anchors.fill: parent
      svc: root.svc
      foreground: Color.popups.text
      fontFamily: root.bar ? root.bar.fontFamily : Style.font.menuFamily
      panelOpen: popup.open
      // popup.visible lasts through the close fade, unlike popupOpen, so the
      // loop keeps playing until the panel has actually faded out.
      videoActive: popup.visible && root.animatedArtwork
      onCloseRequested: root.close()
      onTabRequested: function(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function") {
          root.bar.switchPanelFrom(root, direction)
        }
      }
    }
  }

  // Separate owner so the menu's outside-click dismiss closes only the menu;
  // the panel falls back to assigning its own `open`, which would break the
  // binding to menuOpen.
  QtObject {
    id: menuOwner
    function close() { root.closeMenu() }
  }

  // A KeyboardPanel, not a PopupCard: its window spans the screen, which lets
  // a standard PanelToolTip render above the card instead of being clamped
  // inside a small popup surface.
  KeyboardPanel {
    id: menu
    anchorItem: root.menuOpen || menu.visible ? menuFrozenAnchor : root
    bar: root.bar
    owner: menuOwner
    open: root.menuOpen
    contentWidth: menu.fittedContentWidth(Style.space(300))
    contentHeight: menu.fittedContentHeight(menuColumn.implicitHeight)

    // The dismiss overlay spans the whole screen above the bar, so cut this
    // widget out the same way the main panel does; wheel and back/forward
    // events over it then still reach the widget while the menu is up.
    mask: Region {
      width: menu.screenW
      height: menu.screenH

      Region {
        x: Math.round(root.widgetScreenX)
        y: Math.round(root.widgetScreenY)
        width: Math.max(1, Math.round(root.widgetScreenW))
        height: Math.max(1, Math.round(root.widgetScreenH))
        intersection: Intersection.Subtract
      }
    }

    Column {
      id: menuColumn
      width: parent.width
      spacing: Style.space(12)

      Shortcut {
        sequence: "Escape"
        enabled: root.menuOpen
        onActivated: root.closeMenu()
      }

      // Account header: the signed-in address sits at the top, with a compact
      // destructive logout button on its trailing edge. The avatar opens the
      // account's TIDAL web profile in the browser.
      RowLayout {
        width: parent.width
        spacing: Style.space(10)
        visible: !!root.svc && root.svc.loggedIn

        Rectangle {
          id: profileButton
          property bool linkable: !!root.svc && root.svc.accountUserId !== ""
          Layout.alignment: Qt.AlignVCenter
          Layout.preferredWidth: Style.space(34)
          Layout.preferredHeight: Style.space(34)
          radius: width / 2
          color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.08)
          border.width: profileMa.containsMouse ? Math.max(1, Style.hoverBorderWidth) : 1
          border.color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.14)

          RoundedImage {
            anchors.fill: parent
            radius: width / 2
            borderWidth: 1
            borderColor: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.14)
            source: root.svc ? root.svc.accountAvatarUrl : ""
            sourceSize.width: Math.ceil(width * 2)
            sourceSize.height: Math.ceil(height * 2)
            visible: source !== ""
          }

          SvgIcon {
            anchors.centerIn: parent
            size: Style.space(18)
            color: Color.popups.text
            opacity: 0.8
            source: Qt.resolvedUrl("../assets/icons/user.svg")
            visible: !(root.svc && root.svc.accountAvatarUrl !== "")
          }

          MouseArea {
            id: profileMa
            anchors.fill: parent
            hoverEnabled: true
            enabled: profileButton.linkable
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: {
              root.closeMenu()
              if (root.svc) root.svc.openAccountProfile()
            }
          }

          ButtonToolTip {
            host: profileMa
            text: "Open TIDAL profile"
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }
        }

        Column {
          Layout.fillWidth: true
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Signed in as"
            color: Color.popups.text
            opacity: 0.55
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: text !== ""
            text: root.svc ? root.svc.accountEmail : ""
            color: Color.popups.text
            opacity: 0.85
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            elide: Text.ElideMiddle
            maximumLineCount: 1
          }
        }

        Rectangle {
          id: logoutButton
          Layout.alignment: Qt.AlignVCenter
          Layout.preferredWidth: Style.space(34)
          Layout.preferredHeight: Style.space(34)
          radius: Style.cornerRadius
          color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b,
                         logoutMa.containsMouse ? 0.3 : 0.12)
          border.width: logoutMa.containsMouse ? Math.max(1, Style.hoverBorderWidth) : 0
          border.color: Color.urgent

          SvgIcon {
            anchors.centerIn: parent
            size: Style.space(16)
            color: Color.urgent
            source: Qt.resolvedUrl("../assets/icons/logout.svg")
          }

          MouseArea {
            id: logoutMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.closeMenu()
              if (root.svc) root.svc.logout()
            }
          }

          ButtonToolTip {
            host: logoutMa
            text: "Log out"
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }
        }
      }

      PanelSeparator {
        visible: !!root.svc && root.svc.loggedIn
        foreground: Color.popups.text
        strength: 0.1
      }

      // Bar widget display settings: compact borderless controls that share
      // the menu's horizontal rhythm instead of stacking heavy form cards.
      Column {
        width: parent.width
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          x: Style.space(6)
          width: parent.width - Style.space(12)
          text: "BAR WIDGET"
          color: Color.popups.text
          opacity: 0.5
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          font.weight: Font.DemiBold
          font.letterSpacing: 0.8
        }

        Rectangle {
          id: showLabelRow
          width: parent.width
          height: Math.max(Style.space(32), showLabelContent.implicitHeight + Style.space(8))
          radius: Style.cornerRadius
          color: showLabelMa.containsMouse
            ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.06)
            : "transparent"

          Behavior on color { ColorAnimation { duration: Style.duration(100) } }

          RowLayout {
            id: showLabelContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: "Show track name & artist"
              color: Color.popups.text
              opacity: 0.9
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            ToggleSwitch {
              id: showLabelSwitch
              checked: root.showLabel
              interactive: false
              cursorRing: false
              foreground: Color.popups.text
              accent: Color.accent
              trackHeight: Math.max(18, Math.round(Style.spacing.controlHeight * 0.48))
            }
          }

          MouseArea {
            id: showLabelMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.persistSettings({ showLabel: !root.showLabel })
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          opacity: root.showLabel ? 1.0 : 0.4
          enabled: root.showLabel

          Behavior on opacity { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

          RowLayout {
            width: parent.width - Style.space(12)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: "Max width"
              color: Color.popups.text
              opacity: 0.9
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              textFormat: Text.PlainText
              text: Math.round(root.effectiveMaxLabelWidth) + " px"
              color: Color.popups.text
              opacity: widthSlider.dragging ? 0.95 : 0.6
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.weight: Font.Medium
            }
          }

          PanelSlider {
            id: widthSlider
            width: parent.width - Style.space(12)
            anchors.horizontalCenter: parent.horizontalCenter
            bar: root.bar
            minimum: root.minMaxLabelWidth / root.maxLabelWidthStep
            maximum: root.maxMaxLabelWidth / root.maxLabelWidthStep
            step: root.maxLabelWidthWheelStep / root.maxLabelWidthStep
            integer: true
            value: Math.round(root.clampMaxLabelWidth(root.maxLabelWidth) / root.maxLabelWidthStep)
            trackHeight: Math.max(4, Style.space(4))
            knobSize: Math.max(12, Style.space(12))
            trackColor: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.18)
            fillColor: Color.popups.text
            knobColor: Color.popups.text
            onMoved: function(v) {
              root.previewMaxLabelWidth = root.clampMaxLabelWidth(v * root.maxLabelWidthStep)
            }
            onReleased: function(v) {
              var next = root.clampMaxLabelWidth(v * root.maxLabelWidthStep)
              root.previewMaxLabelWidth = -1
              root.persistSettings({ maxLabelWidth: next })
            }
          }
        }
      }
    }
  }

  // The sleeve decodes at its own small sourceSize, which the now-playing
  // warmers do not cover. Warm the same size for the upcoming covers so the
  // bar and the panel swap in the same frame on a skip.
  Repeater {
    model: (root.svc && root.visible && !root.vertical) ? root.svc.warmArtUrls : []

    Image {
      source: modelData
      asynchronous: true
      cache: true
      visible: false
      fillMode: Image.PreserveAspectCrop
      sourceSize.width: Math.ceil(root.artSize * 2)
      sourceSize.height: Math.ceil(root.artSize * 2)
    }
  }
}
