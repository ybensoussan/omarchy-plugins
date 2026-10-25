import QtQuick
import qs.Commons

// "↵ Open" in the footer: a key cap and what it does.
Row {
  id: hint

  property var launcher: null
  property string keys: ""
  property string label: ""

  spacing: Style.spacing.sm

  Rectangle {
    anchors.verticalCenter: parent.verticalCenter
    width: Math.max(height, capText.implicitWidth + Style.spacing.md * 2)
    height: capText.implicitHeight + Style.spacing.xs * 2
    radius: Math.min(launcher.cornerRadius, height / 3)
    color: Util.alpha(launcher.foreground, 0.1)

    Text {
      id: capText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: hint.keys
      color: launcher.foreground
      opacity: 0.8
      font.family: launcher.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Text {
    textFormat: Text.PlainText
    anchors.verticalCenter: parent.verticalCenter
    text: hint.label
    color: launcher.foreground
    opacity: 0.6
    font.family: launcher.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
