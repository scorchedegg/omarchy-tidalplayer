import QtQuick
import qs.Commons
import qs.Ui

// Clickable artist credit pill: a round avatar and the artist name. Album
// headers and the artist page's Top Tracks heading use the same component, so
// the artwork and label sizes stay identical. The avatar sits 1 px from the
// pill's top, left and bottom edges. The pill carries a stained-glass wash
// from the artist image (GlassSurface); the avatar circle is untouched. Hover
// and press only tint the pill background; the avatar and text never change
// or underline.
Item {
  id: root

  property var svc: null
  property string artistId: ""
  property string artistName: ""
  // Fallback for callers that already hold an image (e.g. the artist hero)
  // before the shared cache has the id.
  property string artUrl: ""
  // Page content for the header variant, which layers a live blur of what
  // scrolls underneath on top of the artist-image wash.
  property Item blurSource: null
  // The wash is a little stronger than the collapsed player's 26 % so the
  // artist colour reads on the small pill; the page still shows through and
  // the label stays readable over bright artwork.
  property real imageOpacity: 0.34
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  // Header variant: a 36 px pill that sits beside the back button and uses
  // the header's button surfaces. The avatar keeps its 1 px inset, so the
  // image's left edge is the pill's left edge.
  property bool headerMode: false
  property real headerSize: 36
  // Caps the pill width in header mode; the label elides when it runs out.
  property real maxWidth: -1
  // Optional base layer under the tint, used by headerMode to match the
  // header's two-layer translucent buttons.
  property color baseSurface: "transparent"
  property color baseHoverSurface: "transparent"
  property color basePressedSurface: "transparent"
  property color surface: "transparent"
  property color hoverSurface: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
  property color pressedSurface: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.24)

  readonly property real artworkSize: root.headerMode ? root.headerSize - root.avatarInset * 2 : 22
  readonly property real fontPixelSize: root.headerMode
    ? (Style.font.subtitle || 13) : (Style.font.body || 12)
  // One shared token for the avatar inset, so top, left and bottom stay
  // identical at any theme spacing scale.
  readonly property real avatarInset: Style.space(1)
  readonly property real rightPadding: root.headerMode ? Style.space(12) : Style.space(8)

  readonly property string cachedArtUrl: {
    if (!root.svc || !root.svc.artistArtCache || !root.artistId) return ""
    return String(root.svc.artistArtCache[root.artistId] || "")
  }
  readonly property string displayArtUrl: root.cachedArtUrl !== "" ? root.cachedArtUrl : root.artUrl

  signal clicked(string id, string name)

  readonly property real naturalWidth: root.avatarInset + root.artworkSize
    + chipRow.spacing + chipLabel.implicitWidth + root.rightPadding
  implicitWidth: root.maxWidth > 0 ? Math.min(root.naturalWidth, root.maxWidth) : root.naturalWidth
  implicitHeight: root.headerMode ? root.headerSize : root.artworkSize + root.avatarInset * 2
  width: implicitWidth
  height: implicitHeight

  // Stained-glass wash from the artist image, like the collapsed player's
  // blurred artwork. The avatar circle stays untouched on top of it.
  GlassSurface {
    anchors.fill: parent
    radius: height / 2
    sourceItem: root.blurSource
    imageSource: root.displayArtUrl
    imageSourceSize: Qt.size(192, 192)
    imageOpacity: root.imageOpacity
    tintAlpha: 0.24
  }

  Rectangle {
    anchors.fill: parent
    radius: height / 2
    antialiasing: true
    color: chipMouse.pressed
      ? root.basePressedSurface
      : (chipMouse.containsMouse ? root.baseHoverSurface : root.baseSurface)
  }

  Rectangle {
    anchors.fill: parent
    radius: height / 2
    antialiasing: true
    color: chipMouse.pressed
      ? root.pressedSurface
      : (chipMouse.containsMouse ? root.hoverSurface : root.surface)
  }

  Row {
    id: chipRow
    anchors.left: parent.left
    anchors.leftMargin: root.avatarInset
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(6)

    Item {
      width: root.artworkSize
      height: root.artworkSize

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
      }

      RoundedImage {
        id: chipArt
        anchors.fill: parent
        radius: width / 2
        source: root.displayArtUrl
        sourceSize.width: 96
        sourceSize.height: 96
        visible: source !== ""
      }

      TidalLogo {
        anchors.centerIn: parent
        size: 11
        color: root.foreground
        faint: true
        visible: !chipArt.showingImage
      }
    }

    FadeText {
      id: chipLabel
      textFormat: Text.PlainText
      width: Math.max(0, root.implicitWidth - root.avatarInset - root.artworkSize
        - chipRow.spacing - root.rightPadding)
      height: root.artworkSize
      verticalAlignment: Text.AlignVCenter
      text: root.artistName
      color: root.foreground
      opacity: 0.9
      font.family: root.fontFamily
      font.pixelSize: root.fontPixelSize
      font.weight: Font.DemiBold
      maximumLineCount: 1
    }
  }

  MouseArea {
    id: chipMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked(root.artistId, root.artistName)
  }
}
