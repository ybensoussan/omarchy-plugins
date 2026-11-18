import QtQuick
import qs.Commons

// Horizontal slider in the theme's control colours. Emits moved(value) while dragging, snapped to `step`.
Item {
  id: slider

  property real value: 0.5
  property real from: 0
  property real to: 1
  property real step: 0.05
  readonly property color ink: Color.menu.text
  readonly property real fraction: Math.max(0, Math.min(1, (value - from) / (to - from)))
  signal moved(real value)

  implicitWidth: Style.space(220)
  implicitHeight: Style.space(26)

  function setFromX(x) {
    var f = Math.max(0, Math.min(1, (x - knob.width / 2) / Math.max(1, width - knob.width)))
    var v = from + f * (to - from)
    v = Math.round(v / step) * step
    v = Math.max(from, Math.min(to, Math.round(v * 100) / 100))
    if (v !== value) moved(v)
  }

  Rectangle {
    id: track
    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
    height: Math.max(4, Style.space(5))
    radius: height / 2
    color: Style.selectedFillFor(slider.ink, Color.accent)
    Rectangle {
      width: knob.x + knob.width / 2
      height: parent.height
      radius: parent.radius
      color: Color.accent
    }
  }

  Rectangle {
    id: knob
    width: Style.space(16)
    height: width
    radius: width / 2
    x: slider.fraction * (slider.width - width)
    anchors.verticalCenter: parent.verticalCenter
    color: Color.accent
    border.width: area.pressed || area.containsMouse ? 2 : 0
    border.color: slider.ink
  }

  MouseArea {
    id: area
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onPressed: function(mouse) { slider.setFromX(mouse.x) }
    onPositionChanged: function(mouse) { if (pressed) slider.setFromX(mouse.x) }
  }
}
