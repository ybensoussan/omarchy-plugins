import QtQuick

// Single-line input for the search line. Key events are offered to
// `keyHandler` first (navigation, shortcuts, filter editing); whatever it
// leaves unaccepted is handled by TextInput itself (cursor, IME, paste).
TextInput {
  id: input
  property Item keyHandler: null
  Keys.forwardTo: keyHandler ? [keyHandler] : []
  selectByMouse: true
  clip: true
  selectionColor: Qt.rgba(color.r, color.g, color.b, 0.3)
  selectedTextColor: color
}
