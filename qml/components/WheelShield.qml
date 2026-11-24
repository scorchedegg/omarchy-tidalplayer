import QtQuick

// Swallows wheel and touchpad scrolling for a modal surface.
//
// A wheel event is delivered to every item under the pointer until one accepts
// it, and a MouseArea only accepts a wheel when it has an `onWheel` handler —
// so the click-catching MouseAreas on a sheet's scrim and body ignore wheel
// events and let them reach the page underneath. There the collapsed player's
// seek bar and volume control turn a scroll over the sheet into a seek or a
// volume change.
//
// Fill the overlay and declare it before the scrim: the scrim and the sheet
// then sit above it, so a scrollable list inside the sheet (the cast device
// list, the playlist picker) still gets the first shot at the event and keeps
// scrolling. Only events that nothing inside the sheet wanted land here.
MouseArea {
  anchors.fill: parent
  // Not a click target: clicks belong to the scrim and the sheet above.
  acceptedButtons: Qt.NoButton
  // Both axes, unlike a WheelHandler, whose vertical orientation would let a
  // horizontal touchpad swipe through.
  onWheel: function(event) { event.accepted = true }
}
