import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The launcher overlay. Searching, ranking and acting live in the Python
// backend (bin/launcher serve), which this talks to over stdin/stdout; this
// file draws what it gets and handles the keyboard.
//
//   settings  ~/.config/omarchy/omarchy-launcher.json   (shared with the backend)
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: String(Quickshell.env("HOME") || "")
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, ""))
  readonly property string backendBin: pluginDir + "bin/launcher"
  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null

  // ---- Look (Omarchy's menu tokens, so themes that style the menu style this) --
  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color border: Commons.Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Commons.Color.menu.scrim
  property color selectedBackground: Commons.Color.menu.selectedBackground
  property color selectedText: Commons.Color.menu.selectedText
  property color selectedBorder: Commons.Color.menu.selectedBorder
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int headerHeight: Math.max(Style.space(38), Style.font.display + Style.spacing.controlPaddingY * 2)
  readonly property int footerHeight: Math.max(Style.space(26), Style.font.bodySmall + Style.spacing.controlPaddingY * 2)
  readonly property int rowHeight: showSubtitles
    ? Math.max(Style.space(54), Style.font.heading + Style.font.bodySmall + Style.spacing.rowPaddingX * 2)
    : Math.max(Style.space(42), Style.font.heading + Style.spacing.rowPaddingX * 2)
  readonly property int sectionHeight: Style.space(24)

  // ---- Settings ------------------------------------------------------------------
  property var settings: ({})
  function look(group, key, fallback) {
    var g = settings[group]
    return g && g[key] !== undefined && g[key] !== null ? g[key] : fallback
  }
  readonly property int cardWidthSetting: Math.max(480, Math.min(1400, Number(look("general", "width", 760)) || 760))
  readonly property int rowsSetting: Math.max(4, Math.min(20, Number(look("general", "rows", 9)) || 9))
  readonly property bool atTop: look("general", "position", "top") !== "center"
  readonly property bool showSubtitles: look("general", "showSubtitles", true) !== false
  readonly property bool rememberQuery: look("general", "rememberQuery", false) === true

  FileView {
    path: root.home + "/.config/omarchy/omarchy-launcher.json"
    printErrors: false
    watchChanges: true
    onLoaded: {
      try { root.settings = JSON.parse(text()) || {} } catch (e) { root.settings = {} }
    }
    onFileChanged: reload()
    onLoadFailed: root.settings = ({})
  }

  // ---- State ---------------------------------------------------------------------
  property bool opened: false
  property string page: "list"          // list | detail | form
  property string filterText: ""
  onFilterTextChanged: if (filterInput.text !== filterText) filterInput.text = filterText
  property var results: []
  property int selectedIndex: 0
  property int seq: 0
  property int shownSeq: -1
  property bool searching: false

  // An item asking for its argument ("Search GitHub for…").
  property var argItem: null            // {item, action, title, placeholder}
  property string queryBeforeArg: ""

  // Actions of the selected result; loaded as the selection moves so their
  // shortcuts work without opening the list.
  property var actions: []
  property string actionsFor: ""
  property bool actionsOpen: false
  property int actionIndex: 0
  property int actionsSeq: 0

  property var detail: null             // {title, text, format, stream, actions, item, icon, status, done}
  property var form: null               // {id, title, fields, submit, icon}
  property string queryBeforePage: ""

  property string toastText: ""
  property bool toastError: false

  // Rows for the ListView (it needs a real model for its section headers);
  // each row's data is root.results[index].
  ListModel { id: resultModel }

  // Ask Claude's conversation window; it outlives the overlay.
  ChatWindow { id: chatWindow; launcher: root; agent: "claude" }
  ChatWindow { id: openCodeWindow; launcher: root; agent: "opencode" }

  readonly property var selected: results.length > 0 && selectedIndex >= 0 && selectedIndex < results.length ? results[selectedIndex] : null
  onSelectedChanged: actionsTimer.restart()

  // ---- Lifecycle (called by the shell) ---------------------------------------------
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) { payload = ({}) }
    root.page = "list"
    root.argItem = null
    root.actionsOpen = false
    root.detail = null
    root.form = null
    root.toastText = ""
    root.opened = true
    root.sendApps()
    root.send({ op: "open" })
    if (payload.query !== undefined) root.setFilter(String(payload.query))
    else if (!root.rememberQuery) root.setFilter("")
    else root.search()
    if (root.appLibrary) root.appLibrary.refreshIcons()
    Qt.callLater(function() { filterInput.forceActiveFocus() })
  }

  function close() {
    if (root.detail && root.detail.stream) root.send({ op: "stop" })
    root.opened = false
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "jvdp.launcher")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---- Backend -----------------------------------------------------------------------
  function send(obj) {
    if (backend.running) backend.write(JSON.stringify(obj) + "\n")
  }

  // Sent on every open as well: at shell start the app list can still be
  // empty, and an empty list here would hide every app until a change.
  function sendApps() {
    var entries = root.appLibrary ? root.appLibrary.sortedEntries("") : []
    // Omarchy's library (hidden entries filtered) when there is one, else
    // Quickshell's own list of desktop entries.
    if (!entries || entries.length === 0) entries = DesktopEntries.applications.values || []
    var apps = []
    for (var i = 0; i < entries.length; i++) {
      // The library hands out rows ({entry, score, …}); Quickshell, entries.
      var e = entries[i] && entries[i].entry ? entries[i].entry : entries[i]
      if (!e || !e.id) continue
      var acts = []
      try {
        for (var j = 0; j < (e.actions || []).length; j++) {
          var a = e.actions[j]
          acts.push({ id: String(a.id || ""), name: String(a.name || ""), icon: String(a.icon || "") })
        }
      } catch (err) {}
      var keywords = []
      try { if (e.keywords) for (var k = 0; k < e.keywords.length; k++) keywords.push(String(e.keywords[k])) } catch (err2) {}
      apps.push({
        id: String(e.id), name: String(e.name || e.id), generic: String(e.genericName || ""),
        comment: String(e.comment || ""), icon: String(e.icon || ""), keywords: keywords,
        exec: String(e.execString || ""), actions: acts
      })
    }
    root.send({ op: "apps", apps: apps })
  }

  Connections {
    target: root.appLibrary
    ignoreUnknownSignals: true
    function onAppsChanged() { appsTimer.restart() }
  }
  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { appsTimer.restart() }
  }
  Timer { id: appsTimer; interval: 500; onTriggered: root.sendApps() }

  Process {
    id: backend
    command: [root.backendBin, "serve"]
    running: true
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.onBackend(line) } }
    stderr: SplitParser { onRead: function(line) { console.warn("jvdp.launcher backend: " + line) } }
    onExited: restartTimer.restart()
  }
  // A crashed backend comes back; the overlay keeps working meanwhile.
  Timer { id: restartTimer; interval: 1500; onTriggered: backend.running = true }

  function onBackend(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (!msg || !msg.op) return
    if (msg.op === "hello") {
      root.sendApps()
      if (root.opened) root.search()
    } else if (msg.op === "results") {
      if (msg.seq !== root.seq) return
      var keepId = msg.seq === root.shownSeq && root.selected ? root.selected.id : ""
      root.results = msg.items || []
      resultModel.clear()
      for (var r = 0; r < root.results.length; r++)
        resultModel.append({ rowId: String(root.results[r].id), section: String(root.results[r].section || "") })
      var idx = 0
      if (keepId) for (var i = 0; i < root.results.length; i++) if (root.results[i].id === keepId) { idx = i; break }
      root.selectedIndex = idx
      root.shownSeq = msg.seq
      root.searching = !msg.done
      Qt.callLater(function() { if (resultList.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain) })
    } else if (msg.op === "actions") {
      if (msg.seq !== root.actionsSeq) return
      root.actions = msg.actions || []
      root.actionsFor = msg.id
    } else if (msg.op === "do") {
      root.perform(msg.steps || [])
    } else if (msg.op === "chat") {
      (msg.agent === "opencode" ? openCodeWindow : chatWindow).onBackend(msg)
    } else if (msg.op === "stream") {
      if (!root.detail || root.detail.stream !== msg.stream) return
      var d = Object.assign({}, root.detail)
      if (msg.text !== undefined) d.text = msg.text
      if (msg.status !== undefined) d.status = msg.status
      if (msg.done) d.done = true
      root.detail = d
    }
  }

  // ---- Searching ---------------------------------------------------------------------
  function setFilter(text) {
    root.filterText = text
    root.selectedIndex = 0
    if (!root.argItem) root.search()
  }

  function search() {
    root.seq += 1
    root.searching = true
    root.send({ op: "query", seq: root.seq, q: root.filterText })
  }

  Timer {
    id: actionsTimer
    interval: 60
    onTriggered: root.loadActions()
  }

  function loadActions() {
    if (!root.selected) { root.actions = []; root.actionsFor = ""; return }
    if (root.actionsFor === root.selected.id) return
    root.actionsSeq += 1
    root.send({ op: "actions", seq: root.actionsSeq, id: root.selected.id })
  }

  function select(delta) {
    if (root.results.length === 0) return
    root.selectedIndex = Math.max(0, Math.min(root.results.length - 1, root.selectedIndex + delta))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  // ---- Acting ------------------------------------------------------------------------
  function runSelected(actionId) {
    var it = root.selected
    if (!it) return
    if (root.argItem) {
      root.send({ op: "run", id: root.argItem.item, action: root.argItem.action, arg: root.filterText })
      return
    }
    root.send({ op: "run", id: it.id, action: actionId || "default", arg: null })
  }

  function runAction(act) {
    root.actionsOpen = false
    if (!act) return
    if (root.page === "detail") {
      // The page's own actions; "copy" copies what is on it.
      if (act.id === "copy") {
        root.send({ op: "copy", text: root.detail ? root.detail.text : "" })
        root.showToast("Copied", false)
        return
      }
      if (root.detail && root.detail.item) root.send({ op: "run", id: root.detail.item, action: act.id, arg: null })
      return
    }
    root.runSelected(act.id)
  }

  function perform(steps) {
    for (var i = 0; i < steps.length; i++) {
      var st = steps[i]
      if (st.type === "close") {
        root.dismiss()
      } else if (st.type === "toast") {
        root.showToast(st.text, st.error === true, st.sticky === true)
      } else if (st.type === "query") {
        root.leavePage()
        root.argItem = null
        root.setFilter(st.q)
      } else if (st.type === "refresh") {
        root.actionsFor = ""
        if (root.page === "list") root.search()
      } else if (st.type === "chat") {
        (st.agent === "opencode" ? openCodeWindow : chatWindow).ask(st.q)
      } else if (st.type === "launch-app") {
        root.launchApp(st.appId, st.name, st.action)
      } else if (st.type === "detail") {
        root.enterPage("detail")
        root.detail = { title: st.title, text: st.text || "", format: st.format || "plain", stream: st.stream || "",
                        actions: st.actions || [], item: st.item || "", icon: st.icon || "", status: "",
                        done: !st.stream }
        root.actions = root.detail.actions
        detailView.scrollTop()
      } else if (st.type === "form") {
        root.enterPage("form")
        root.form = st.form
        Qt.callLater(function() { formView.begin() })
      } else if (st.type === "arg") {
        root.queryBeforeArg = root.filterText
        root.argItem = { item: st.item, action: st.action || "default", title: st.title || "", placeholder: st.placeholder || "" }
        root.filterText = ""
      }
    }
  }

  function launchApp(appId, name, actionId) {
    if (actionId) {
      var entry = DesktopEntries.byId(appId)
      if (entry) {
        for (var i = 0; i < (entry.actions || []).length; i++) {
          if (String(entry.actions[i].id) === actionId) { entry.actions[i].execute(); return }
        }
      }
    }
    if (root.appLibrary) root.appLibrary.launch(appId, name)
    else Util.execArgv(["uwsm-app", "--", "gtk-launch", appId + ".desktop"])
  }

  function enterPage(name) {
    if (root.page === "list") root.queryBeforePage = root.filterText
    root.page = name
    root.actionsOpen = false
  }

  function leavePage() {
    if (root.page === "detail" && root.detail && root.detail.stream && !root.detail.done) root.send({ op: "stop" })
    if (root.page !== "list") {
      root.page = "list"
      root.detail = null
      root.form = null
      root.actionsFor = ""
      root.filterText = root.queryBeforePage
      Qt.callLater(function() { filterInput.forceActiveFocus() })
    }
  }

  function back() {
    if (root.actionsOpen) { root.actionsOpen = false; return }
    if (root.page !== "list") { root.leavePage(); root.search(); return }
    if (root.argItem) {
      root.argItem = null
      root.setFilter(root.queryBeforeArg)
      return
    }
    if (root.filterText) { root.setFilter(""); return }
    root.dismiss()
  }

  function showToast(text, error, sticky) {
    root.toastText = String(text || "")
    root.toastError = error
    // A sticky toast ("Unlocking…") stays until the next one replaces it.
    if (sticky) toastTimer.stop()
    else toastTimer.restart()
  }
  Timer { id: toastTimer; interval: 2800; onTriggered: root.toastText = "" }

  // "ctrl+shift+c" for a key event, to match the actions' shortcuts.
  function shortcutOf(event) {
    var mods = []
    if (event.modifiers & Qt.ControlModifier) mods.push("ctrl")
    if (event.modifiers & Qt.ShiftModifier) mods.push("shift")
    if (event.modifiers & Qt.AltModifier) mods.push("alt")
    var key = ""
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) key = "enter"
    else if (event.key >= Qt.Key_A && event.key <= Qt.Key_Z) key = String.fromCharCode(event.key).toLowerCase()
    else if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9) key = String.fromCharCode(event.key)
    else if (event.key === Qt.Key_Comma) key = ","
    else if (event.key === Qt.Key_Delete) key = "delete"
    else return ""
    return mods.length ? mods.join("+") + "+" + key : key
  }

  function actionForShortcut(sc) {
    if (!sc || sc.indexOf("ctrl") !== 0 && sc.indexOf("alt") !== 0) return null
    for (var i = 0; i < root.actions.length; i++)
      if (root.actions[i].shortcut === sc) return root.actions[i]
    return null
  }

  function primaryTitle() {
    if (root.argItem) return "Go"
    if (root.page === "detail") return ""
    if (root.actions.length > 0 && root.selected && root.actionsFor === root.selected.id) return root.actions[0].title
    return root.selected ? "Open" : ""
  }

  function handleKey(event) {
    if (root.actionsOpen) {
      if (event.key === Qt.Key_Escape || event.key === Qt.Key_Tab || (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier))) {
        root.actionsOpen = false
      } else if (event.key === Qt.Key_Up) {
        root.actionIndex = Math.max(0, root.actionIndex - 1)
      } else if (event.key === Qt.Key_Down) {
        root.actionIndex = Math.min(root.actions.length - 1, root.actionIndex + 1)
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        root.runAction(root.actions[root.actionIndex])
      } else {
        var hit = root.actionForShortcut(root.shortcutOf(event))
        if (hit) root.runAction(hit)
      }
      event.accepted = true
      return
    }

    var sc = root.shortcutOf(event)
    if (event.key === Qt.Key_Escape) {
      root.back()
    } else if (event.key === Qt.Key_Tab || (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier))) {
      if (root.actions.length > 0 && (root.page === "detail" || (root.selected && root.actionsFor === root.selected.id))) {
        root.actionIndex = 0
        root.actionsOpen = true
      }
    } else if (event.key === Qt.Key_Comma && (event.modifiers & Qt.ControlModifier)) {
      root.send({ op: "run", id: "launcher:settings", action: "default", arg: null })
    } else if (root.page === "detail") {
      var hitD = root.actionForShortcut(sc)
      if (hitD) root.runAction(hitD)
      else if (event.key === Qt.Key_Up) detailView.scrollBy(-Style.space(40))
      else if (event.key === Qt.Key_Down) detailView.scrollBy(Style.space(40))
      else if (event.key === Qt.Key_PageUp) detailView.scrollBy(-detailView.height * 0.9)
      else if (event.key === Qt.Key_PageDown) detailView.scrollBy(detailView.height * 0.9)
      else if (event.key === Qt.Key_Backspace) root.back()
      else return
    } else if (Util.editsFilter(event, root.filterText)) {
      root.setFilter(Util.editedFilter(event, root.filterText))
    } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier) && !root.actionForShortcut(sc))) {
      root.select(-1)
    } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier) && !root.actionForShortcut(sc))) {
      root.select(1)
    } else if (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier) && !root.actionForShortcut(sc)) {
      root.select(1)
    } else if (event.key === Qt.Key_PageUp) {
      root.select(-root.rowsSetting + 1)
    } else if (event.key === Qt.Key_PageDown) {
      root.select(root.rowsSetting - 1)
    } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier))) {
      if (root.argItem || root.selected) root.runSelected("default")
    } else if (root.actionForShortcut(sc) && !root.argItem) {
      root.runAction(root.actionForShortcut(sc))
    } else if (event.key === Qt.Key_Backspace && !root.filterText && root.argItem) {
      root.back()
    } else {
      return
    }
    event.accepted = true
  }

  // ---- The overlay -------------------------------------------------------------------
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "jvdp-launcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    readonly property int cardWidth: Math.min(Style.space(root.cardWidthSetting), width - Style.gapsOut * 2)
    readonly property int listHeight: root.rowsSetting * (root.rowHeight + Style.spacing.xs)
    readonly property int cardHeight: Math.min(
      root.contentMargin * 2 + card.borderTop + card.borderBottom + root.headerHeight + Style.spacing.md * 2
        + Style.spacing.hairline + listHeight + root.footerHeight,
      height - Style.gapsOut * 2)

    BorderSurface {
      id: card
      width: panel.cardWidth
      height: panel.cardHeight
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      // Upper third: the search line stays put as results come and go.
      y: root.atTop ? Math.max(Style.gapsOut, Math.round(panel.height * 0.16)) : Math.round((panel.height - height) / 2)
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        Keys.onPressed: function(event) { root.handleKey(event) }
      }

      Column {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        // Search line ---------------------------------------------------------------
        Item {
          width: parent.width
          height: root.headerHeight

          Rectangle {
            id: chip
            visible: root.page !== "list" || !!root.argItem
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            height: chipText.implicitHeight + Style.spacing.sm * 2
            width: visible ? Math.min(parent.width * 0.6, chipText.implicitWidth + Style.spacing.lg * 2) : 0
            radius: root.cornerRadius
            color: Util.alpha(root.accent, 0.16)

            Text {
              id: chipText
              textFormat: Text.PlainText
              anchors.centerIn: parent
              width: Math.min(implicitWidth, parent.width - Style.spacing.lg * 2)
              text: root.argItem ? root.argItem.title
                : root.page === "detail" && root.detail ? (root.detail.icon ? root.detail.icon + "  " : "") + root.detail.title
                : root.page === "form" && root.form ? (root.form.icon ? root.form.icon + "  " : "") + root.form.title : ""
              color: root.selectedText
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.weight: Font.Medium
              elide: Text.ElideRight
            }
          }

          Text {
            id: searchGlyph
            visible: !chip.visible
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "󰍉"
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.display * 0.75
          }

          FilterInput {
            id: filterInput
            anchors.left: chip.visible ? chip.right : searchGlyph.right
            anchors.leftMargin: Style.spacing.lg
            anchors.right: busy.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            keyHandler: keyCatcher
            readOnly: root.page !== "list"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display * 0.75
            onTextChanged: if (text !== root.filterText && root.page === "list") root.setFilter(text)
          }

          Text {
            textFormat: Text.PlainText
            anchors.fill: filterInput
            verticalAlignment: Text.AlignVCenter
            visible: !root.filterText && !filterInput.preeditText && root.page === "list"
            text: root.argItem ? (root.argItem.placeholder || "…") : "Search apps, commands, files…"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.display * 0.75
            elide: Text.ElideRight
          }

          Text {
            id: busy
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(18)
            horizontalAlignment: Text.AlignRight
            text: "󰔟"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            opacity: (root.searching && root.page === "list") || (root.page === "detail" && root.detail && !root.detail.done) ? 0.5 : 0
            Behavior on opacity { NumberAnimation { duration: 150 } }
          }
        }

        Rectangle {
          width: parent.width
          height: Style.spacing.hairline
          color: Util.alpha(root.foreground, 0.12)
        }

        // Results ------------------------------------------------------------------------
        Item {
          width: parent.width
          height: panel.listHeight

          ListView {
            id: resultList
            anchors.fill: parent
            visible: root.page === "list"
            model: resultModel
            clip: true
            spacing: Style.spacing.xs
            boundsBehavior: Flickable.StopAtBounds
            highlightMoveDuration: 0
            currentIndex: root.selectedIndex

            section.property: "section"
            section.criteria: ViewSection.FullString
            section.delegate: Item {
              required property string section
              width: ListView.view.width
              height: section === "Favourites" || section === "Recent" || section === "Suggested" ? root.sectionHeight : (section === "fallback" ? Style.space(9) : 0)
              visible: height > 0

              Text {
                visible: parent.section !== "fallback"
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.space(3)
                text: parent.section
                color: root.foreground
                opacity: 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.weight: Font.Medium
                font.capitalization: Font.AllUppercase
              }

              Rectangle {
                visible: parent.section === "fallback"
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                height: Style.spacing.hairline
                color: Util.alpha(root.foreground, 0.12)
              }
            }

            delegate: ResultRow {
              required property int index
              entry: (index >= 0 && index < root.results.length && root.results[index]) || ({})
              width: ListView.view.width
              height: root.rowHeight
              launcher: root
              current: index === root.selectedIndex
              onHoveredRow: root.selectedIndex = index
              onActivated: {
                root.selectedIndex = index
                root.runSelected("default")
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: root.page === "list" && root.results.length === 0 && !root.searching

            Text {
              textFormat: Text.PlainText
              text: root.filterText ? "󰈉" : "󱓞"
              color: root.selectedText
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: Style.space(360)
            }

            Text {
              textFormat: Text.PlainText
              text: root.argItem ? "Type, then Enter"
                : root.filterText ? "Nothing found for “" + root.filterText + "”"
                : "Type to search · Ctrl+, settings"
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: Style.space(360)
              wrapMode: Text.WordWrap
            }
          }

          DetailView {
            id: detailView
            anchors.fill: parent
            visible: root.page === "detail"
            launcher: root
          }

          FormView {
            id: formView
            anchors.fill: parent
            visible: root.page === "form"
            launcher: root
          }

          ActionsPopup {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            visible: root.actionsOpen
            launcher: root
          }
        }

        // Footer ---------------------------------------------------------------------------
        Item {
          width: parent.width
          height: root.footerHeight

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: hints.left
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            text: root.toastText ? root.toastText
              : root.page === "detail" && root.detail && root.detail.status ? root.detail.status
              : root.page === "form" ? "Tab / ↑↓ move · ←→ change · Ctrl+S save · Esc back"
              : root.selected ? (root.selected.subtitle && !root.showSubtitles ? root.selected.subtitle : "") : ""
            color: root.toastText && root.toastError ? root.urgent : root.foreground
            opacity: root.toastText ? 0.95 : 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Row {
            id: hints
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xl

            KeyHint { launcher: root; keys: "↵"; label: root.primaryTitle(); visible: label.length > 0 && root.page !== "form" }
            KeyHint { launcher: root; keys: "⇥"; label: "Actions"; visible: root.page !== "form" && root.actions.length > 1 }
            KeyHint { launcher: root; keys: "Ctrl+S"; label: root.form ? (root.form.submit || "Save") : "Save"; visible: root.page === "form" }
          }
        }
      }
    }
  }
}
