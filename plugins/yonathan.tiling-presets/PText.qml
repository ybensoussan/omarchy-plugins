import QtQuick
import qs.Commons

// Text for user-owned strings (preset names): never rich text.
Text {
  textFormat: Text.PlainText
  color: Color.menu.text
  font.family: Style.font.family
  font.pixelSize: Style.font.body
}
