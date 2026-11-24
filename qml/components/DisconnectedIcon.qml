import QtQuick
import qs.Commons

// A deliberately simple offline mark: a ring with a diagonal stroke across it.
// It is drawn from rectangles rather than an SVG because the bar draws it at
// ~10 px, where a rasterised icon turns to mush (same reason the pause badge is
// made of two rectangles).
Item {
  id: root

  property real size: 24
  property color color: Color.urgent

  implicitWidth: size
  implicitHeight: size

  readonly property int stroke: Math.max(1, Math.round(root.size * 0.09))

  Rectangle {
    anchors.fill: parent
    radius: width / 2
    color: "transparent"
    border.width: root.stroke
    border.color: root.color
    antialiasing: true
  }

  // The slash runs across the ring and ends inside its stroke, so the mark
  // reads as one connected glyph instead of a dash floating in the circle. It
  // rotates as a full-size item around the icon's own centre, which keeps the
  // line centred on both axes at every size.
  Item {
    anchors.fill: parent
    rotation: 45

    Rectangle {
      // Long enough for both rounded ends to overlap the ring's inner edge.
      width: Math.round(root.size * 0.94)
      height: root.stroke
      radius: root.stroke / 2
      color: root.color
      // Centre on the exact rotation pivot. `anchors.centerIn` rounds x/y to
      // whole pixels, and that half-pixel shift lies along the band before the
      // 45° rotation — after it, it becomes a perpendicular offset, so the
      // slash cut the 12 px bar ring about 55/45 instead of through the
      // centre. Explicit positions keep the fraction and pass through it.
      x: (root.size - width) / 2
      y: (root.size - height) / 2
      antialiasing: true
    }
  }
}
