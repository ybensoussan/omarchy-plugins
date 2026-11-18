import QtQuick
import qs.Commons
import "Logic.js" as L

// A miniature of what a preset does to `count` windows.
Rectangle {
  id: root

  property var preset: null
  property int count: 4
  property color ink: Color.menu.text
  property color tint: Color.accent
  readonly property real gap: Math.max(2, Math.round(Math.min(width, height) * 0.025))
  readonly property var rects: preset ? L.previewRects(preset, count, width / Math.max(1, height)) : []

  radius: Math.max(3, Style.cornerRadius)
  color: Qt.alpha(ink, 0.06)
  border.width: 1
  border.color: Qt.alpha(ink, 0.14)
  clip: true

  Repeater {
    model: root.rects
    delegate: Rectangle {
      required property var modelData
      required property int index
      readonly property bool stacked: modelData.z !== undefined
      readonly property real stepPx: stacked ? root.gap * 2 : 0
      readonly property real spread: stacked ? (root.count - 1) * stepPx : 0
      readonly property real mid: modelData.x + modelData.w / 2
      readonly property real midY: modelData.y + modelData.h / 2

      x: modelData.x * root.width + root.gap + (modelData.step || 0) * stepPx
      y: modelData.y * root.height + root.gap + (modelData.step || 0) * stepPx
      width: Math.max(0, modelData.w * root.width - 2 * root.gap - spread)
      height: Math.max(0, modelData.h * root.height - 2 * root.gap - spread)
      z: modelData.z || 0
      radius: Math.max(2, root.radius / 2)
      color: Qt.alpha(root.tint, index === 0 ? 0.55 : 0.28)
      border.width: 1
      border.color: Qt.alpha(root.tint, index === 0 ? 0.95 : 0.6)
      opacity: mid < 0 || mid > 1 || midY < 0 || midY > 1 ? 0.35 : 1
    }
  }
}
