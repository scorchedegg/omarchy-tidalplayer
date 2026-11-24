import QtQuick
import QtQuick.Effects
import QtMultimedia

// Album artwork that upgrades to TIDAL's animated cover when the release has
// one. Animated covers are short silent MP4 loops. The static cover stays
// underneath so it shows instantly while the loop buffers, and remains as the
// fallback when the video fails or animated artwork is disabled.
//
// `active` pauses the loop when the artwork is offscreen (popup closed, a
// sub-page is shown, lyrics are open) but keeps the buffered frame around so
// the transition back in resumes mid-loop instead of snapping to the static
// cover. Callers should keep it true through the duration of any fade-out for
// the same reason. `playing` pauses the loop so a paused track keeps showing
// its current frame instead of animating.
Item {
  id: root

  property string source: ""
  property string videoSource: ""
  property bool active: true
  property bool playing: true
  property real radius: width / 2
  property int borderWidth: 0
  property color borderColor: "transparent"

  property alias sourceSize: img.sourceSize
  property alias asynchronous: img.asynchronous

  readonly property alias status: img.status
  readonly property bool videoVisible: videoReady && !videoFailed && videoSource !== "" && active
  // True while either the static cover or the animated frame is on screen.
  readonly property bool showingArtwork: videoVisible || img.showingImage

  implicitWidth: 34
  implicitHeight: 34

  function syncPlayback() {
    if (!active) {
      // Pause rather than stop so the buffered frame stays on the sink. The
      // loop resumes on the same frame when the artwork comes back, which
      // keeps both the fade-out and the fade-in from snapping to the static
      // cover while the view is still visible.
      if (video.playbackState === MediaPlayer.PlayingState) video.pause()
      return
    }
    if (!playing) {
      if (video.playbackState === MediaPlayer.PlayingState) video.pause()
      return
    }
    if (videoSource === "" || videoFailed) return
    if (video.playbackState !== MediaPlayer.PlayingState) video.play()
  }

  property bool videoReady: false
  property bool videoFailed: false

  onVideoSourceChanged: {
    videoReady = false
    videoFailed = false
    if (root.videoSource !== "") {
      video.source = root.videoSource
    } else if (video.playbackState !== MediaPlayer.StoppedState) {
      // Leave the previous source in place but stop the decoder; assigning an
      // empty URL makes FFmpeg log spurious open failures.
      video.stop()
    }
    Qt.callLater(syncPlayback)
  }
  onActiveChanged: syncPlayback()
  onPlayingChanged: syncPlayback()

  RoundedImage {
    id: img
    anchors.fill: parent
    radius: root.radius
    borderWidth: 0
    source: root.source
  }

  Rectangle {
    id: videoMask
    anchors.fill: parent
    radius: root.radius
    color: "white"
    visible: false
    layer.enabled: root.videoSource !== ""
    antialiasing: true
  }

  VideoOutput {
    id: videoOut
    anchors.fill: parent
    fillMode: VideoOutput.PreserveAspectCrop
    visible: false
  }

  MultiEffect {
    anchors.fill: parent
    source: videoOut
    maskEnabled: true
    maskSource: videoMask
    visible: root.videoVisible
  }

  MediaPlayer {
    id: video
    loops: MediaPlayer.Infinite
    videoOutput: videoOut
    // No AudioOutput is assigned: animated covers stay silent.

    onPlaybackStateChanged: {
      if (playbackState === MediaPlayer.PlayingState
          && mediaStatus >= MediaPlayer.LoadedMedia
          && hasVideo !== false) {
        root.videoReady = true
      }
    }
    onMediaStatusChanged: {
      if (mediaStatus === MediaPlayer.InvalidMedia || mediaStatus === MediaPlayer.NoMedia) {
        root.videoReady = false
      } else if (playbackState === MediaPlayer.PlayingState
          && mediaStatus >= MediaPlayer.LoadedMedia
          && hasVideo !== false) {
        root.videoReady = true
      }
      root.syncPlayback()
    }
    onErrorOccurred: {
      root.videoFailed = true
      root.videoReady = false
    }
  }

  Rectangle {
    id: border
    anchors.fill: parent
    color: "transparent"
    radius: root.radius
    border.width: root.borderWidth
    border.color: root.borderColor
    visible: root.borderWidth > 0
    antialiasing: true
  }
}
