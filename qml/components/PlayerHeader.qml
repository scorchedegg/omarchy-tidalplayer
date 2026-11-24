import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "../lib/Cast.js" as Cast
import "../lib/Design.js" as Design
import "../lib/Format.js" as Format

Item {
  id: root

  property bool alive: true
  Component.onDestruction: root.alive = false

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily
  // Page content captured by the floating buttons' glass. MiniPlayer passes
  // its view container; when null the buttons keep their flat surfaces.
  property Item blurSource: null
  property string currentFace: "nowPlaying"
  property string artistArtUrl: ""
  property var currentArtists: []
  property var artistArtCache: ({})
  property bool collectionsActive: false
  // Album pages carry a share button and a favourite heart, right of the
  // search seat. Playlist pages keep their actions in the row below the
  // Play/Shuffle pills instead.
  property bool showEntityButtons: false
  property bool entityFavorite: false
  property bool entityCanFavorite: false
  // Cast button: only on the default face, only while a device exists, and
  // accent-coloured while a session is active. The glyph also follows the
  // active device's class (TV, speaker group, speaker), so the button shows
  // where the audio is going rather than one generic Cast mark.
  property bool castAvailable: false
  property bool castActive: false
  property string castDeviceKind: ""
  property string castDeviceName: ""
  // Artist credit pill shown after the back button on artist sub-pages
  // (Top Tracks, Albums, Singles), sized like the header's round buttons.
  property bool showArtistChip: false
  property string headerArtistId: ""
  property string headerArtistName: ""
  property string headerArtistArtUrl: ""

  // Faces whose content reaches under the floating header (artwork faces,
  // collections, queue, top tracks, releases) get glass buttons that sample
  // the page. Lists, search and login start their content below the header,
  // so there is nothing to blur and the flat surface is enough.
  readonly property bool glassButtons: root.blurSource !== null
    && root.currentFace !== "collectionList"
    && root.currentFace !== "search"
    && root.currentFace !== "login"
  // The buttons sit on two surfaces. Over artwork they are the theme
  // background; over flat pages they match the now-playing footer's action
  // buttons (an 8 % foreground wash over the page).
  // `headerArtworkProgress` comes from the visible view, so scrolling a hero
  // away fades the buttons smoothly to the flat surface.
  //
  // Opacity matches the collapsed player's net transparency. Its glass is a
  // 26 % artwork wash over the page blur plus a 24 % tint, so 74 % x 76 % =
  // 56 % of the page stays visible. A button without the artwork wash gets
  // the equivalent 44 % tint.
  //
  // Because the surface is drawn at `glassTintAlpha`, the hue carries the
  // footer wash pre-divided by that alpha: 44 % of an 18.2 % foreground mix
  // over the page lands on the footer's 8 % foreground composite.
  property real headerArtworkProgress: 0
  Behavior on headerArtworkProgress { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

  readonly property real glassTintAlpha: 0.44
  readonly property color artworkHeaderSurface: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, root.glassTintAlpha)
  readonly property color flatHeaderSurface: {
    var bg = Color.popups.background
    var fg = root.foreground
    var fgFraction = 0.08 / root.glassTintAlpha
    return Qt.rgba(
      bg.r + (fg.r - bg.r) * fgFraction,
      bg.g + (fg.g - bg.g) * fgFraction,
      bg.b + (fg.b - bg.b) * fgFraction,
      root.glassTintAlpha)
  }
  readonly property real flatProgress: 1 - Math.max(0, Math.min(1, root.headerArtworkProgress))
  readonly property color headerSurface: Qt.rgba(
    root.artworkHeaderSurface.r + (root.flatHeaderSurface.r - root.artworkHeaderSurface.r) * root.flatProgress,
    root.artworkHeaderSurface.g + (root.flatHeaderSurface.g - root.artworkHeaderSurface.g) * root.flatProgress,
    root.artworkHeaderSurface.b + (root.flatHeaderSurface.b - root.artworkHeaderSurface.b) * root.flatProgress,
    root.artworkHeaderSurface.a + (root.flatHeaderSurface.a - root.artworkHeaderSurface.a) * root.flatProgress)
  readonly property color headerHoverTint: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

  // Two-layer surfaces: the base rectangle carries the surface colour (the
  // GlassSurface carries it on glass faces), and the tint rectangle above it
  // is see-through at rest and lifts on hover.
  readonly property color buttonBaseSurface: root.glassButtons ? "transparent" : root.headerSurface
  readonly property color buttonTintSurface: "transparent"
  readonly property color buttonTintHoverSurface: root.headerHoverTint

  readonly property bool hasTrack: svc ? (svc.title !== "" || svc.playing) : false

  readonly property var displayArtists: {
    if (root.currentArtists && Array.isArray(root.currentArtists) && root.currentArtists.length > 0) {
      return root.currentArtists
    }
    if (root.svc && root.svc.currentArtists && Array.isArray(root.svc.currentArtists) && root.svc.currentArtists.length > 0) {
      return root.svc.currentArtists
    }
    if (root.svc && (root.svc.artistId || root.svc.artist)) {
      return [{ id: root.svc.artistId || "", name: root.svc.artist || "Artist" }]
    }
    return [{ id: "", name: "Artist" }]
  }

  // Last avatar URL shown per circle. The Repeater's delegates are rebuilt on
  // track changes, so the memory lives on the header: a circle keeps its
  // previous artist image while the next artist's art is still being looked
  // up, instead of flashing the TIDAL glyph on every skip.
  property var lastArtistArtUrls: ({})

  function rememberArtistArtUrl(index, url) {
    if (root.lastArtistArtUrls[index] === url) return
    var next = Object.assign({}, root.lastArtistArtUrls)
    next[index] = url
    root.lastArtistArtUrls = next
  }

  // Queue page: the playing-from summary sits in the top bar, between the
  // back button and the collections button, instead of scrolling with the
  // queue. It always shows the source, track count and total queue time.
  readonly property string queueBarSource: (root.svc && root.svc.playingContext) ? root.svc.playingContext : "Top Tracks"
  readonly property int queueBarTrackCount: (root.svc && root.svc.queueTracks) ? root.svc.queueTracks.length : 0
  readonly property int queueBarDuration: {
    var tracks = (root.svc && root.svc.queueTracks) ? root.svc.queueTracks : []
    var total = 0
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i] && tracks[i].duration) total += tracks[i].duration
    }
    return total
  }

  signal backClicked()
  signal artistSelected(string id, string name, string artUrl)
  signal headerArtistClicked(string id, string name)
  signal collectionsClicked()
  signal castClicked()
  signal searchClicked()
  signal entityFavoriteClicked()
  signal entityShareClicked()
  signal queueBarClicked()
  // Down from the search field enters the results list.
  signal searchDownRequested()

  property string searchQuery: ""

  function setSearchQuery(q) {
    if (headerSearchInput) {
      headerSearchInput.text = q || ""
    }
    root.searchQuery = q || ""
  }

  function focusSearch() {
    if (headerSearchInput) {
      headerSearchInput.forceActiveFocus()
    }
  }

  // Animated open, used only when search is opened from the button/IPC.
  function animateSearchIn() {
    searchExpand.restart()
  }

  // Coming back from a result page shows the search bar as it was left,
  // without replaying the expand animation.
  function showSearchNow() {
    searchExpand.stop()
    searchBox.reveal = 1
  }

  onCurrentFaceChanged: {
    if (root.currentFace === "search") {
      Qt.callLater(function() {
        if (root && root.alive && root.currentFace === "search") root.focusSearch()
      })
    } else {
      searchExpand.stop()
      searchBox.reveal = 0
    }
  }

  implicitHeight: 52
  width: parent.width

  // Left Slot: Circular Artist Avatar(s) (on NowPlaying) OR Unclickable Logo (on idle Collections) OR Back Button (on sub-pages)
  Item {
    id: leftSlot
    anchors.left: parent.left
    anchors.leftMargin: Design.pageGutter
    anchors.top: parent.top
    anchors.topMargin: 16
    width: root.currentFace === "nowPlaying" ? avatarRow.implicitWidth : 36
    height: 36

    // 1. Unclickable Tidal Logo diamond (when nothing playing on collections page)
    Item {
      width: 36
      height: 36
      visible: root.currentFace === "collections" && !root.hasTrack

      TidalLogo {
        anchors.centerIn: parent
        size: 22
        color: root.foreground
        opacity: 0.95
      }
    }

    // 2. Back Button (sub-pages or collections when playing)
    Rectangle {
      width: 36
      height: 36
      radius: 18
      antialiasing: true
      color: root.buttonBaseSurface
      visible: root.currentFace !== "nowPlaying" && !(root.currentFace === "collections" && !root.hasTrack)

      GlassSurface {
        anchors.fill: parent
        radius: 18
        sourceItem: root.glassButtons ? root.blurSource : null
        tintColor: root.headerSurface
        tintAlpha: root.headerSurface.a
      }

      Rectangle {
        anchors.fill: parent
        radius: parent.radius
        antialiasing: true
        color: backMa.containsMouse ? root.buttonTintHoverSurface : root.buttonTintSurface
      }

      SvgIcon {
        anchors.centerIn: parent
        size: 18
        color: root.foreground
        source: Qt.resolvedUrl("../../assets/icons/back.svg")
      }

      MouseArea {
        id: backMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.backClicked()
      }

      ButtonToolTip {
        host: backMa
        text: "Back"
        fontFamily: root.fontFamily
      }
    }

    // 3. Circular Artist Avatars (Now Playing view: one circle per artist side by side)
    //
    // The credits stack the way TIDAL draws them: the circles overlap, and
    // the leftmost one sits on top. Each circle that has a visible left
    // neighbour is therefore cut to a crescent (`avatar-crescent.svg`) rather
    // than letting a later circle paint over an earlier one, and the mask
    // keeps a 3 px gap so the page shows through the seam instead of the two
    // covers merging.
    Row {
      id: avatarRow
      readonly property real avatarDiameter: 36
      // A quarter of the diameter: enough that the pair reads as one stacked
      // credit, small enough that the right-hand cover stays legible in a
      // 52 px header.
      readonly property real avatarOverlap: Math.round(avatarRow.avatarDiameter * 0.25)
      spacing: -avatarRow.avatarOverlap
      visible: root.currentFace === "nowPlaying"

      // Fixed slots rather than a Repeater over the artist array: a changing
      // model destroys and recreates every delegate on each track change,
      // which blanks the whole row for a frame. These delegates persist, so
      // an avatar can keep its previous image while the artist swaps.
      Repeater {
        id: avatarSlots
        model: 4

        Item {
          id: artistCircle
          required property int index

          width: avatarRow.avatarDiameter
          height: avatarRow.avatarDiameter
          // Descending, so the left circle draws over its right neighbour.
          z: 4 - index

          // A circle is overlapped once some earlier slot is showing: the Row
          // skips invisible slots, so the nearest visible one always sits
          // directly to the left.
          readonly property bool overlapped: {
            for (var i = artistCircle.index - 1; i >= 0; i--) {
              var sibling = avatarSlots.itemAt(i)
              if (sibling && sibling.visible) return true
            }
            return false
          }

          readonly property var artist: root.displayArtists.length > index ? root.displayArtists[index] : null
          readonly property string artistId: artist ? String(artist.id || "") : ""
          readonly property string artistName: artist ? String(artist.name || "Artist") : ""

          // A newly appearing artist has no previous image to inherit, so the
          // circle waits for its avatar instead of showing a placeholder.
          // Slots that already showed a circle keep it while the next image
          // loads, because `showingImage` covers the retained image too.
          visible: artist !== null && avatarImg.showingImage

          readonly property string circleArtUrl: {
            var aId = artistCircle.artistId
            if (aId && root.artistArtCache && root.artistArtCache[aId]) {
              return root.artistArtCache[aId]
            }
            if (aId && root.svc && root.svc.artistArtCache && root.svc.artistArtCache[aId]) {
              return root.svc.artistArtCache[aId]
            }
            if (artistCircle.index === 0 && root.artistArtUrl) {
              return root.artistArtUrl
            }
            return ""
          }

          // A cached "" is a finished lookup that found no image; a missing
          // key means the request is still in flight. Only the former may
          // clear the circle.
          readonly property bool artistArtResolved: {
            if (artistCircle.circleArtUrl !== "") return true
            var aId = artistCircle.artistId
            if (aId === "") return true
            if (root.artistArtCache && root.artistArtCache[aId] !== undefined) return true
            if (root.svc && root.svc.artistArtCache && root.svc.artistArtCache[aId] !== undefined) return true
            return false
          }

          readonly property string displayArtUrl: {
            if (artistCircle.circleArtUrl !== "") return artistCircle.circleArtUrl
            if (artistCircle.artistArtResolved) return ""
            return String(root.lastArtistArtUrls[artistCircle.index] || "")
          }

          onCircleArtUrlChanged: {
            if (circleArtUrl !== "") root.rememberArtistArtUrl(index, circleArtUrl)
          }
          onArtistArtResolvedChanged: {
            if (artistArtResolved) root.rememberArtistArtUrl(index, circleArtUrl)
          }
          Component.onCompleted: {
            if (artistArtResolved || circleArtUrl !== "") root.rememberArtistArtUrl(index, circleArtUrl)
          }

          // The avatar carries the crescent itself (`RoundedImage.maskSource`)
          // rather than being wrapped in an OpacityMask: an outer mask renders
          // the component through a texture that is never refreshed when
          // network art arrives, which left the circle blank until the panel
          // was rebuilt. Hover is a wash over the artwork for the same reason —
          // it is clipped by the same mask, so it follows the crescent instead
          // of outlining the whole disc.
          RoundedImage {
            id: avatarImg
            anchors.fill: parent
            radius: avatarRow.avatarDiameter / 2
            // Stretched to the slot, so the crescent's authored 36 px geometry
            // tracks `avatarDiameter` and its bite tracks `avatarOverlap`.
            maskSource: artistCircle.overlapped
              ? Qt.resolvedUrl("../../assets/masks/avatar-crescent.svg") : ""
            source: artistCircle.displayArtUrl
            sourceSize.width: 72
            sourceSize.height: 72
            visible: artistCircle.displayArtUrl !== ""
            // A light wash over the whole cover rather than a ring, which read
            // as an outline when the circle is only 36 px across.
            highlightColor: root.foreground
            highlightOpacity: circleMa.containsMouse ? 0.18 : 0
          }

          MouseArea {
            id: circleMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.artistSelected(artistCircle.artistId, artistCircle.artistName, artistCircle.circleArtUrl)
            }
          }

          ButtonToolTip {
            host: circleMa
            text: artistCircle.artistName
            fontFamily: root.fontFamily
          }
        }
      }
    }
  }

  // Artist credit on artist sub-pages (Top Tracks / Albums / Singles), after
  // the back button. The 36 px pill matches the header's round buttons,
  // including their two-layer translucent surfaces; the avatar keeps a 1 px
  // inset and the label elides before the right-hand buttons.
  ArtistChip {
    id: headerArtistChip
    anchors.left: leftSlot.right
    anchors.leftMargin: 8
    anchors.top: parent.top
    anchors.topMargin: 16
    headerMode: true
    headerSize: 36
    svc: root.svc
    artistId: root.headerArtistId
    artistName: root.headerArtistName
    artUrl: root.headerArtistArtUrl
    // Artist image wash plus the page blur, matching the collapsed player.
    // The flat page behind this chip mutes the wash, so it runs a little
    // stronger than the album chips (which sit over a bright cover backdrop).
    blurSource: root.glassButtons ? root.blurSource : null
    imageOpacity: 0.45
    foreground: root.foreground
    fontFamily: root.fontFamily
    baseSurface: root.buttonBaseSurface
    baseHoverSurface: root.buttonBaseSurface
    basePressedSurface: root.buttonBaseSurface
    surface: root.buttonTintSurface
    hoverSurface: root.buttonTintHoverSurface
    pressedSurface: root.buttonTintHoverSurface
    maxWidth: Math.max(0, rightSlot.x - Style.space(8)
      - (leftSlot.x + leftSlot.width + 8))
    visible: root.showArtistChip && root.headerArtistName !== ""
    onClicked: function(id, name) { root.headerArtistClicked(id, name) }
  }

  // Center Slot: Circular search button that expands into the search bar on
  // the search face. Collapsed, it occupies the seat left for it in the
  // right-hand button row.
  Rectangle {
    id: searchBox
    anchors.top: parent.top
    anchors.topMargin: 16
    height: 36
    radius: 18
    antialiasing: true
    clip: true
    z: 1

    readonly property bool expanded: root.currentFace === "search"
    // Collapsed width matches the button row slot; expanded it spans from the
    // back button to the same right margin the row uses.
    readonly property real collapsedX: parent.width - 52
    readonly property real expandedX: leftSlot.x + leftSlot.width + 8

    // 0 = collapsed button, 1 = expanded bar. Only expansion is animated;
    // `onCurrentFaceChanged` snaps it back so leaving the page is instant.
    property real reveal: 0

    x: collapsedX + (expandedX - collapsedX) * reveal
    width: expanded ? parent.width - x - 16 : 36
    visible: root.currentFace !== "login"
    color: root.buttonBaseSurface

    GlassSurface {
      anchors.fill: parent
      radius: 18
      sourceItem: root.glassButtons ? root.blurSource : null
      tintColor: root.headerSurface
      tintAlpha: root.headerSurface.a
    }

    Rectangle {
      anchors.fill: parent
      radius: parent.radius
      antialiasing: true
      color: searchBox.expanded
        ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
        : (searchMa.containsMouse ? root.buttonTintHoverSurface : root.buttonTintSurface)
    }

    Component.onCompleted: reveal = expanded ? 1 : 0

    NumberAnimation {
      id: searchExpand
      target: searchBox
      property: "reveal"
      from: 0
      to: 1
      duration: Design.base
      easing.type: Easing.OutCubic
    }

    MouseArea {
      id: searchMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: searchBox.expanded ? Qt.IBeamCursor : Qt.PointingHandCursor
      onClicked: {
        if (searchBox.expanded) root.focusSearch()
        else root.searchClicked()
      }
    }

    ButtonToolTip {
      host: searchMa
      allowed: !searchBox.expanded
      text: "Search"
      fontFamily: root.fontFamily
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: searchBox.expanded ? 12 : 9
      anchors.rightMargin: 10
      spacing: 8

      SvgIcon {
        Layout.alignment: Qt.AlignVCenter
        size: 18
        color: root.foreground
        source: Qt.resolvedUrl("../../assets/icons/search.svg")
      }

      TextInput {
        id: headerSearchInput
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        font.family: root.fontFamily
        font.pixelSize: 13
        color: root.foreground
        clip: true
        verticalAlignment: TextInput.AlignVCenter
        selectByMouse: true
        activeFocusOnPress: true
        enabled: searchBox.expanded
        opacity: searchBox.reveal
        onTextChanged: root.searchQuery = text

        Text {
          textFormat: Text.PlainText
          text: "Search anything..."
          color: root.foreground
          opacity: 0.4
          font.family: headerSearchInput.font.family
          font.pixelSize: headerSearchInput.font.pixelSize
          visible: !headerSearchInput.text && !headerSearchInput.inputMethodComposing
          anchors.verticalCenter: parent.verticalCenter
        }

        onAccepted: {
          if (text.trim() && root.svc) {
            root.svc.addRecentSearch(text.trim())
          }
        }

        Keys.onDownPressed: function(event) {
          root.searchDownRequested()
          event.accepted = true
        }
      }

      // Clear Button
      Rectangle {
        Layout.preferredWidth: 24
        Layout.preferredHeight: 24
        radius: 12
        opacity: searchBox.reveal
        color: clearMa.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15) : "transparent"
        visible: headerSearchInput.text !== ""

        SvgIcon {
          anchors.centerIn: parent
          size: 14
          color: root.foreground
          opacity: 0.7
          source: Qt.resolvedUrl("../../assets/icons/close.svg")
        }

        MouseArea {
          id: clearMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.setSearchQuery("")
          }
        }

        ButtonToolTip {
          host: clearMa
          text: "Clear search"
          fontFamily: root.fontFamily
        }
      }
    }
  }

  // Right Slot: Share / Favourite / Collections Buttons. The search
  // button is the collapsed search box in the center slot; on the search face
  // it fades out beneath the expanding bar.
  Row {
    id: rightSlot
    anchors.right: parent.right
    anchors.rightMargin: Design.pageGutter
    anchors.top: parent.top
    anchors.topMargin: 16
    spacing: 8
    visible: root.currentFace !== "login"

    // Share Button for the current album
    Rectangle {
      id: entityShareBtn
      width: 36
      height: 36
      radius: 18
      antialiasing: true
      visible: root.showEntityButtons
      opacity: 1 - searchBox.reveal
      color: root.buttonBaseSurface

      GlassSurface {
        anchors.fill: parent
        radius: 18
        sourceItem: root.glassButtons ? root.blurSource : null
        tintColor: root.headerSurface
        tintAlpha: root.headerSurface.a
      }

      Rectangle {
        anchors.fill: parent
        radius: parent.radius
        antialiasing: true
        color: entityShareMa.containsMouse ? root.buttonTintHoverSurface : root.buttonTintSurface
      }

      SvgIcon {
        anchors.centerIn: parent
        size: 18
        color: root.foreground
        source: Qt.resolvedUrl("../../assets/icons/share.svg")
      }

      MouseArea {
        id: entityShareMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        enabled: root.currentFace !== "search"
        onClicked: root.entityShareClicked()
      }

      ButtonToolTip {
        host: entityShareMa
        text: "Share"
        fontFamily: root.fontFamily
      }
    }

    // Favourite (heart) Button for the current album
    Rectangle {
      id: favBtn
      width: 36
      height: 36
      radius: 18
      antialiasing: true
      visible: root.showEntityButtons && root.entityCanFavorite
      opacity: 1 - searchBox.reveal
      color: root.buttonBaseSurface

      GlassSurface {
        anchors.fill: parent
        radius: 18
        sourceItem: root.glassButtons ? root.blurSource : null
        tintColor: root.headerSurface
        tintAlpha: root.headerSurface.a
      }

      Rectangle {
        anchors.fill: parent
        radius: parent.radius
        antialiasing: true
        color: favBtnMa.containsMouse ? root.buttonTintHoverSurface : root.buttonTintSurface
      }

      SvgIcon {
        anchors.centerIn: parent
        size: 18
        color: root.foreground
        source: root.entityFavorite
          ? Qt.resolvedUrl("../../assets/icons/heart-filled.svg")
          : Qt.resolvedUrl("../../assets/icons/heart.svg")
      }

      MouseArea {
        id: favBtnMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        enabled: root.currentFace !== "search"
        onClicked: root.entityFavoriteClicked()
      }

      ButtonToolTip {
        host: favBtnMa
        text: root.entityFavorite ? "Remove from albums" : "Add to albums"
        fontFamily: root.fontFamily
      }
    }

    // Cast Button. Sits left of Collections and is only present while the
    // daemon has discovered at least one device (or a session is active).
    Rectangle {
      id: castBtn
      width: 36
      height: 36
      radius: 18
      antialiasing: true
      visible: root.castAvailable && root.currentFace === "nowPlaying"
      opacity: 1 - searchBox.reveal
      color: root.buttonBaseSurface

      GlassSurface {
        anchors.fill: parent
        radius: 18
        sourceItem: root.glassButtons ? root.blurSource : null
        tintColor: root.headerSurface
        tintAlpha: root.headerSurface.a
      }

      Rectangle {
        anchors.fill: parent
        radius: parent.radius
        antialiasing: true
        color: root.castActive
          ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.25)
          : (castMa.containsMouse ? root.buttonTintHoverSurface : root.buttonTintSurface)
      }

      SvgIcon {
        anchors.centerIn: parent
        size: 18
        color: root.castActive ? Color.accent : root.foreground
        source: Qt.resolvedUrl("../../assets/icons/" + Cast.iconForKind(root.castDeviceKind))
      }

      MouseArea {
        id: castMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        enabled: root.currentFace !== "search"
        onClicked: root.castClicked()
      }

      ButtonToolTip {
        host: castMa
        text: root.castActive
          ? ("Casting to " + (root.castDeviceName !== "" ? root.castDeviceName : "a device"))
          : "Cast to a device"
        fontFamily: root.fontFamily
      }
    }

    // Collections (Library) Button
    Rectangle {
      id: colBtn
      width: 36
      height: 36
      radius: 18
      antialiasing: true
      opacity: 1 - searchBox.reveal
      color: root.buttonBaseSurface

      GlassSurface {
        anchors.fill: parent
        radius: 18
        sourceItem: root.glassButtons ? root.blurSource : null
        tintColor: root.headerSurface
        tintAlpha: root.headerSurface.a
      }

      Rectangle {
        anchors.fill: parent
        radius: parent.radius
        antialiasing: true
        color: root.collectionsActive
          ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
          : (colMa.containsMouse ? root.buttonTintHoverSurface : root.buttonTintSurface)
      }

      SvgIcon {
        anchors.centerIn: parent
        size: 18
        color: root.foreground
        source: Qt.resolvedUrl("../../assets/icons/music.svg")
      }

      MouseArea {
        id: colMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        enabled: root.currentFace !== "search"
        onClicked: root.collectionsClicked()
      }

      ButtonToolTip {
        host: colMa
        text: "Music"
        fontFamily: root.fontFamily
      }
    }

    // Seat for the collapsed search button, so the collections button keeps
    // its position while the search bar expands over it.
    Item {
      width: 36
      height: 36
    }
  }

  // Queue summary pill: sits in the top bar between the back button and the
  // collections button, rounded like the buttons. Clicking it opens the
  // context the queue was started from.
  Rectangle {
    id: queueBar
    anchors.left: leftSlot.right
    anchors.leftMargin: 8
    anchors.right: rightSlot.left
    anchors.rightMargin: 8
    anchors.top: parent.top
    anchors.topMargin: 16
    height: 36
    radius: 18
    antialiasing: true
    clip: true
    visible: root.currentFace === "queue" && root.queueBarTrackCount > 0
    color: root.buttonBaseSurface

    GlassSurface {
      anchors.fill: parent
      radius: 18
      sourceItem: root.glassButtons ? root.blurSource : null
      tintColor: root.headerSurface
      tintAlpha: root.headerSurface.a
    }

    Rectangle {
      anchors.fill: parent
      radius: parent.radius
      antialiasing: true
      color: queueBarMa.containsMouse ? root.buttonTintHoverSurface : root.buttonTintSurface
    }

    // Two independent rows rather than two fixed columns: the source name on
    // the bottom row can run all the way to the playback time before it
    // elides, without being constrained by the track count above it.
    Column {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: 12
      anchors.rightMargin: 12
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      RowLayout {
        width: parent.width
        spacing: 8

        Text {
          textFormat: Text.PlainText
          text: "Playing from"
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: 8
          elide: Text.ElideRight
          Layout.fillWidth: true
        }

        Text {
          textFormat: Text.PlainText
          text: root.queueBarTrackCount + (root.queueBarTrackCount === 1 ? " track" : " tracks")
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: 9
          Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
        }
      }

      RowLayout {
        width: parent.width
        spacing: 8

        FadeText {
          textFormat: Text.PlainText
          text: root.queueBarSource
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: 10
          font.weight: Font.DemiBold
          Layout.fillWidth: true
        }

        Text {
          textFormat: Text.PlainText
          text: root.queueBarDuration > 0 ? Format.formatDuration(root.queueBarDuration) : ""
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: 9
          Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
          visible: text !== ""
        }
      }
    }

    MouseArea {
      id: queueBarMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.queueBarClicked()
    }
  }
}
