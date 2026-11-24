import QtQuick

// Keyboard dispatcher for the mini player, modelled on qs.Ui.PanelKeyCatcher
// so the interaction stays Omarchy-standard: arrows/hjkl move a shared cursor,
// Enter activates, single letters are direct actions, Tab switches bar panels.
//
// It is a focused overlay rather than a wrapper: while a text field has
// active focus the field receives keys and this item hears nothing, which is
// exactly the behaviour panels want from `blocked` — without the field ever
// having to declare itself. MiniPlayer hands focus back to this catcher when
// an editor goes away.
//
// Two deliberate differences from the shell component:
//   - Space is play/pause, not activate. Media controls are the primary
//     transport, so Space keeps its universal meaning; Enter activates.
//   - It never consumes Escape; MiniPlayer owns the ladder (close sheet ->
//     back -> close panel) so it also runs while a text field has focus
//     through a window-level Shortcut.
Item {
  id: root

  signal moveRequested(int dx, int dy, bool shift)
  signal activateRequested(bool shift)
  signal playPauseRequested()
  signal deleteRequested()
  signal escapeRequested()
  signal pageRequested(int direction)
  signal homeEndRequested(bool toEnd)
  signal backRequested()
  signal forwardRequested()
  signal tabRequested(int direction)
  signal textKey(string text)

  focus: true
  Keys.onPressed: function(event) {
    switch (event.key) {
      case Qt.Key_Escape:
        root.escapeRequested()
        event.accepted = true
        return
      case Qt.Key_Down:
        root.moveRequested(0, 1, (event.modifiers & Qt.ShiftModifier) !== 0)
        event.accepted = true
        return
      case Qt.Key_Up:
        root.moveRequested(0, -1, (event.modifiers & Qt.ShiftModifier) !== 0)
        event.accepted = true
        return
      case Qt.Key_Right:
        root.moveRequested(1, 0, (event.modifiers & Qt.ShiftModifier) !== 0)
        event.accepted = true
        return
      case Qt.Key_Left:
        root.moveRequested(-1, 0, (event.modifiers & Qt.ShiftModifier) !== 0)
        event.accepted = true
        return
      case Qt.Key_Delete:
        if (!event.isAutoRepeat) root.deleteRequested()
        event.accepted = true
        return
      case Qt.Key_PageDown:
        root.pageRequested(1)
        event.accepted = true
        return
      case Qt.Key_PageUp:
        root.pageRequested(-1)
        event.accepted = true
        return
      case Qt.Key_Home:
        root.homeEndRequested(false)
        event.accepted = true
        return
      case Qt.Key_End:
        root.homeEndRequested(true)
        event.accepted = true
        return
      case Qt.Key_Return:
      case Qt.Key_Enter:
        if (!event.isAutoRepeat) root.activateRequested((event.modifiers & Qt.ShiftModifier) !== 0)
        event.accepted = true
        return
      case Qt.Key_Space:
        if (!event.isAutoRepeat) root.playPauseRequested()
        event.accepted = true
        return
      case Qt.Key_Tab:
      case Qt.Key_Backtab:
        root.tabRequested(event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1)
        event.accepted = true
        return
      case Qt.Key_Backspace:
        if (!event.isAutoRepeat) {
          if ((event.modifiers & Qt.ShiftModifier) !== 0) root.forwardRequested()
          else root.backRequested()
        }
        event.accepted = true
        return
    }
    var text = event.text || ""
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
    // Uppercase hjkl is Shift held (or Caps Lock): carry the flag so list
    // views can move the row along instead of just the cursor.
    var moved = (event.modifiers & Qt.ShiftModifier) !== 0
    if (text === "j" || text === "J") { root.moveRequested(0, 1, moved); event.accepted = true; return }
    if (text === "k" || text === "K") { root.moveRequested(0, -1, moved); event.accepted = true; return }
    if (text === "l" || text === "L") { root.moveRequested(1, 0, moved); event.accepted = true; return }
    if (text === "h" || text === "H") { root.moveRequested(-1, 0, moved); event.accepted = true; return }
    if (text.length === 1) {
      root.textKey(text)
      event.accepted = true
    }
  }
}
