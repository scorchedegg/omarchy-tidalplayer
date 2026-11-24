import QtQuick
import QtQuick.Effects

// Top and bottom edge fade for a clipped vertical surface (the lyric sheet).
// The mask is white at the two edges so MultiEffect hides them, and keeps a
// 0.05 sliver through the middle because the shader masks away alpha 0 as
// well; the threshold/spread pair turns that ramp into a one-way fade.
MultiEffect {
  maskEnabled: true
  maskThresholdMax: 0.5
  maskSpreadAtMax: 1.0
  maskSource: mask

  Image {
    id: mask
    anchors.fill: parent
    visible: false
    source: Qt.resolvedUrl("../../assets/masks/fade-vertical.svg")
    fillMode: Image.Stretch
  }
}
