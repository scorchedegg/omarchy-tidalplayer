import QtQuick
import qs.Ui

// The standard PanelToolTip for clickable controls, with one extra rule: a
// click hides the tooltip and it stays down until the pointer leaves the
// button and comes back. Hovering alone raises it again after the normal
// delay; wiggling the mouse inside the button does not. Declare it as a
// sibling of the control's MouseArea and hand that MouseArea over as `host`:
//
//   ButtonToolTip {
//     host: nextMa
//     text: "Next"
//     fontFamily: root.fontFamily
//   }
//
// `allowed` is the hook for a site whose tooltip needs an extra condition
// beyond the hover (e.g. a search button that only tips while collapsed).
// `hideOnClick: false` keeps the tooltip up through clicks, for a tooltip
// that reads the control's current state and must relabel in place (the
// shuffle and repeat buttons). `suppress()` hides the tooltip the way a
// click does; the play/pause buttons call it on a state flip under a
// resting pointer, so the tooltip cannot rise over the quality line above
// the transport.
PanelToolTip {
  id: root

  // The control's MouseArea (hoverEnabled: true); its press and enter events
  // drive the gate.
  property var host: null
  property bool allowed: true
  property bool hideOnClick: true
  property bool armed: true

  visible: root.host !== null && root.host.containsMouse && root.allowed && root.armed

  function suppress() {
    root.armed = false
  }

  Connections {
    target: root.host

    // A press is a click in progress: the tooltip goes down at once and stays
    // down for the rest of this hover, so it cannot sit over what the button
    // covers or pop up behind a state flip the click caused. A state readout
    // (hideOnClick: false) stays up instead and relabels.
    function onPressed() {
      if (root.hideOnClick) {
        root.armed = false
      }
    }

    // Hovering back over the button is the only thing that re-arms the tip.
    function onEntered() {
      root.armed = true
    }
  }
}
