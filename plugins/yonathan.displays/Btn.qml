import QtQuick
import qs.Commons

// Themed button. `primary` = filled accent, `danger` = destructive, `checked` = toggled/segment on.
Rectangle {
  id: button

  property string text: ""
  property string icon: ""
  property bool primary: false
  property bool danger: false
  property bool checked: false
  property bool compact: false
  property string tooltip: ""
  signal clicked()

  readonly property color fg: Color.menu.text
  readonly property color accent: Color.accent
  readonly property color red: Color.urgent

  implicitHeight: compact ? 24 : 30
  implicitWidth: Math.max(compact ? 24 : 30, content.implicitWidth + (compact ? 12 : 20))
  radius: 6
  opacity: enabled ? 1 : 0.4
  color: primary ? (area.containsMouse ? Qt.lighter(accent, 1.12) : accent)
       : checked ? Qt.alpha(accent, 0.24)
       : danger && area.containsMouse ? Qt.alpha(red, 0.18)
       : area.containsMouse ? Qt.alpha(fg, 0.12) : Qt.alpha(fg, 0.05)
  border.width: 1
  border.color: primary ? accent : checked ? Qt.alpha(accent, 0.8) : danger ? Qt.alpha(red, 0.55) : Qt.alpha(fg, 0.13)

  Behavior on color { ColorAnimation { duration: 90 } }

  Row {
    id: content
    anchors.centerIn: parent
    spacing: 6
    Text {
      visible: button.icon !== ""
      text: button.icon
      color: button.primary ? Color.menu.background : button.danger ? button.red : button.checked ? button.accent : button.fg
      font.family: Style.font.menuFamily
      font.pixelSize: button.compact ? Style.font.bodySmall : Style.font.title
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      visible: button.text !== ""
      text: button.text
      color: button.primary ? Color.menu.background : button.danger ? button.red : button.checked ? button.accent : button.fg
      font.family: Style.font.menuFamily
      font.pixelSize: button.compact ? Style.font.caption : Style.font.body
      font.bold: button.primary || button.checked
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    id: area
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: button.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: if (button.enabled) button.clicked()
  }
}
