import QtQuick
import QtQuick.Layouts
import qs.Commons

// Rounded filter pills for an artist's discography, mirroring TIDAL's
// Discography tabs. The view owns the selected key and the option list, while
// `disabledKeys` marks buckets with no releases: those pills stay in place but
// dim, keep the default cursor and ignore clicks, so the row never reflows or
// opens an empty page.
// The row fills its parent like the search result tabs: each pill starts at its
// label width and the leftover space is shared, so the last pill ends flush.
// Inactive pills use the same translucent wash as the Shuffle pill on the
// artist hero; the active one inverts to the foreground colour.
Item {
  id: root

  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  // [{ key: "popular", label: "Popular" }, ...]
  property var options: []
  property string currentFilter: "popular"
  // Filter keys whose bucket is empty.
  property var disabledKeys: []

  signal filterSelected(string key)

  function isDisabled(key) {
    return root.disabledKeys.indexOf(key) >= 0
  }

  readonly property int pillHeight: 30
  // A plain Item keeps a zero height inside a Column, so reserve the row plus
  // the breathing room above and below it.
  implicitHeight: root.pillHeight + Style.space(16)
  height: implicitHeight

  RowLayout {
    id: pillRow
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.topMargin: Style.space(8)
    anchors.bottomMargin: Style.space(8)
    spacing: Style.space(8)

    Repeater {
      model: root.options

      Rectangle {
        id: pill
        required property var modelData
        readonly property bool active: root.currentFilter === pill.modelData.key
        readonly property bool disabled: root.isDisabled(pill.modelData.key)

        Layout.fillWidth: true
        Layout.preferredWidth: pillLabel.implicitWidth + Style.space(16)
        Layout.preferredHeight: root.pillHeight
        radius: height / 2
        color: pill.active
          ? root.foreground
          : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, pillMa.containsMouse && !pill.disabled ? 0.16 : 0.09)

        // An empty bucket dims its label without touching the pill's size.
        opacity: pill.disabled ? 0.4 : 1.0

        Text {
          id: pillLabel
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: pill.modelData.label
          color: pill.active ? Color.popups.background : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption || 11
          font.weight: Font.DemiBold
        }

        MouseArea {
          id: pillMa
          anchors.fill: parent
          hoverEnabled: true
          // `enabled: false` suppresses the click but still applies
          // `cursorShape`, so a disabled pill would keep the pointer hand.
          cursorShape: pill.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor
          onClicked: if (!pill.disabled) root.filterSelected(pill.modelData.key)
        }
      }
    }
  }
}
