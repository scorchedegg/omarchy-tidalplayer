import QtQuick

Item {
  id: root

  property var artists: []
  property string fallbackText: ""
  property string fallbackArtistId: ""
  property color foreground: "white"
  property string fontFamily: ""
  property real fontPixelSize: 12
  property real textOpacity: 1.0
  property bool bold: false
  // When off, the names are plain text: no hover, no underline, no click,
  // no pointer hand. `enabled: false` alone is not enough — a disabled
  // MouseArea keeps its hover and cursor (see ReleaseFilters.qml).
  property bool interactive: true

  readonly property var entries: {
    var credits = Array.isArray(root.artists) ? root.artists.filter(function(artist) {
      return artist && String(artist.name || "").trim() !== ""
    }) : []
    if (credits.length > 0) return credits
    return String(root.fallbackText || "").split(/\s*,\s*/).filter(function(name) {
      return name.trim() !== ""
    }).map(function(name, index) {
      return { id: index === 0 ? root.fallbackArtistId : "", name: name }
    })
  }

  signal artistClicked(string id, string name)

  // Natural width of the whole credit run; the row fades at the right once
  // the assigned width is narrower than this. TextMetrics under-measures the
  // rendered run by a fraction, so only fade once the width is genuinely
  // below the natural width.
  readonly property real naturalWidth: fullTextMetrics.advanceWidth
  readonly property bool clamped: width < naturalWidth
  implicitWidth: naturalWidth
  implicitHeight: artistTextMetrics.height
  height: implicitHeight
  clip: true

  TextMetrics {
    id: fullTextMetrics
    text: root.entries.map(function(entry) {
      return String(entry.name || "")
    }).join(", ")
    font.family: root.fontFamily
    font.pixelSize: root.fontPixelSize
    font.weight: root.bold ? Font.DemiBold : Font.Normal
  }

  TextMetrics {
    id: artistTextMetrics
    text: "Ag"
    font.family: root.fontFamily
    font.pixelSize: root.fontPixelSize
    font.weight: root.bold ? Font.DemiBold : Font.Normal
  }

  Row {
    id: creditRow
    width: root.width
    height: parent.height
    clip: true
    // The row clips at its width, so a long credit run needs the fade at the
    // row edge, not only on individually clamped names.
    layer.enabled: root.clamped && root.width > 0
    layer.effect: FadeEdge {}

    Repeater {
      model: root.entries

      delegate: Item {
        id: creditItem
        required property var modelData
        required property int index

        readonly property bool hasComma: creditItem.index < root.entries.length - 1
        readonly property real commaWidth: hasComma ? commaText.implicitWidth : 0
        width: creditText.width + commaWidth
        height: parent.height

        Text {
          id: creditText
          textFormat: Text.PlainText
          text: String(creditItem.modelData.name || "")
          width: implicitWidth
          anchors.verticalCenter: parent.verticalCenter
          color: root.foreground
          opacity: root.textOpacity
          font.family: root.fontFamily
          font.pixelSize: root.fontPixelSize
          font.weight: root.bold ? Font.DemiBold : Font.Normal
          font.underline: root.interactive && creditMouse.containsMouse
          maximumLineCount: 1

          MouseArea {
            id: creditMouse
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            // Keep clicks inside the visible row; the name itself is laid out
            // at its natural width so the row fade has glyphs to dissolve.
            width: Math.min(creditText.width, Math.max(0, root.width - creditItem.x))
            height: parent.height
            acceptedButtons: root.interactive ? Qt.LeftButton : Qt.NoButton
            hoverEnabled: root.interactive
            cursorShape: root.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: {
              if (!root.interactive) return
              root.artistClicked(String(creditItem.modelData.id || ""), String(creditItem.modelData.name || ""))
            }
          }
        }

        Text {
          id: commaText
          textFormat: Text.PlainText
          text: creditItem.hasComma ? ", " : ""
          anchors.left: creditText.right
          anchors.verticalCenter: parent.verticalCenter
          color: root.foreground
          opacity: root.textOpacity
          font.family: root.fontFamily
          font.pixelSize: root.fontPixelSize
          font.weight: root.bold ? Font.DemiBold : Font.Normal
        }
      }
    }
  }
}
