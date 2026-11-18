import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Logic.js" as L

// Tiling Presets: pick a preset layout for the focused workspace, and edit the presets.
//   omarchy-shell shell toggle yonathan.tiling-presets          the picker (1-9 or Enter applies, E edits)
//   omarchy-shell shell toggle yonathan.tiling-presets '{"mode":"edit","preset":2}'    the editor, on preset 2
// Presets are stored in ~/.config/omarchy/tiling-presets.json; applying one is done by bin/tiling-preset,
// which can also be bound straight to a key:  tiling-preset apply "Main + stack"
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool pickerOpen: false
  property bool editorOpen: false
  readonly property bool opened: pickerOpen || editorOpen

  // ---- theme ----------------------------------------------------------------
  readonly property color bg: Color.menu.background
  readonly property color windowBg: Qt.rgba(Color.menu.background.r, Color.menu.background.g, Color.menu.background.b, 1)
  readonly property color fg: Color.menu.text
  readonly property color accent: Color.accent
  readonly property color red: Color.urgent
  readonly property string font: Style.font.family
  readonly property color dim: Qt.alpha(fg, 0.55)
  readonly property color faint: Style.normalFillFor(fg, accent)
  readonly property color hoverFill: Style.hoverFillFor(fg, accent)
  readonly property color selFill: Style.selectedFillFor(fg, accent)
  readonly property color line: Util.alpha(fg, 0.12)
  readonly property int r: Style.cornerRadius
  readonly property var menuBorder: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property var popupBorder: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

  // ---- backend ----------------------------------------------------------------
  readonly property string script: String(Qt.resolvedUrl("bin/tiling-preset")).replace(/^file:\/\//, "")
  property var st: null
  readonly property var presets: st ? st.presets : []
  readonly property var allPresets: st ? st.all : []
  readonly property bool portrait: st ? st.portrait : false
  readonly property int previewDefault: st ? L.clamp(st.windows, 3, 6) : 4
  property var afterLoad: null

  function load(then) {
    afterLoad = then || null
    stateProc.running = true
  }

  Process {
    id: stateProc
    command: [root.script, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = null
        try { data = JSON.parse(text) } catch (e) { root.fail("Could not read the presets."); return }
        root.st = data
        var next = root.afterLoad
        root.afterLoad = null
        if (next) next()
      }
    }
  }

  Process {
    id: saveProc
    property bool thenApply: false
    property string applyName: ""
    onExited: function(code) {
      if (code !== 0) { root.fail("Could not save the presets."); return }
      var apply = saveProc.thenApply, name = saveProc.applyName
      saveProc.thenApply = false
      root.load(function() {
        root.adoptSaved()
        root.setStatus(apply ? "Saved and applied." : "Saved.")
        if (apply) Quickshell.execDetached([root.script, "apply", name])
      })
    }
  }

  Process {
    id: defaultsProc
    command: [root.script, "defaults"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.draft = JSON.parse(text); root.sel = 0 } catch (e) { root.fail("Could not read the defaults.") }
      }
    }
  }

  // ---- shared state ------------------------------------------------------------
  property int sel: 0
  property string status: ""
  property bool statusError: false
  function setStatus(text, error) { status = text; statusError = !!error }
  function fail(text) { setStatus(text, true) }

  // ---- lifecycle ---------------------------------------------------------------
  function open(payload) {
    var mode = "pick"
    var parsed = {}
    try { parsed = JSON.parse(String(payload || "")); mode = parsed.mode || mode } catch (e) {}
    if (mode === "edit") openEditor(parsed.preset !== undefined ? parsed.preset - 1 : undefined)
    else openPicker()
  }

  function close() {
    if (editorOpen) requestCloseEditor()
    pickerOpen = false
  }

  IpcHandler {
    target: "yonathan.tiling-presets"
    function toggle(): void { if (root.opened) root.close(); else root.openPicker() }
    function pick(): void { root.openPicker() }
    function edit(): void { root.openEditor() }
    function close(): void { root.close() }
  }

  // ---- picker -------------------------------------------------------------------
  function openPicker() {
    setStatus("")
    sel = 0
    pickerOpen = true
    load(function() {
      var at = -1
      for (var i = 0; i < presets.length; i++) if (presets[i].name === st.current) at = i
      sel = Math.max(0, at)
    })
  }

  function closePicker() { pickerOpen = false }

  function applyPreset(index) {
    if (index < 0 || index >= presets.length) return
    pickerOpen = false
    Quickshell.execDetached([script, "apply", String(index + 1)])
  }

  // ---- editor state --------------------------------------------------------------
  property var draft: null
  property string savedJson: ""
  property int previewCount: 4
  readonly property bool dirty: draft !== null && JSON.stringify(draft) !== savedJson
  readonly property var problems: {
    var out = []
    if (!draft) return out
    var seen = {}
    for (var i = 0; i < draft.length; i++) {
      var key = draft[i].name.trim().toLowerCase()
      if (!key) out.push("Preset " + (i + 1) + " needs a name.")
      else if (seen[key]) out.push("Two presets are called “" + draft[i].name.trim() + "”.")
      seen[key] = true
    }
    return out
  }
  readonly property var current: draft && sel >= 0 && sel < draft.length ? draft[sel] : null

  property string confirmText: ""
  property string confirmOk: ""
  property var confirmAction: null
  function ask(text, ok, action) { confirmText = text; confirmOk = ok; confirmAction = action }

  function edit(fn) { var d = L.clone(draft); fn(d); draft = d }

  function adoptSaved() {
    draft = L.clone(allPresets)
    savedJson = JSON.stringify(draft)
    sel = Math.max(0, Math.min(sel, draft.length - 1))
  }

  // `index` counts the whole list; `name` picks a preset by name (the picker only knows the ones it shows).
  function openEditor(index, name) {
    setStatus("")
    if (index !== undefined && index >= 0) sel = index
    editorOpen = true
    previewCount = 4
    load(function() {
      adoptSaved()
      previewCount = previewDefault
      if (name) for (var i = 0; i < draft.length; i++) if (draft[i].name === name) sel = i
    })
  }

  function editShown(i) {
    closePicker()
    openEditor(undefined, i >= 0 && i < presets.length ? presets[i].name : "")
  }

  function closeEditor() { editorOpen = false; draft = null; confirmAction = null }

  function requestCloseEditor() {
    if (dirty) ask("Close and discard unsaved changes?", "Discard", function() { root.closeEditor() })
    else closeEditor()
  }

  function save(thenApply) {
    if (!draft || problems.length) return
    var list = L.clone(draft).map(function(p) { p.name = p.name.trim(); return p })
    saveProc.thenApply = !!thenApply
    saveProc.applyName = current ? current.name.trim() : ""
    saveProc.command = ["sh", "-c", "printf %s \"$1\" | \"$2\" save", "sh", JSON.stringify(list), script]
    saveProc.running = true
    setStatus("Saving…")
  }

  function addPreset() {
    if (draft.length >= L.MAX_PRESETS) return
    edit(function(d) { d.push(L.blank(L.uniqueName(d, "New preset"))) })
    sel = draft.length - 1
  }

  function duplicatePreset() {
    if (!current || draft.length >= L.MAX_PRESETS) return
    edit(function(d) {
      var copy = L.clone(d[sel])
      copy.name = L.uniqueName(d, copy.name)
      d.splice(sel + 1, 0, copy)
    })
    sel = sel + 1
  }

  function deletePreset() {
    if (!current) return
    var i = sel
    edit(function(d) { d.splice(i, 1) })
    sel = Math.max(0, Math.min(i, draft.length - 1))
  }

  function movePreset(by) {
    var to = sel + by
    if (!current || to < 0 || to >= draft.length) return
    var from = sel
    edit(function(d) { var p = d.splice(from, 1)[0]; d.splice(to, 0, p) })
    sel = to
  }

  // ======================================================================================
  // Picker window. Not Ui/OverlayWindow: it only reveals once Qt's pixel ratio equals the
  // monitor scale, which never happens on monitors scaled below 1 (the switcher does the same).
  // ======================================================================================
  PanelWindow {
    id: panel
    visible: root.pickerOpen
    screen: {
      var name = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
      for (var i = 0; i < Quickshell.screens.length; i++) if (Quickshell.screens[i].name === name) return Quickshell.screens[i]
      return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    }
    anchors { top: true; left: true; bottom: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "yonathan-tiling-presets"

    readonly property int columns: Math.max(1, Math.min(4, root.presets.length))
    readonly property int cardWidth: Style.space(210)
    readonly property int cardGap: Style.space(10)
    property bool pointerMoved: false
    onVisibleChanged: {
      pointerMoved = false
      if (visible) Qt.callLater(function() { keys.forceActiveFocus() })
    }

    Rectangle { anchors.fill: parent; color: Color.menu.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.closePicker() }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      padding: Style.spacing.panelPadding
      width: Math.max(Style.space(420), grid.width) + 2 * padding
      height: content.implicitHeight + 2 * padding
      radius: root.r
      color: root.bg
      borderSpec: root.menuBorder
      MouseArea { anchors.fill: parent }

      FocusScope {
        id: keys
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          var n = root.presets.length
          var cols = panel.columns
          var digit = event.key - Qt.Key_1
          if (event.key === Qt.Key_Escape) root.closePicker()
          else if (event.key === Qt.Key_E) root.editShown(root.sel)
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.applyPreset(root.sel)
          else if (digit >= 0 && digit < 9 && digit < n) root.applyPreset(digit)
          else if (n === 0) return
          else if (event.key === Qt.Key_Left) root.sel = (root.sel + n - 1) % n
          else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab) root.sel = (root.sel + 1) % n
          else if (event.key === Qt.Key_Backtab) root.sel = (root.sel + n - 1) % n
          else if (event.key === Qt.Key_Down) root.sel = Math.min(n - 1, root.sel + cols)
          else if (event.key === Qt.Key_Up) root.sel = Math.max(0, root.sel - cols)
          else return
          event.accepted = true
        }
      }

      Column {
        id: content
        x: card.padding
        y: card.padding
        width: card.width - 2 * card.padding
        spacing: Style.spacing.md

        Row {
          width: parent.width
          spacing: Style.space(10)
          PText {
            id: titleText
            text: "Tiling preset"
            font.pixelSize: Style.font.heading
            font.bold: true
          }
          PText {
            anchors.verticalCenter: titleText.verticalCenter
            width: parent.width - titleText.width - parent.spacing
            elide: Text.ElideRight
            text: root.st ? "for " + (root.st.name || root.st.workspace) + (root.portrait ? " · portrait display" : "") + " · " + root.st.windows + (root.st.windows === 1 ? " window" : " windows") : ""
            color: root.dim
            font.pixelSize: Style.font.bodySmall
          }
        }

        PText {
          visible: root.presets.length === 0
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.st ? "No presets yet. Press E to create some." : "Loading…"
          color: root.dim
        }

        Grid {
          id: grid
          anchors.horizontalCenter: parent.horizontalCenter
          columns: panel.columns
          spacing: panel.cardGap
          Repeater {
            model: root.presets
            delegate: Rectangle {
              id: tile
              required property var modelData
              required property int index
              readonly property bool selected: root.sel === index
              readonly property bool applied: root.st && root.st.current === modelData.name
              width: panel.cardWidth
              height: tileCol.implicitHeight + 2 * Style.space(10)
              radius: root.r
              color: selected ? Color.menu.selectedBackground : tileArea.containsMouse ? root.hoverFill : root.faint
              border.width: selected ? 2 : 1
              border.color: selected ? root.accent : root.line

              MouseArea {
                id: tileArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: { if (panel.pointerMoved) root.sel = tile.index; panel.pointerMoved = true }
                onClicked: root.applyPreset(tile.index)
              }

              Rectangle {
                id: pencil
                visible: tile.selected || tileArea.containsMouse || pencilArea.containsMouse
                z: 5
                anchors { right: parent.right; top: parent.top; margins: Style.space(14) }
                width: Style.space(26); height: Style.space(24); radius: root.r
                color: pencilArea.containsMouse ? root.accent : Qt.alpha(root.windowBg, 0.85)
                border.width: 1
                border.color: root.line
                PText {
                  anchors.centerIn: parent
                  text: "󰏫"
                  color: pencilArea.containsMouse ? root.windowBg : root.fg
                  font.pixelSize: Style.font.body
                }
                MouseArea {
                  id: pencilArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.editShown(tile.index)
                }
              }

              Column {
                id: tileCol
                x: Style.space(10); y: Style.space(10)
                width: parent.width - 2 * Style.space(10)
                spacing: Style.space(6)
                PreviewBox {
                  width: parent.width
                  portrait: root.portrait
                  preset: tile.modelData
                  count: root.previewDefault
                  ink: tile.selected ? Color.menu.selectedText : root.fg
                  tint: root.accent
                }
                Row {
                  width: parent.width
                  spacing: Style.space(6)
                  Rectangle {
                    id: badge
                    width: Style.space(20); height: width; radius: Style.space(4)
                    color: "transparent"
                    border.width: 1
                    border.color: Qt.alpha(tile.selected ? Color.menu.selectedText : root.fg, 0.4)
                    PText {
                      anchors.centerIn: parent
                      text: String(tile.index + 1)
                      color: tile.selected ? Color.menu.selectedText : root.fg
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }
                  }
                  PText {
                    anchors.verticalCenter: badge.verticalCenter
                    width: parent.width - badge.width - parent.spacing
                    elide: Text.ElideRight
                    text: tile.modelData.name + (tile.applied ? "  ●" : "")
                    color: tile.selected ? Color.menu.selectedText : root.fg
                    font.bold: true
                  }
                }
                PText {
                  width: parent.width
                  elide: Text.ElideRight
                  text: L.describe(tile.modelData)
                  color: Qt.alpha(tile.selected ? Color.menu.selectedText : root.fg, 0.65)
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        Item {
          width: parent.width
          height: Style.space(30)
          PText {
            anchors.verticalCenter: parent.verticalCenter
            text: "1-9 or Enter apply  ·  ←→↑↓ move  ·  E or 󰏫 edit this preset  ·  ● in use here  ·  Esc close"
            color: root.dim
            font.pixelSize: Style.font.caption
          }
          Btn {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            compact: true
            icon: "󰏫"
            text: "Edit presets"
            onClicked: root.editShown(root.sel)
          }
        }
      }
    }
  }

  // ======================================================================================
  // Editor window
  // ======================================================================================
  FloatingWindow {
    visible: root.editorOpen
    title: "Tiling Presets"
    color: root.windowBg
    implicitWidth: 1040
    implicitHeight: 700
    onVisibleChanged: if (!visible && root.editorOpen) root.closeEditor()

    FocusScope {
      id: editor
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        var ctrl = event.modifiers & Qt.ControlModifier
        if (event.key === Qt.Key_Escape) {
          if (root.confirmAction) root.confirmAction = null
          else root.requestCloseEditor()
          event.accepted = true
        } else if (ctrl && event.key === Qt.Key_S) {
          root.save(false); event.accepted = true
        } else if (ctrl && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
          root.save(true); event.accepted = true
        }
      }

      // ---------------- header ----------------
      Item {
        id: header
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: 60
        PText {
          x: 18; anchors.verticalCenter: parent.verticalCenter
          text: "Tiling Presets"
          font.pixelSize: Style.font.title
          font.bold: true
        }
        PText {
          anchors { right: parent.right; rightMargin: 18; verticalCenter: parent.verticalCenter }
          text: "Super + Shift + L opens the picker on the focused workspace"
          color: root.dim
          font.pixelSize: Style.font.bodySmall
        }
        PanelSeparator { anchors.bottom: parent.bottom; foreground: root.fg }
      }

      // ---------------- sidebar ----------------
      Item {
        id: sidebar
        anchors { left: parent.left; top: header.bottom; bottom: footer.top }
        width: 310
        Rectangle { anchors { right: parent.right; top: parent.top; bottom: parent.bottom } width: 1; color: root.line }

        Flickable {
          anchors { left: parent.left; right: parent.right; top: parent.top; bottom: sideActions.top; margins: 12 }
          contentHeight: list.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: list
            width: parent.width
            spacing: 4
            Repeater {
              model: root.draft || []
              delegate: Rectangle {
                id: row
                required property var modelData
                required property int index
                readonly property bool selected: root.sel === index
                width: list.width
                height: 62
                radius: root.r
                color: selected ? root.selFill : rowArea.containsMouse ? root.hoverFill : "transparent"
                MouseArea {
                  id: rowArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.sel = row.index
                }
                PreviewBox {
                  id: thumb
                  x: 8; anchors.verticalCenter: parent.verticalCenter
                  width: 72
                  portrait: row.modelData.monitor === "portrait"
                  preset: row.modelData
                  count: root.previewCount
                }
                Column {
                  anchors { left: thumb.right; leftMargin: 10; right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                  spacing: 2
                  PText {
                    width: parent.width; elide: Text.ElideRight
                    text: (row.index + 1) + "  " + (row.modelData.name.trim() || "Unnamed")
                    font.bold: true
                    color: row.modelData.name.trim() ? root.fg : root.dim
                  }
                  PText {
                    width: parent.width; elide: Text.ElideRight
                    text: L.describe(row.modelData) + L.scope(row.modelData)
                    color: root.dim
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }
        }

        Column {
          id: sideActions
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 12 }
          spacing: 6
          Btn {
            width: parent.width
            icon: "󰐕"
            text: "New preset"
            enabled: !!root.draft && root.draft.length < L.MAX_PRESETS
            onClicked: root.addPreset()
          }
          Btn {
            width: parent.width
            compact: true
            icon: "󰑐"
            text: "Restore the defaults"
            onClicked: root.ask("Replace all presets with the built-in ones? Nothing is saved until you press Save.", "Replace", function() { defaultsProc.running = true })
          }
        }
      }

      // ---------------- main ----------------
      Item {
        id: main
        anchors { left: sidebar.right; right: parent.right; top: header.bottom; bottom: footer.top; margins: 18 }

        PText {
          visible: !root.current
          anchors.centerIn: parent
          text: root.draft ? "No presets. Add one with “New preset”." : "Loading…"
          color: root.dim
        }

        Column {
          visible: !!root.current
          anchors.fill: parent
          spacing: 14

          Row {
            width: parent.width
            spacing: 8
            Field {
              id: nameField
              width: parent.width - actions.width - parent.spacing
              fontSize: Style.font.title
              placeholder: "Preset name"
              text: root.current ? root.current.name : ""
              onEdited: { var t = nameField.text; root.edit(function(d) { d[root.sel].name = t }) }
            }
            Row {
              id: actions
              spacing: 4
              anchors.verticalCenter: parent.verticalCenter
              Btn { compact: true; icon: "󰁝"; tooltip: "Move up (earlier number)"; enabled: root.sel > 0; onClicked: root.movePreset(-1) }
              Btn { compact: true; icon: "󰁅"; tooltip: "Move down (later number)"; enabled: !!root.draft && root.sel < root.draft.length - 1; onClicked: root.movePreset(1) }
              Btn { compact: true; icon: "󰆏"; tooltip: "Duplicate"; enabled: !!root.draft && root.draft.length < L.MAX_PRESETS; onClicked: root.duplicatePreset() }
              Btn { compact: true; danger: true; icon: "󰆴"; tooltip: "Delete"; onClicked: root.deletePreset() }
            }
          }

          Row {
            width: parent.width
            spacing: 22

            // ---- preview ----
            Column {
              id: previewCol
              width: 400
              spacing: 8
              PreviewBox {
                width: parent.width
                portrait: !!root.current && root.current.monitor === "portrait"
                preset: root.current
                count: root.previewCount
              }
              Row {
                spacing: 8
                PText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Preview with"
                  color: root.dim
                  font.pixelSize: Style.font.bodySmall
                }
                Btn { compact: true; text: "−"; enabled: root.previewCount > 1; onClicked: root.previewCount-- }
                PText { anchors.verticalCenter: parent.verticalCenter; text: root.previewCount + (root.previewCount === 1 ? " window" : " windows"); font.pixelSize: Style.font.bodySmall }
                Btn { compact: true; text: "+"; enabled: root.previewCount < 9; onClicked: root.previewCount++ }
              }
              PText {
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.current ? L.layoutInfo(root.current.layout).blurb : ""
                color: root.dim
                font.pixelSize: Style.font.caption
              }
            }

            // ---- options ----
            Column {
              id: options
              width: main.width - previewCol.width - 22
              spacing: 10

              Label { text: "LAYOUT" }
              Flow {
                width: parent.width
                spacing: 6
                Repeater {
                  model: L.LAYOUTS
                  delegate: Btn {
                    required property var modelData
                    text: modelData.label
                    checked: root.current && root.current.layout === modelData.id
                    onClicked: root.edit(function(d) { d[root.sel].layout = modelData.id })
                  }
                }
              }

              Label { text: "OFFERED ON" }
              Flow {
                width: parent.width
                spacing: 6
                Repeater {
                  model: L.MONITORS
                  delegate: Btn {
                    required property var modelData
                    text: modelData.label
                    checked: root.current && (root.current.monitor || "any") === modelData.id
                    onClicked: root.edit(function(d) { d[root.sel].monitor = modelData.id })
                  }
                }
              }

              // master
              Column {
                visible: !!root.current && root.current.layout === "master"
                width: parent.width
                spacing: 10
                Label { text: "MAIN WINDOW GOES" }
                Flow {
                  width: parent.width
                  spacing: 6
                  Repeater {
                    model: L.ORIENTATIONS
                    delegate: Btn {
                      required property string modelData
                      text: L.cap(modelData)
                      checked: root.current && root.current.orientation === modelData
                      onClicked: root.edit(function(d) { d[root.sel].orientation = modelData })
                    }
                  }
                }
                Label { text: "MAIN WINDOW SIZE" }
                Row {
                  spacing: 10
                  Slider {
                    width: 220
                    from: 0.1; to: 0.9; step: 0.05
                    value: root.current ? root.current.ratio : 0.55
                    onMoved: function(v) { root.edit(function(d) { d[root.sel].ratio = v }) }
                  }
                  PText { anchors.verticalCenter: parent.verticalCenter; text: root.current ? L.percent(root.current.ratio) : ""; font.bold: true }
                }
              }

              // scrolling
              Column {
                visible: !!root.current && root.current.layout === "scrolling"
                width: parent.width
                spacing: 10
                Label { text: "NEW WINDOWS APPEAR TO THE" }
                Flow {
                  width: parent.width
                  spacing: 6
                  Repeater {
                    model: L.DIRECTIONS
                    delegate: Btn {
                      required property string modelData
                      text: L.cap(modelData)
                      checked: root.current && root.current.direction === modelData
                      onClicked: root.edit(function(d) { d[root.sel].direction = modelData })
                    }
                  }
                }
                Label { text: "COLUMN WIDTH" }
                Row {
                  spacing: 10
                  Slider {
                    width: 220
                    from: 0.1; to: 1; step: 0.05
                    value: root.current ? root.current.columnWidth : 0.5
                    onMoved: function(v) { root.edit(function(d) { d[root.sel].columnWidth = v }) }
                  }
                  PText { anchors.verticalCenter: parent.verticalCenter; text: root.current ? L.percent(root.current.columnWidth) : ""; font.bold: true }
                }
              }

              PText {
                visible: !!root.current && (root.current.layout === "dwindle" || root.current.layout === "monocle")
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Nothing else to set for this layout."
                color: root.dim
                font.pixelSize: Style.font.caption
              }
            }
          }

          Item { width: 1; height: 4 }
          Label { text: "HOTKEYS" }
          PText {
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.dim
            font.pixelSize: Style.font.caption
            lineHeight: 1.3
            text: "• Super + Shift + L opens the picker; press a preset's number (1-9) to apply it at once. It lists the presets\n"
                + "   offered on the focused monitor, so a portrait monitor sees the portrait and any-monitor ones, numbered from 1.\n"
                + "• To give a preset its own key, bind this in ~/.config/hypr/bindings.lua:\n"
                + "     o.bind(\"SUPER + ALT + 1\", \"Tiling preset\", \"tiling-preset apply 1\")      (a number among those shown, or the preset's name)\n"
                + "• Applying a preset sticks to the workspace until you pick another layout (Super + L also replaces it).\n"
                + "• The size of the main window is not remembered across a Hyprland reload; the layout and its direction are."
          }
        }
      }

      // ---------------- footer ----------------
      Rectangle {
        id: footer
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 56
        color: "transparent"
        PanelSeparator { anchors.top: parent.top; foreground: root.fg }
        PText {
          anchors { left: parent.left; leftMargin: 18; right: actionRow.left; rightMargin: 16; verticalCenter: parent.verticalCenter }
          text: root.problems.length ? root.problems[0] : (root.status || (root.dirty ? "●  Unsaved changes" : ""))
          color: root.problems.length || root.statusError ? root.red : root.dirty && !root.status ? root.accent : root.fg
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        Row {
          id: actionRow
          anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
          spacing: 8
          Btn { text: "Discard"; enabled: root.dirty; onClicked: root.adoptSaved() }
          Btn { text: "Save"; enabled: root.dirty && root.problems.length === 0; onClicked: root.save(false) }
          Btn {
            primary: true
            text: root.dirty ? "Save & Apply" : "Apply"
            enabled: !!root.current && root.problems.length === 0
            tooltip: "Apply the selected preset to the focused workspace"
            onClicked: root.dirty ? root.save(true) : Quickshell.execDetached([root.script, "apply", root.current.name.trim()])
          }
        }
      }

      // ---------------- confirm ----------------
      Rectangle {
        anchors.fill: parent
        visible: root.confirmAction !== null
        z: 100
        color: Color.menu.scrim
        MouseArea { anchors.fill: parent; onClicked: root.confirmAction = null }
        BorderSurface {
          anchors.centerIn: parent
          width: 420; height: confirmCol.implicitHeight + 40
          radius: root.r; color: Color.popups.background; borderSpec: root.popupBorder
          MouseArea { anchors.fill: parent }
          Column {
            id: confirmCol
            anchors.centerIn: parent
            width: parent.width - 40
            spacing: 18
            PText { width: parent.width; wrapMode: Text.WordWrap; text: root.confirmText; font.pixelSize: Style.font.title }
            Row {
              anchors.right: parent.right
              spacing: 8
              Btn { text: "Cancel"; onClicked: root.confirmAction = null }
              Btn { primary: true; text: root.confirmOk; onClicked: { var fn = root.confirmAction; root.confirmAction = null; if (fn) fn() } }
            }
          }
        }
      }
    }
  }

  component Label: PanelSectionHeader {
    foreground: root.fg
    fontFamily: root.font
  }
}
