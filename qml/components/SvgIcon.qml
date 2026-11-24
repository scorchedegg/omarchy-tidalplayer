import QtQuick
import Qt5Compat.GraphicalEffects

Item {
  id: root

  property string source: ""
  property color color: "#ffffff"
  property real size: 24
  // Supersampling factor for the rasterised SVG. 2 is a good default for
  // HiDPI, but a 1x screen showing a 16 px glyph is better served by 1: the
  // 2x raster is immediately downscaled again, which softens it.
  property real renderScale: 2

  implicitWidth: size
  implicitHeight: size
  width: implicitWidth
  height: implicitHeight

  Image {
    id: img
    anchors.fill: parent
    source: root.source
    fillMode: Image.PreserveAspectFit
    sourceSize.width: Math.max(16, Math.round(root.size * root.renderScale))
    sourceSize.height: Math.max(16, Math.round(root.size * root.renderScale))
    visible: false
    asynchronous: true
  }

  ColorOverlay {
    id: overlay
    anchors.fill: img
    source: img
    color: root.color
    cached: true
  }
}
