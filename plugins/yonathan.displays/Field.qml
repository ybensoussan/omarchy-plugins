import QtQuick
import qs.Commons
import qs.Ui

// Single-line text field styled like Omarchy's kit TextField (theme fill, hover/focus borders and
// selection colour from [controls] in shell.toml). Emits accepted() on Enter and cancelled() on
// Escape; `input` exposes the TextInput for focus and bindings.
BorderSurface {
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

  readonly property color foreground: Color.menu.text
  readonly property bool focused: input.activeFocus
  readonly property bool hot: hover.hovered
  readonly property var stateBorder: Border.controlSpec(focused ? "focus" : (hot ? "hover-cursor" : "normal"), foreground, Color.accent)

  implicitHeight: Math.max(Style.spacing.controlHeight, fontSize + Style.spacing.inputPaddingY * 2)
  implicitWidth: Style.space(160)
  radius: Style.cornerRadius
  color: Style.controlFill(focused, hot, foreground, Color.accent)
  borderSpec: stateBorder

  HoverHandler { id: hover; cursorShape: Qt.IBeamCursor }

  TextInput {
    id: input
    anchors.fill: parent
    anchors.leftMargin: Style.spacing.controlPaddingX + Border.left(field.stateBorder)
    anchors.rightMargin: Style.spacing.controlPaddingX + Border.right(field.stateBorder)
    verticalAlignment: TextInput.AlignVCenter
    color: field.foreground
    font.family: Style.font.family
    font.pixelSize: field.fontSize
    clip: true
    selectByMouse: true
    selectionColor: Style.selectionFillFor(field.foreground, Color.accent)
    selectedTextColor: field.foreground
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
    textFormat: Text.PlainText
    text: field.placeholder
    color: Qt.darker(field.foreground, 1.6)
    font.family: Style.font.family
    font.pixelSize: field.fontSize
    elide: Text.ElideRight
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: input.anchors.leftMargin
    anchors.rightMargin: input.anchors.rightMargin
  }
}
