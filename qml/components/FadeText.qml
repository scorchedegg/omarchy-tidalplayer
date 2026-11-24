import QtQuick

// Single-line text that dissolves into the background at the right edge
// instead of ending in an ellipsis. Every Text property works as usual;
// callers should leave elide alone. Centred and right-aligned text cannot
// truncate cleanly on the right, so those keep the standard ellipsis; use
// plain Text for multi-line text that should wrap.
Text {
  id: root

  textFormat: Text.PlainText
  clip: true

  readonly property bool overflowing: root.contentWidth > root.width + 0.5
  readonly property bool canFade: root.horizontalAlignment !== Text.AlignHCenter && root.horizontalAlignment !== Text.AlignRight

  elide: root.canFade ? Text.ElideNone : Text.ElideRight
  layer.enabled: root.canFade && root.overflowing && root.width > 0
  layer.effect: FadeEdge {}
}
