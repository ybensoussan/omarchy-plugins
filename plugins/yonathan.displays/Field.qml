import QtQuick
import qs.Commons

// Single-line text field. Emits accepted() on Enter and cancelled() on Escape.
Rectangle {
  id: field

  property alias text: input.text
  property alias input: input
  property string placeholder: ""
  property int fontSize: Style.font.body
  property bool numeric: false
  signal accepted()
  signal cancelled()
  signal edited()
  signal focusLost()

  implicitHeight: 30
  implicitWidth: 160
  radius: 6
  color: Qt.alpha(Color.menu.text, 0.06)
  border.width: 1
  border.color: input.activeFocus ? Color.accent : Qt.alpha(Color.menu.text, 0.14)

  TextInput {
    id: input
    anchors.fill: parent
    anchors.leftMargin: 9
    anchors.rightMargin: 9
    verticalAlignment: TextInput.AlignVCenter
    color: Color.menu.text
    font.family: Style.font.menuFamily
    font.pixelSize: field.fontSize
    clip: true
    selectByMouse: true
    selectionColor: Qt.alpha(Color.accent, 0.45)
    inputMethodHints: field.numeric ? Qt.ImhFormattedNumbersOnly : Qt.ImhNone
    validator: field.numeric ? intValidator : null
    onTextEdited: field.edited()
    onActiveFocusChanged: if (!activeFocus) field.focusLost()
    Keys.onReturnPressed: function(event) { field.accepted(); event.accepted = true }
    Keys.onEnterPressed: function(event) { field.accepted(); event.accepted = true }
    Keys.onEscapePressed: function(event) { field.cancelled(); input.focus = false; event.accepted = true }
  }

  IntValidator { id: intValidator; bottom: -100000; top: 100000 }

  Text {
    visible: input.text === "" && !input.activeFocus
    text: field.placeholder
    color: Qt.alpha(Color.menu.text, 0.4)
    font.family: Style.font.menuFamily
    font.pixelSize: field.fontSize
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.leftMargin: 9
  }
}
