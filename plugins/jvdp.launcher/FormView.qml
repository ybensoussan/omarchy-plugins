import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A form the backend describes: settings, a quicklink, a snippet, an alias.
// Field types: section, info, text, textarea, number, toggle, choice, link.
Item {
  id: view

  property var launcher: null
  readonly property var form: launcher ? launcher.form : null
  readonly property var fields: form ? (form.fields || []) : []
  property var values: ({})
  property int cursor: -1
  readonly property int rowH: Math.max(Style.space(40), Style.font.body + Style.spacing.controlPaddingY * 2 + Style.space(14))

  function focusable(i) {
    var f = fields[i]
    return !!f && f.type !== "section" && f.type !== "info"
  }

  function begin() {
    var v = {}
    for (var i = 0; i < fields.length; i++) if (fields[i].key) v[fields[i].key] = fields[i].value
    values = v
    cursor = -1
    move(1)
  }

  function setValue(key, value) {
    var v = Object.assign({}, values)
    v[key] = value
    values = v
  }

  function move(delta) {
    var i = cursor
    for (var n = 0; n < fields.length; n++) {
      i += delta
      if (i < 0 || i >= fields.length) return
      if (focusable(i)) break
    }
    if (!focusable(i)) return
    cursor = i
    var row = repeater.itemAt(i)
    if (row) {
      flick.ensureVisible(row)
      row.takeFocus()
    }
  }

  function submit() {
    if (!form) return
    launcher.send({ op: "submit", form: form.id, values: values })
  }

  function cycle(f, delta) {
    var opts = f.options || []
    if (opts.length === 0) return
    var idx = 0
    for (var i = 0; i < opts.length; i++) if (opts[i].value === values[f.key]) idx = i
    setValue(f.key, opts[(idx + delta + opts.length) % opts.length].value)
  }

  function activate(f) {
    if (f.type === "toggle") setValue(f.key, !values[f.key])
    else if (f.type === "choice") cycle(f, 1)
    else if (f.type === "link") launcher.send({ op: "run", id: f.item, action: "default", arg: null })
    else move(1)
  }

  // Keys every field shares; text fields pass the rest on to typing.
  function navKey(event, f, multiline) {
    var ctrl = event.modifiers & Qt.ControlModifier
    if (event.key === Qt.Key_Escape) { launcher.back(); return true }
    if (ctrl && (event.key === Qt.Key_S || event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { submit(); return true }
    if (event.key === Qt.Key_Tab) { move(1); return true }
    if (event.key === Qt.Key_Backtab) { move(-1); return true }
    if (!multiline && event.key === Qt.Key_Down) { move(1); return true }
    if (!multiline && event.key === Qt.Key_Up) { move(-1); return true }
    if (!multiline && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
      if (f.type === "text" || f.type === "number" || f.type === "password") move(1)
      else activate(f)
      return true
    }
    if (f.type === "choice" && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
      cycle(f, Util.readingKey(event) === Qt.Key_Left ? -1 : 1)
      return true
    }
    if ((f.type === "toggle" || f.type === "choice") && event.key === Qt.Key_Space) { activate(f); return true }
    return false
  }

  Flickable {
    id: flick
    anchors.fill: parent
    contentWidth: width
    contentHeight: column.implicitHeight + Style.space(8)
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    function ensureVisible(item) {
      var y = item.y
      if (y < contentY) contentY = Math.max(0, y - Style.space(28))
      else if (y + item.height > contentY + height) contentY = Math.min(contentHeight - height, y + item.height - height + Style.space(8))
    }

    Column {
      id: column
      width: flick.width
      spacing: Style.spacing.xs

      Repeater {
        id: repeater
        model: view.fields

        delegate: Item {
          id: fieldRow
          required property var modelData
          required property int index
          readonly property var f: modelData
          readonly property bool current: index === view.cursor
          readonly property bool isText: f.type === "text" || f.type === "number" || f.type === "password" || f.type === "textarea"

          width: column.width
          height: f.type === "section" ? Style.space(30)
            : f.type === "info" ? infoText.implicitHeight + Style.space(10)
            : f.type === "textarea" ? Style.space(130) + (hintText.visible ? hintText.implicitHeight : 0)
            : view.rowH + (hintText.visible ? hintText.implicitHeight + Style.space(2) : 0)

          function takeFocus() {
            if (f.type === "text" || f.type === "number" || f.type === "password") lineField.forceActiveFocus()
            else if (f.type === "textarea") areaField.forceActiveFocus()
            else keyTaker.forceActiveFocus()
          }

          Item {
            id: keyTaker
            Keys.onPressed: function(event) { if (view.navKey(event, fieldRow.f, false)) event.accepted = true }
          }

          // Section heading
          Text {
            visible: fieldRow.f.type === "section"
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(4)
            text: fieldRow.f.label || ""
            color: view.launcher.selectedText
            font.family: view.launcher.fontFamily
            font.pixelSize: Style.font.caption
            font.weight: Font.Bold
            font.capitalization: Font.AllUppercase
          }

          Text {
            id: infoText
            visible: fieldRow.f.type === "info"
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: (fieldRow.f.label || "") + (fieldRow.f.hint ? "\n" + fieldRow.f.hint : "")
            color: view.launcher.foreground
            opacity: 0.6
            wrapMode: Text.WordWrap
            font.family: view.launcher.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // A field: highlight, label on the left, control on the right.
          Rectangle {
            id: frame
            visible: view.focusable(fieldRow.index)
            anchors.fill: parent
            radius: view.launcher.cornerRadius
            color: fieldRow.current ? view.launcher.selectedBackground : "transparent"

            MouseArea {
              anchors.fill: parent
              onClicked: {
                view.cursor = fieldRow.index
                fieldRow.takeFocus()
                if (!fieldRow.isText) view.activate(fieldRow.f)
              }
            }

            Text {
              id: label
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              y: (view.rowH - height) / 2
              width: fieldRow.f.type === "link" ? parent.width - Style.space(40) : parent.width * 0.38
              text: (fieldRow.f.label || "") + (fieldRow.f.type === "link" ? "  ›" : "")
              color: fieldRow.current ? view.launcher.selectedText : view.launcher.foreground
              font.family: view.launcher.fontFamily
              font.pixelSize: Style.font.body
              font.weight: fieldRow.current ? Font.Medium : Font.Normal
              elide: Text.ElideRight
            }

            Text {
              id: hintText
              visible: !!fieldRow.f.hint && fieldRow.f.type !== "info"
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(5)
              text: fieldRow.f.hint || ""
              color: view.launcher.foreground
              opacity: 0.45
              wrapMode: Text.WordWrap
              font.family: view.launcher.fontFamily
              font.pixelSize: Style.font.caption
            }

            Item {
              id: control
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              y: fieldRow.f.type === "textarea" ? view.rowH * 0.85 : 0
              width: fieldRow.f.type === "textarea" ? parent.width - Style.space(20) : parent.width * 0.58
              height: fieldRow.f.type === "textarea" ? Style.space(130) - view.rowH * 0.85 - Style.space(4) : view.rowH

              TextField {
                id: lineField
                visible: fieldRow.f.type === "text" || fieldRow.f.type === "number" || fieldRow.f.type === "password"
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                foreground: view.launcher.foreground
                accent: view.launcher.accent
                font.family: view.launcher.fontFamily
                hasCursor: fieldRow.current
                echoMode: fieldRow.f.type === "password" ? TextInput.Password : TextInput.Normal
                inputMethodHints: fieldRow.f.type === "password" ? (Qt.ImhSensitiveData | Qt.ImhNoPredictiveText) : fieldRow.f.type === "number" ? Qt.ImhDigitsOnly : Qt.ImhNone
                validator: fieldRow.f.type === "number" ? numberValidator : null
                text: fieldRow.f.key && view.values[fieldRow.f.key] !== undefined ? String(view.values[fieldRow.f.key]) : ""
                onTextEdited: view.setValue(fieldRow.f.key, fieldRow.f.type === "number" ? (parseInt(text) || 0) : text)
                onActiveFocusChanged: if (activeFocus) view.cursor = fieldRow.index
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) { if (view.navKey(event, fieldRow.f, false)) event.accepted = true }
                IntValidator { id: numberValidator; bottom: fieldRow.f.min || 0; top: fieldRow.f.max || 99999 }
              }

              Controls.ScrollView {
                visible: fieldRow.f.type === "textarea"
                anchors.fill: parent

                Controls.TextArea {
                  id: areaField
                  wrapMode: TextEdit.Wrap
                  color: view.launcher.foreground
                  selectionColor: Util.alpha(view.launcher.accent, 0.35)
                  font.family: view.launcher.fontFamily
                  font.pixelSize: Style.font.body
                  text: fieldRow.f.key && view.values[fieldRow.f.key] !== undefined ? String(view.values[fieldRow.f.key]) : ""
                  onTextChanged: if (fieldRow.f.type === "textarea" && activeFocus) view.setValue(fieldRow.f.key, text)
                  onActiveFocusChanged: if (activeFocus) view.cursor = fieldRow.index
                  Keys.priority: Keys.BeforeItem
                  Keys.onPressed: function(event) { if (view.navKey(event, fieldRow.f, true)) event.accepted = true }
                  background: BorderSurface {
                    color: Style.controlFill(areaField.activeFocus, fieldRow.current, view.launcher.foreground, view.launcher.accent)
                    borderSpec: Border.controlSpec(areaField.activeFocus ? "focus" : "normal", view.launcher.foreground, view.launcher.accent)
                    radius: Style.cornerRadius
                  }
                }
              }

              ToggleSwitch {
                visible: fieldRow.f.type === "toggle"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: view.values[fieldRow.f.key] === true
                hasCursor: fieldRow.current
                foreground: view.launcher.foreground
                accent: view.launcher.accent
                onToggled: {
                  view.cursor = fieldRow.index
                  view.activate(fieldRow.f)
                }
              }

              Row {
                visible: fieldRow.f.type === "choice"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                Text {
                  textFormat: Text.PlainText
                  text: "‹"
                  color: view.launcher.foreground
                  opacity: fieldRow.current ? 0.7 : 0.25
                  font.family: view.launcher.fontFamily
                  font.pixelSize: Style.font.heading
                  MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: { view.cursor = fieldRow.index; view.cycle(fieldRow.f, -1) } }
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: {
                    var opts = fieldRow.f.options || []
                    for (var i = 0; i < opts.length; i++) if (opts[i].value === view.values[fieldRow.f.key]) return opts[i].label
                    return String(view.values[fieldRow.f.key] || "")
                  }
                  color: fieldRow.current ? view.launcher.selectedText : view.launcher.foreground
                  font.family: view.launcher.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  textFormat: Text.PlainText
                  text: "›"
                  color: view.launcher.foreground
                  opacity: fieldRow.current ? 0.7 : 0.25
                  font.family: view.launcher.fontFamily
                  font.pixelSize: Style.font.heading
                  MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: { view.cursor = fieldRow.index; view.cycle(fieldRow.f, 1) } }
                }
              }
            }
          }
        }
      }

      Item {
        width: column.width
        height: view.rowH

        Button {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: (view.form && view.form.submit) || "Save"
          bordered: true
          foreground: view.launcher.foreground
          accent: view.launcher.accent
          onClicked: view.submit()
        }
      }
    }
  }
}
