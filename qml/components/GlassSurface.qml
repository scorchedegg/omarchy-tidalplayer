import QtQuick
import QtQuick.Effects
import Qt5Compat.GraphicalEffects
import Quickshell
import qs.Commons

// Frosted-glass base for pills and round header buttons. It can blur live
// page content under the control (`sourceItem`, used by the floating header
// buttons so they frost whatever scrolls beneath them), a still image
// supplied by the caller (`imageSource`, used by the artist chips for their
// stained-glass wash), or both at once (the header artist chip, mirroring the
// collapsed player: page blur, then the artwork wash, then a theme tint).
// Everything is clipped to the control's rounded shape with OpacityMask:
// MultiEffect's own mask discards the antialiased rim and leaves a hard edge,
// and non-default mask thresholds suppress the effect entirely.
Item {
  id: root

  property Item sourceItem: null
  property string imageSource: ""
  property color tintColor: Color.popups.background
  // Callers set their own surface; the default is the estimated flat-button
  // tint that matches the collapsed player's net transparency (44 %, i.e.
  // 56 % of the blurred page visible). Chips pass the player's 24 %.
  property real tintAlpha: 0.44
  // How strongly a still image shows through the tint. Live content always
  // shows at full strength; the blur itself softens it. 26 % is the collapsed
  // player's artwork wash.
  property real imageOpacity: 0.26
  property real radius: height / 2
  // The page blur matches the collapsed player exactly.
  property real blurMax: 48
  property real blurAmount: 0.95
  // The still image uses the collapsed player's artwork wash: blur 0.70 with
  // max 56.
  property real imageBlurMax: 56
  property real imageBlurAmount: 0.70
  property size imageSourceSize: Qt.size(192, 192)

  readonly property bool hasContent: root.sourceItem !== null
  readonly property bool hasImage: root.imageSource !== ""
    && backdropImage.status === Image.Ready
  readonly property bool active: root.hasContent || root.hasImage

  // mapToItem() reads the item hierarchy without registering binding
  // dependencies, so a sourceRect binding that only maps coordinates never
  // updates after the layout moves the control. Bumping this once the scene
  // has laid out re-evaluates every slice, so each control samples its own
  // rect instead of the top-left one. The parent's position changes when the
  // right-hand button row shifts (share/heart appearing, the search bar
  // animating), so those moves refresh the slice too.
  property bool alive: true
  Component.onDestruction: root.alive = false
  property int layoutRevision: 0
  Component.onCompleted: Qt.callLater(function() { if (root && root.alive) root.layoutRevision++ })

  // mapToItem() reads coordinates without registering a binding dependency.
  // Watch the live transform instead: when the right-hand button row shifts
  // (share/heart appearing), the button's own x can stay put while an ancestor
  // moves, and a stale slice samples another button's content (or flips at the
  // page edge).
  TransformWatcher {
    id: positionWatcher
    a: root.sourceItem
    b: root
  }
  readonly property point pageOrigin: {
    positionWatcher.transform
    if (!root.sourceItem) return Qt.point(0, 0)
    return root.mapToItem(root.sourceItem, 0, 0)
  }

  Connections {
    target: root.parent
    function onXChanged() { root.layoutRevision++ }
    function onYChanged() { root.layoutRevision++ }
  }

  // Live slice of the page under the control. Exactly the control's rect,
  // rendered into its own small texture so several buttons can share the
  // same source item.
  ShaderEffectSource {
    id: contentSlice
    anchors.fill: parent
    sourceItem: root.sourceItem
    sourceRect: {
      if (root.layoutRevision < 0) return Qt.rect(0, 0, 1, 1)
      if (!root.sourceItem) return Qt.rect(0, 0, 1, 1)
      return Qt.rect(root.pageOrigin.x, root.pageOrigin.y, width, height)
    }
    textureSize: Qt.size(Math.max(1, Math.round(width)), Math.max(1, Math.round(height)))
    live: root.visible && root.hasContent
    visible: false
  }

  Image {
    id: backdropImage
    anchors.fill: parent
    source: root.imageSource
    fillMode: Image.PreserveAspectCrop
    sourceSize: root.imageSourceSize
    asynchronous: true
    visible: false
  }

  Rectangle {
    id: glassMask
    anchors.fill: parent
    radius: root.radius
    color: "white"
    visible: false
    antialiasing: true
  }

  MultiEffect {
    id: contentBlur
    anchors.fill: parent
    source: contentSlice
    blurEnabled: true
    blurMax: root.blurMax
    blur: root.blurAmount
    autoPaddingEnabled: false
    visible: false
  }

  MultiEffect {
    id: imageBlur
    anchors.fill: parent
    source: backdropImage
    blurEnabled: true
    blurMax: root.imageBlurMax
    blur: root.imageBlurAmount
    autoPaddingEnabled: false
    visible: false
  }

  OpacityMask {
    anchors.fill: parent
    source: contentBlur
    maskSource: glassMask
    cached: false
    visible: root.hasContent
  }

  // The image's opacity lives on the mask output: OpacityMask grabs the
  // MultiEffect texture directly, so an opacity set on the effect itself is
  // ignored and the wash renders fully opaque.
  OpacityMask {
    anchors.fill: parent
    source: imageBlur
    maskSource: glassMask
    cached: true
    opacity: root.imageOpacity
    visible: root.hasImage
  }

  Rectangle {
    anchors.fill: parent
    radius: root.radius
    color: Qt.rgba(root.tintColor.r, root.tintColor.g, root.tintColor.b, root.tintAlpha)
    visible: root.active
    antialiasing: true
  }
}
