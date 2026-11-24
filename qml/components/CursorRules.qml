import QtQuick
import qs.Commons

// The keyboard cursor's marker on a full-bleed row.
//
// Rows run the panel's full width, so a closed border would draw two vertical
// lines down the panel's own edges. The cursor is marked with a rule above and
// below instead, which reads as a selected band across the panel; the playing
// row has no border at all, only its fill (a cursored playing row shows both).
Item {
  id: root

  property bool shown: false
  property color ruleColor: Color.accent

  visible: shown
  z: 1

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: 1
    color: root.ruleColor
  }

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: 1
    color: root.ruleColor
  }
}
