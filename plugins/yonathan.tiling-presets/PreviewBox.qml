import QtQuick
import qs.Commons
import "Logic.js" as L

// A LayoutPreview inside a fixed landscape box; a portrait one is drawn narrow and centred in it,
// the way the monitor it is for looks next to a landscape one.
Item {
  id: box

  property var preset: null
  property int count: 4
  property bool portrait: false
  property color ink: Color.menu.text
  property color tint: Color.accent
  readonly property real ratio: 1.6

  implicitHeight: Math.round(width / ratio)

  LayoutPreview {
    anchors.centerIn: parent
    height: parent.height
    width: box.portrait ? Math.round(parent.height * L.PORTRAIT_ASPECT) : parent.width
    preset: box.preset
    count: box.count
    ink: box.ink
    tint: box.tint
  }
}
