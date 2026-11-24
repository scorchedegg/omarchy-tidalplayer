import QtQuick
import QtQuick.Effects

// The right-edge fade used by layer.effect on an item whose content is
// clipped at its width. MultiEffect masks away both alpha 0 and alpha 1, so
// the mask keeps a sliver of alpha in the visible area; the threshold/spread
// pair turns its ramp into a one-way fade.
MultiEffect {
  maskEnabled: true
  maskThresholdMax: 0.5
  maskSpreadAtMax: 1.0
  maskSource: mask

  Image {
    id: mask
    anchors.fill: parent
    visible: false
    source: Qt.resolvedUrl("../../assets/masks/fade-right.svg")
    fillMode: Image.Stretch
  }
}
