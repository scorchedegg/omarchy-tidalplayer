import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../components"
import "../lib/Design.js" as Design

// Full-page keyboard reference, opened from `?`. It lives in the face stack
// like every other page, so the floating header can step back out of it and
// the list scrolls with the same wheel/keyboard handling as the rest.
Item {
  id: root

  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  property real bottomInset: 0

  readonly property var sections: [
    {
      title: "Playback",
      items: [
        { keys: "Space", label: "Play / pause" },
        { keys: "<  >", label: "Previous / next track" },
        { keys: ",  .", label: "Seek back / forward 10 s" },
        { keys: "-  +", label: "Volume down / up" },
        { keys: "s", label: "Shuffle" },
        { keys: "r", label: "Repeat" }
      ]
    },
    {
      title: "Views",
      items: [
        { keys: "/", label: "Search" },
        { keys: "m", label: "Music" },
        { keys: "c", label: "Cast" },
        { keys: "q", label: "Play queue" },
        { keys: "y", label: "Lyrics" },
        { keys: "M", label: "Menu for this page" },
        { keys: "a  A", label: "Add / remove" },
        { keys: "S", label: "Share" },
        { keys: "e", label: "Edit playlist" },
        { keys: "R", label: "Go to radio" },
        { keys: "?", label: "This reference" }
      ]
    },
    {
      title: "Navigate",
      items: [
        { keys: "\u2191 \u2193  k j", label: "Move the selection" },
        { keys: "\u2190 \u2192  h l", label: "Move horizontally (pills, grids)" },
        { keys: "Enter", label: "Open row \u00B7 Play all (no selection)" },
        { keys: "\u21E7Enter", label: "Shuffle all (no selection)" },
        { keys: "PgUp PgDn", label: "Page through a list" },
        { keys: "Home End", label: "Jump to the first / last row" },
        { keys: "Esc", label: "Back \u00B7 Close panel" },
        { keys: "\u232B  \u21E7\u232B", label: "Back / forward one view" }
      ]
    },
    {
      title: "Playlist edit",
      items: [
        { keys: "\u21E7\u2191 \u21E7\u2193  K J", label: "Reorder selected track" },
        { keys: "Del", label: "Remove selected track" },
        { keys: "Ctrl+S", label: "Save changes" }
      ]
    }
  ]

  // Keyboard scrolling, routed from MiniPlayer while this face is active.
  function scrollBy(delta) {
    if (!shortcutsFlick) return
    var maxY = Math.max(0, shortcutsFlick.contentHeight - shortcutsFlick.height)
    var target = Math.max(0, Math.min(maxY, shortcutsFlick.contentY + delta * Style.space(40)))
    scrollHandler.reset()
    shortcutsFlick.contentY = target
  }

  function pageBy(direction) {
    if (!shortcutsFlick) return
    var maxY = Math.max(0, shortcutsFlick.contentHeight - shortcutsFlick.height)
    var target = Math.max(0, Math.min(maxY, shortcutsFlick.contentY + direction * shortcutsFlick.height * 0.8))
    scrollHandler.reset()
    shortcutsFlick.contentY = target
  }

  function homeEnd(toEnd) {
    if (!shortcutsFlick) return
    var target = toEnd ? Math.max(0, shortcutsFlick.contentHeight - shortcutsFlick.height) : 0
    scrollHandler.reset()
    shortcutsFlick.contentY = target
  }

  function scrollToTop() {
    scrollHandler.reset()
    if (shortcutsFlick.contentY !== 0) shortcutsFlick.contentY = 0
  }

  Flickable {
    id: shortcutsFlick
    anchors.fill: parent
    contentWidth: width
    contentHeight: Design.scrollContentHeight(mainCol.implicitHeight, shortcutsFlick.height, root.bottomInset, Style.space(16))
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick

    SmoothScrollHandler { id: scrollHandler }

    Column {
      id: mainCol
      width: shortcutsFlick.width - 2 * Design.pageGutter
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(14)

      // Clear the floating header.
      Item {
        width: parent.width
        height: Design.headerClearance
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "Keyboard shortcuts"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading + 4
        font.weight: Font.Bold
        horizontalAlignment: Text.AlignHCenter
      }

      Repeater {
        model: root.sections

        Column {
          required property var modelData
          width: mainCol.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            leftPadding: Style.space(4)
            text: modelData.title
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption || 11
            font.weight: Font.Bold
          }

          Rectangle {
            width: parent.width
            height: sectionRows.implicitHeight + Style.space(8)
            radius: Style.space(8)
            // A quiet theme-tinted card, never a default white Rectangle.
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)

            Column {
              id: sectionRows
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(4)
              spacing: 0

              Repeater {
                model: modelData.items

                Item {
                  required property var modelData
                  width: sectionRows.width
                  height: Style.space(32)

                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(6)
                    anchors.rightMargin: Style.space(6)
                    spacing: Style.space(12)

                    Rectangle {
                      Layout.preferredWidth: Math.max(Style.space(66), keyText.implicitWidth + Style.space(16))
                      Layout.preferredHeight: Style.space(22)
                      radius: Style.space(4)
                      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.11)

                      Text {
                        id: keyText
                        textFormat: Text.PlainText
                        anchors.centerIn: parent
                        text: modelData.keys
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption || 11
                        font.weight: Font.DemiBold
                      }
                    }

                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: modelData.label
                      color: root.foreground
                      opacity: 0.85
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall || 12
                      elide: Text.ElideRight
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
