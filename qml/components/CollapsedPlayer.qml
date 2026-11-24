import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import qs.Commons
import qs.Ui

// Collapsed bottom player docked on sub-pages:
// Spans full width from left to right edge, flush at bottom with 0 radius.
Item {
  id: root

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  property var blurSource: null

  // Same play/pause tooltip rule as the now-playing transport: a state flip
  // under a resting pointer must not raise the tooltip; suppressing it leaves
  // it down until the pointer leaves the button and comes back.
  readonly property bool playState: !!(root.svc && root.svc.playing)
  onPlayStateChanged: playTip.suppress()

  signal expandRequested()

  implicitHeight: 58
  width: parent.width

  // Double-layer shadow above the glass, following the CSS recipe
  // `0 .5px 3px #1014184d, 0 3px 12px #10141826`: a short, darker layer at
  // the seam under a longer, lighter halo. The per-stop alphas approximate
  // the two Gaussian falloffs so the pair reads as one soft shadow.
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
    id: bgContainer
    anchors.fill: parent
    clip: true

    // 1. Captured slice of page content underneath (blurry like frosted glass)
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

    // 2. Blurry album artwork background covering full width, centered vertically, semi-transparent
    Image {
      id: bgArtwork
      width: parent.width
      height: parent.width
      anchors.centerIn: parent
      source: root.svc ? root.svc.artUrl : ""
      fillMode: Image.PreserveAspectCrop
      sourceSize.width: 420
      sourceSize.height: 420
      asynchronous: true
      visible: false
      layer.enabled: true
    }

    MultiEffect {
      anchors.fill: bgArtwork
      source: bgArtwork
      blurEnabled: true
      blurMax: 56
      blur: 0.70
      autoPaddingEnabled: false
      opacity: 0.26
      visible: bgArtwork.status === Image.Ready && opacity > 0
    }

    // 3. Subtle glass tint overlay for text legibility and rich tone
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.24)
    }

    // Tap card to expand back to NowPlaying view; absorb right/middle clicks so
    // they never fall through to rows underneath.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        if (mouse.button === Qt.LeftButton) root.expandRequested()
      }
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: 16
      anchors.rightMargin: 16
      spacing: 12

      // Album Artwork Thumbnail
      Rectangle {
        Layout.preferredWidth: 40
        Layout.preferredHeight: 40
        radius: 2
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
        border.width: 1
        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

        RoundedImage {
          id: thumbImg
          anchors.fill: parent
          radius: 2
          borderWidth: 1
          borderColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
          source: root.svc ? root.svc.artUrl : ""
          sourceSize.width: 80
          sourceSize.height: 80
          visible: source !== ""
        }

        TidalLogo {
          anchors.centerIn: parent
          size: 18
          color: root.foreground
          faint: true
          visible: !thumbImg.showingImage
        }
      }

      // Track Title & Artist (clickable to expand)
      Column {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        spacing: 2
        clip: true

        FadeText {
          textFormat: Text.PlainText
          width: parent.width
          text: root.svc && root.svc.title !== "" ? root.svc.title : "Not Playing"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall || 12
          font.weight: Font.DemiBold
          maximumLineCount: 1
        }

        FadeText {
          textFormat: Text.PlainText
          width: parent.width
          text: root.svc ? root.svc.artist : ""
          color: root.foreground
          opacity: 0.8
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption || 10
          maximumLineCount: 1
          visible: text !== ""
        }
      }

      // Play / Pause Button
      Rectangle {
        Layout.preferredWidth: 36
        Layout.preferredHeight: 36
        radius: 18
        color: playMa.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15) : "transparent"

        SvgIcon {
          anchors.centerIn: parent
          size: 20
          color: root.foreground
          source: (root.svc && root.svc.playing)
            ? Qt.resolvedUrl("../../assets/icons/pause.svg")
            : Qt.resolvedUrl("../../assets/icons/play.svg")
        }

        MouseArea {
          id: playMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: if (root.svc) root.svc.playPause()
        }

        ButtonToolTip {
          id: playTip
          host: playMa
          text: root.playState ? "Pause" : "Play"
          fontFamily: root.fontFamily
        }
      }

      // Next Button
      Rectangle {
        Layout.preferredWidth: 36
        Layout.preferredHeight: 36
        radius: 18
        color: nextMa.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15) : "transparent"

        SvgIcon {
          anchors.centerIn: parent
          size: 20
          color: root.foreground
          source: Qt.resolvedUrl("../../assets/icons/next.svg")
        }

        MouseArea {
          id: nextMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: if (root.svc) root.svc.next()
        }

        ButtonToolTip {
          host: nextMa
          text: "Next"
          fontFamily: root.fontFamily
        }
      }
    }
  }
}
