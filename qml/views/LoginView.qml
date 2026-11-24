import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import "../components"

Item {
  id: root

  property bool alive: true
  Component.onDestruction: {
    root.alive = false
    pollTimer.stop()
    copyTimer.stop()
  }

  property var svc: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.menuFamily

  property string authUrl: ""
  property bool waitingForAuth: false
  property bool clipboardWatching: true
  property bool submitting: false
  property bool copied: false
  property string errorText: ""

  readonly property bool signingIn: root.submitting || (root.svc ? root.svc.authExchanging : false)
  readonly property string displayError: root.errorText !== ""
    ? root.errorText
    : (root.svc ? root.svc.authError : "")

  signal loginCompleted()

  onVisibleChanged: {
    if (!root.visible) {
      pollTimer.stop()
    } else {
      root.syncPendingState()
    }
  }

  function syncPendingState() {
    if (!root.alive || !root.svc) return
    root.svc.pollPkceAuth(function(err, data) {
      if (!root || !root.alive || err || !data) return
      if (data.logged_in) {
        root.waitingForAuth = false
        root.errorText = ""
        pollTimer.stop()
        root.loginCompleted()
        return
      }
      if (data.pending && data.url) {
        root.authUrl = String(data.url)
        root.clipboardWatching = data.clipboard_watching !== false
        root.waitingForAuth = true
        if (data.error) root.errorText = String(data.error)
        if (root.visible) pollTimer.restart()
      } else if (root.waitingForAuth) {
        root.waitingForAuth = false
        pollTimer.stop()
      }
    })
  }

  function startLogin() {
    if (!root.svc) return
    root.errorText = ""
    root.waitingForAuth = true
    pasteInput.text = ""
    root.svc.startPkceAuth(function(err, data) {
      if (!root || !root.alive) return
      if (!err && data && data.url) {
        root.authUrl = String(data.url)
        root.clipboardWatching = data.clipboard_watching !== false
        root.openBrowser()
        if (root.visible) pollTimer.restart()
      } else {
        root.waitingForAuth = false
        root.errorText = (err && err.message) ? String(err.message) : "Could not start sign-in. Try again."
      }
    })
  }

  function checkAuth() {
    if (!root.alive || !root.visible || !root.waitingForAuth || !root.svc) return
    root.svc.pollPkceAuth(function(err, data) {
      if (!root || !root.alive || err || !data) return
      if (data.logged_in) {
        root.waitingForAuth = false
        root.errorText = ""
        pasteInput.text = ""
        pollTimer.stop()
        root.loginCompleted()
      } else if (!data.pending) {
        pollTimer.stop()
        root.waitingForAuth = false
        root.authUrl = ""
        root.errorText = "Sign-in expired. Try again."
      } else if (data.error) {
        root.errorText = String(data.error)
      }
    })
  }

  function submitRedirectUrl() {
    if (!root.svc || root.signingIn) return
    var text = String(pasteInput.text || "").trim()
    if (text === "") return
    root.submitting = true
    root.errorText = ""
    root.svc.completePkceAuth(text, function(err, success) {
      if (!root || !root.alive) return
      root.submitting = false
      if (success) {
        root.waitingForAuth = false
        root.errorText = ""
        pasteInput.text = ""
        pollTimer.stop()
        root.loginCompleted()
      } else {
        root.errorText = (err && err.message) ? String(err.message) : "Could not complete sign-in."
      }
    })
  }

  function cancelLogin() {
    pollTimer.stop()
    root.waitingForAuth = false
    root.authUrl = ""
    root.errorText = ""
    pasteInput.text = ""
    if (root.svc) root.svc.cancelPkceAuth()
  }

  // Direct keys (`c` copies link, `o` opens the browser) and the buttons share
  // these. Timer ids resolve lexically, so the functions can live up here.
  function copyLoginUrl() {
    if (!root.authUrl) return
    Quickshell.clipboardText = root.authUrl
    root.copied = true
    copyTimer.restart()
  }

  function openBrowser() {
    if (!root.authUrl) return
    Quickshell.execDetached([
      "sh", "-c",
      "if command -v omarchy-launch-browser >/dev/null 2>&1; then exec omarchy-launch-browser \"$1\"; else exec xdg-open \"$1\"; fi",
      "sh", root.authUrl
    ])
  }

  Timer {
    id: pollTimer
    interval: 1000
    repeat: true
    running: false
    onTriggered: if (root.alive) root.checkAuth()
  }

  Column {
    anchors.centerIn: parent
    width: parent.width - 48
    spacing: (root.waitingForAuth && !root.signingIn) ? Style.space(16) : Style.space(24)

    // Brand Mark & Header
    Column {
      width: parent.width
      spacing: Style.space(12)

      TidalLogo {
        anchors.horizontalCenter: parent.horizontalCenter
        size: (root.waitingForAuth && !root.signingIn) ? 44 : 62
        color: root.foreground
        pulsing: root.waitingForAuth || root.signingIn
      }

      Column {
        width: parent.width
        spacing: 5

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.signingIn
            ? "Signing in to TIDAL\u2026"
            : (root.waitingForAuth ? "Sign in to TIDAL" : "TIDAL Player")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: (root.waitingForAuth && !root.signingIn) ? 19 : 22
          font.weight: Font.Bold
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.signingIn
            ? "Connecting your account"
            : (root.waitingForAuth
              ? "Finish connecting your account in the browser"
              : "Hi-Res Lossless streaming on Omarchy")
          color: root.foreground
          opacity: 0.65
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall || 12
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
      }
    }

    // Active token-exchange feedback (shown as soon as the redirect URL is caught)
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(parent.width, 220)
      height: 36
      radius: 18
      visible: root.signingIn
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
      border.width: 1
      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

      RowLayout {
        anchors.centerIn: parent
        spacing: 8

        Rectangle {
          Layout.preferredWidth: 7
          Layout.preferredHeight: 7
          radius: 3.5
          color: root.foreground
          opacity: 0.85

          SequentialAnimation on opacity {
            running: root.signingIn && root.visible
            loops: Animation.Infinite
            NumberAnimation { to: 0.25; duration: 600; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0.9; duration: 600; easing.type: Easing.InOutSine }
          }
        }

        Text {
          textFormat: Text.PlainText
          text: "Authorizing session\u2026"
          color: root.foreground
          opacity: 0.8
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption || 11
          font.weight: Font.Medium
        }
      }
    }

    // Initial Login Action Button (When not initiated)
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(parent.width, 240)
      height: 44
      radius: 22
      color: loginMa.containsMouse
        ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.88)
        : root.foreground
      visible: !root.waitingForAuth && !root.signingIn

      RowLayout {
        anchors.centerIn: parent
        spacing: 8

        SvgIcon {
          size: 16
          color: Color.popups.background
          source: Qt.resolvedUrl("../../assets/icons/login.svg")
        }

        Text {
          textFormat: Text.PlainText
          text: "Log in with TIDAL"
          color: Color.popups.background
          font.family: root.fontFamily
          font.pixelSize: Style.font.body || 13
          font.weight: Font.Bold
        }
      }

      MouseArea {
        id: loginMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.startLogin()
      }
    }

    // Failure Banner (shown on exchange/auth failure so the user immediately sees why it failed)
    Rectangle {
      width: parent.width
      implicitHeight: errCol.implicitHeight + 20
      radius: 10
      visible: !root.signingIn && root.displayError !== ""
      color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.14)
      border.width: 1
      border.color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.45)

      Column {
        id: errCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        spacing: 3

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "Sign-in failed"
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall || 12
          font.weight: Font.Bold
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.displayError
          color: root.foreground
          opacity: 0.9
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption || 11
          wrapMode: Text.WordWrap
        }
      }
    }

    // PKCE Guidance & Fallback Paste Card (When initiated and not currently exchanging)
    Column {
      width: parent.width
      spacing: Style.space(12)
      visible: root.waitingForAuth && !root.signingIn

      Rectangle {
        width: parent.width
        implicitHeight: guideCol.implicitHeight + 28
        radius: 12
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
        border.width: 1
        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.13)

        Column {
          id: guideCol
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: 14
          anchors.rightMargin: 14
          spacing: 11

          // Step 1
          RowLayout {
            width: parent.width
            spacing: 10

            Rectangle {
              Layout.preferredWidth: 20
              Layout.preferredHeight: 20
              Layout.alignment: Qt.AlignTop
              radius: 10
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: "1"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: 11
                font.weight: Font.Bold
              }
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: "Sign in to your TIDAL account in your browser."
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall || 12
              wrapMode: Text.WordWrap
            }
          }

          // Step 2
          RowLayout {
            width: parent.width
            spacing: 10

            Rectangle {
              Layout.preferredWidth: 20
              Layout.preferredHeight: 20
              Layout.alignment: Qt.AlignTop
              radius: 10
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: "2"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: 11
                font.weight: Font.Bold
              }
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: root.clipboardWatching
                ? "On the \u201CPage not found\u201D screen, copy the URL from the address bar (or press Ctrl+L \u2192 Ctrl+C)."
                : "On the \u201CPage not found\u201D screen, copy the URL from the address bar and paste it below."
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall || 12
              wrapMode: Text.WordWrap
            }
          }

          // Clipboard listening indicator
          Rectangle {
            width: parent.width
            height: 1
            visible: root.clipboardWatching
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
          }

          RowLayout {
            width: parent.width
            spacing: 8
            visible: root.clipboardWatching

            Rectangle {
              Layout.preferredWidth: 7
              Layout.preferredHeight: 7
              radius: 3.5
              color: root.foreground
              opacity: 0.75

              SequentialAnimation on opacity {
                running: root.waitingForAuth && !root.signingIn && root.clipboardWatching && root.visible
                loops: Animation.Infinite
                NumberAnimation { to: 0.25; duration: 900; easing.type: Easing.InOutSine }
                NumberAnimation { to: 0.85; duration: 900; easing.type: Easing.InOutSine }
              }
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: "Waiting for copied URL \u2014 finishes automatically"
              color: root.foreground
              opacity: 0.62
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption || 11
              wrapMode: Text.WordWrap
            }
          }
        }
      }

      // Fallback paste input for manual completion
      RowLayout {
        width: parent.width
        spacing: 8

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: 36
          radius: 9
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
          border.width: 1
          border.color: pasteInput.activeFocus
            ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.4)
            : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.13)
          clip: true

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 11
            anchors.rightMargin: 11
            text: "Or paste the URL here\u2026"
            color: root.foreground
            opacity: 0.42
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption || 11
            elide: Text.ElideRight
            visible: pasteInput.text === ""
          }

          TextInput {
            id: pasteInput
            anchors.fill: parent
            anchors.leftMargin: 11
            anchors.rightMargin: 11
            verticalAlignment: TextInput.AlignVCenter
            color: root.foreground
            selectionColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.28)
            selectedTextColor: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption || 11
            selectByMouse: true
            onAccepted: root.submitRedirectUrl()
          }
        }

        Rectangle {
          Layout.preferredWidth: 78
          Layout.preferredHeight: 36
          radius: 9
          readonly property bool ready: !root.signingIn && pasteInput.text.trim() !== ""
          color: ready
            ? (connectMa.containsMouse
              ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.88)
              : root.foreground)
            : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: "Connect"
            color: parent.ready ? Color.popups.background : root.foreground
            opacity: parent.ready ? 1.0 : 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall || 12
            font.weight: Font.DemiBold
          }

          MouseArea {
            id: connectMa
            anchors.fill: parent
            hoverEnabled: true
            enabled: parent.ready
            cursorShape: parent.ready ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.submitRedirectUrl()
          }
        }
      }

      RowLayout {
        width: parent.width
        spacing: 10

        // Copy Link Button
        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: 38
          radius: 19
          color: copyMa.containsMouse
            ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
            : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)

          RowLayout {
            anchors.centerIn: parent
            spacing: 7

            SvgIcon {
              size: 14
              color: root.foreground
              source: root.copied
                ? Qt.resolvedUrl("../../assets/icons/check.svg")
                : Qt.resolvedUrl("../../assets/icons/copy.svg")
            }

            Text {
              textFormat: Text.PlainText
              text: root.copied ? "Copied!" : "Copy Link"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall || 12
              font.weight: Font.DemiBold
            }
          }

          MouseArea {
            id: copyMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.copyLoginUrl()
          }

          Timer {
            id: copyTimer
            interval: 2000
            onTriggered: if (root.alive) root.copied = false
          }
        }

        // Open Browser Button (or Try Again when an auth error occurred)
        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: 38
          radius: 19
          color: openMa.containsMouse
            ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.88)
            : root.foreground

          RowLayout {
            anchors.centerIn: parent
            spacing: 6

            Text {
              textFormat: Text.PlainText
              text: root.displayError !== "" ? "Try Again" : "Open Browser"
              color: Color.popups.background
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall || 12
              font.weight: Font.Bold
            }
          }

          MouseArea {
            id: openMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (root.displayError !== "") root.startLogin()
              else root.openBrowser()
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Cancel"
        color: root.foreground
        opacity: cancelMa.containsMouse ? 0.9 : 0.52
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption || 11

        MouseArea {
          id: cancelMa
          anchors.fill: parent
          anchors.margins: -6
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.cancelLogin()
        }
      }
    }
  }
}
