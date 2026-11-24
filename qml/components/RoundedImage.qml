import QtQuick
import Qt5Compat.GraphicalEffects

Item {
  id: root

  property string source: ""
  property alias fillMode: img.fillMode
  property alias asynchronous: img.asynchronous
  property alias sourceSize: img.sourceSize
  property alias status: img.status
  property real radius: width / 2
  // Optional custom mask shape (e.g. the now-playing avatar crescent),
  // stretched to the item and used instead of the rounded rectangle. Masks
  // must not be nested: wrapping this component in another OpacityMask renders
  // it through an intermediate texture that is not refreshed when network art
  // arrives later, so the artwork stays blank until the item is rebuilt. Pass
  // a shape here instead of masking around the component.
  property string maskSource: ""
  property real borderWidth: 0
  property color borderColor: "transparent"
  // Subtle hover wash painted over the artwork, clipped by the same mask (and
  // therefore by a custom `maskSource` shape too). Animate `highlightOpacity`
  // rather than the colour so the fade is a plain number ramp.
  property color highlightColor: "white"
  property real highlightOpacity: 0

  // Artwork comes from the network. When the shell starts before the network
  // is reachable (e.g. right after login) Qt reports "Host not found" and
  // leaves the image in Error without retrying. Retry with a cache-busting
  // query (each attempt is a unique URL, since Qt caches failed loads) and
  // back off to one attempt every 30s until the art loads.
  property bool alive: true
  Component.onDestruction: {
    root.alive = false
    retryTimer.stop()
  }

  readonly property int maxRetries: 5
  property int retrySeq: 0
  // Keep the last decoded image visible while the next source loads. Without
  // this every track/artist change blanks the artwork for as long as the
  // network fetch takes.
  property string lastReadySource: ""
  // True while any artwork is on screen: the current source once decoded, or
  // the retained previous image during a track/artist change. Placeholders
  // bind to this instead of `status` so they never flash over visible art
  // while the next image loads.
  readonly property bool showingImage: img.status === Image.Ready
    || (lastReadySource !== "" && img.status !== Image.Ready)

  implicitWidth: 34
  implicitHeight: 34

  onSourceChanged: {
    retryTimer.stop()
    retrySeq = 0
    if (source === "") lastReadySource = ""
  }

  Image {
    id: img
    anchors.fill: parent
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    // Mipmap filtering gives a much cleaner downscale than plain bilinear,
    // which aliases small avatars and thumbnails (faces and sharp artwork
    // edges turn jagged). It has no effect at 1:1.
    mipmap: true
    visible: false
    source: {
      if (root.source === "" || root.retrySeq === 0) return root.source
      var remote = root.source.indexOf("http://") === 0 || root.source.indexOf("https://") === 0
      if (!remote) return root.source
      return root.source + (root.source.indexOf("?") === -1 ? "?" : "&") + "retry=" + root.retrySeq
    }
    onStatusChanged: {
      if (status === Image.Error) {
        if (root.retrySeq < root.maxRetries) {
          retryTimer.interval = Math.min(1000 * Math.pow(2, root.retrySeq), 30000)
          retryTimer.restart()
        } else {
          root.lastReadySource = ""
        }
      } else if (status === Image.Ready) {
        root.lastReadySource = String(img.source)
        retryTimer.stop()
      }
    }
  }

  // Previous image stays underneath until the new one is decoded, so a
  // track/artist change never drops to a blank sleeve.
  Image {
    id: previousImg
    anchors.fill: parent
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    mipmap: true
    cache: true
    visible: false
    source: root.lastReadySource
    sourceSize: img.sourceSize
  }

  Timer {
    id: retryTimer
    repeat: false
    onTriggered: if (root.alive) root.retrySeq++
  }

  Rectangle {
    id: mask
    anchors.fill: parent
    radius: root.radius
    color: "white"
    visible: false
    antialiasing: true
  }

  // Custom shape, stretched over the item. Only present when a caller asks for
  // one, so the rounded rectangle keeps its cheaper path.
  Image {
    id: shapeMask
    anchors.fill: parent
    visible: false
    fillMode: Image.Stretch
    source: root.maskSource
  }

  OpacityMask {
    anchors.fill: parent
    source: previousImg
    maskSource: root.maskSource !== "" ? shapeMask : mask
    cached: true
    visible: root.lastReadySource !== "" && img.status !== Image.Ready
  }

  OpacityMask {
    anchors.fill: parent
    source: img
    maskSource: root.maskSource !== "" ? shapeMask : mask
    cached: true
    visible: img.source !== "" && img.status === Image.Ready
  }

  Rectangle {
    id: highlightRect
    anchors.fill: parent
    color: root.highlightColor
    visible: false
    antialiasing: true
  }

  // Hover wash, clipped to the same shape as the artwork. `visible` follows the
  // opacity so no effect is run at rest.
  OpacityMask {
    anchors.fill: parent
    source: highlightRect
    maskSource: root.maskSource !== "" ? shapeMask : mask
    cached: true
    opacity: root.highlightOpacity
    visible: root.highlightOpacity > 0
  }

  // A Rectangle draws its border inside its bounds, so this stroke covers the
  // artwork's outermost pixel instead of losing its outer half to the artwork
  // mask. Masking it left the corner antialiasing multiplied twice and the
  // artwork read as poking out past a dim outline.
  Rectangle {
    id: outline
    anchors.fill: parent
    color: "transparent"
    radius: root.radius
    border.width: root.borderWidth
    border.color: root.borderColor
    antialiasing: true
    visible: root.borderWidth > 0
  }
}
