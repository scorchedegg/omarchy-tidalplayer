import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import qs.Commons
import qs.Ui

// Floating Save/Cancel dock shown while the playlist page is being edited.
// It replaces the collapsed player in the same bottom slot, so Save is always
// in reach however long the list is. The surface is lighter than the
// collapsed player's glass: the page beneath it blurs through, under a
// mostly-opaque tint.
Item {
  id: root

  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  property var blurSource: null

  signal saveRequested()
  signal cancelRequested()

  implicitHeight: 58
  width: parent.width

  // Double-layer shadow above the dock, following the CSS recipe
  // `0 .5px 3px #1014184d, 0 3px 12px #10141826`: a short, darker layer at
  // the seam under a longer, lighter halo.
  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.top
    height: 3
    gradient: Gradient {
      GradientStop { position: 0.00; color: "#00000000" }
      GradientStop { position: 1.00; color: "#0C000000" }
    }
  }

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.top
    height: 8
    gradient: Gradient {
      GradientStop { position: 0.000; color: "#00000000" }
      GradientStop { position: 1.000; color: "#1A000000" }
    }
  }

  Item {
    anchors.fill: parent
    clip: true

    // Page content beneath, blurred (the collapsed player's glass, held back
    // by the heavier tint below).
    ShaderEffectSource {
      id: backgroundSlice
      anchors.fill: parent
      sourceItem: root.blurSource
      sourceRect: root.blurSource
        ? Qt.rect(0, Math.max(0, root.blurSource.height - root.height), root.blurSource.width, Math.min(root.height, root.blurSource.height))
        : Qt.rect(0, 0, 1, 1)
      textureSize: Qt.size(Math.max(1, width), Math.max(1, height))
      live: root.visible && root.blurSource !== null
      visible: false
    }

    MultiEffect {
      anchors.fill: parent
      source: backgroundSlice
      blurEnabled: true
      blurMax: 48
      blur: 0.95
      autoPaddingEnabled: false
      visible: root.blurSource !== null
    }

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.82)
    }
  }

  // The bar is chrome: hover and clicks on its empty space must not fall
  // through to the rows underneath. The wheel is left alone so the page
  // still scrolls over the bar. Declared before the buttons so their targets
  // stay on top.
  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onClicked: function(mouse) { }
  }

  RowLayout {
    anchors.fill: parent
    anchors.leftMargin: 16
    anchors.rightMargin: 16
    spacing: 12

    // Save Pill Button
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: 40
      radius: 20
      color: saveMa.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.88) : root.foreground

      RowLayout {
        anchors.centerIn: parent
        spacing: 6

        SvgIcon {
          size: 16
          color: Color.popups.background
          source: Qt.resolvedUrl("../../assets/icons/check.svg")
        }

        Text {
          textFormat: Text.PlainText
          text: "Save"
          color: Color.popups.background
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall || 12
          font.weight: Font.Bold
        }
      }

      MouseArea {
        id: saveMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.saveRequested()
      }
    }

    // Cancel Pill Button
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: 40
      radius: 20
      color: cancelMa.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.09)

      RowLayout {
        anchors.centerIn: parent
        spacing: 6

        SvgIcon {
          size: 16
          color: root.foreground
          source: Qt.resolvedUrl("../../assets/icons/close.svg")
        }

        Text {
          textFormat: Text.PlainText
          text: "Cancel"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall || 12
          font.weight: Font.Bold
        }
      }

      MouseArea {
        id: cancelMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.cancelRequested()
      }
    }
  }
}
