import QtQuick

// Holds the top of the page still while the content above it settles.
//
// A lazy ListView keeps the page header in its inline `header`, so `originY` is
// negative by the header's height. Qt moves `originY` when that header resizes
// but leaves `contentY` where it was: a header that grows after
// `positionViewAtBeginning()` — album credits and the duration line landing a
// frame after the rows, a title wrapping, a description arriving — leaves the
// page looking scrolled by exactly that growth, because the header's top edge
// ends up above the viewport. Nothing that already renders may move because
// content finished loading, so while the viewport still shows the page top this
// follows `originY` exactly. A page the user has scrolled into is left alone:
// the rows do not move in content coordinates when the header grows (only the
// header above them does), so there is nothing to compensate there.
//
// Place it as a direct child of the ListView/Flickable, next to
// `SmoothScrollHandler`. A plain Flickable keeps `originY` at 0 and never
// triggers anything.
Item {
  id: root
  anchors.fill: parent

  readonly property var flickable: {
    if (parent && typeof parent.contentY !== "undefined") return parent
    if (parent && parent.parent && typeof parent.parent.contentY !== "undefined") return parent.parent
    return null
  }

  // The originY the last move was measured against; only an inline header
  // changes it.
  property real lastOriginY: 0

  Component.onCompleted: root.sync()

  function sync() {
    if (root.flickable) root.lastOriginY = root.flickable.originY
  }

  Connections {
    target: root.flickable
    ignoreUnknownSignals: true
    function onOriginYChanged() {
      var view = root.flickable
      if (!view) return
      var before = root.lastOriginY
      root.lastOriginY = view.originY
      // Any downward movement since the last header change (a drag, a flick,
      // the wheel animation's first frame) means the page is no longer at its
      // top, so its viewport must not be touched.
      if (view.contentY > before + 0.5) return
      if (view.moving) return
      if (view.contentY !== view.originY) view.contentY = view.originY
    }
  }
}
