import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import "Logic.js" as L

// Displays & Workspaces: one place to arrange monitors, place/number/rename workspaces
// and manage profiles. All persistence and applying is done by `omarchy-display-profiles`.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  readonly property color bg: Qt.rgba(Color.menu.background.r, Color.menu.background.g, Color.menu.background.b, 1)
  readonly property color fg: Color.menu.text
  readonly property color accent: Color.accent
  readonly property color red: Color.urgent
  readonly property string font: Style.font.menuFamily
  readonly property color dim: Qt.alpha(fg, 0.55)
  readonly property color faint: Qt.alpha(fg, 0.08)

  // ---- backend state ------------------------------------------------------
  property var st: null
  readonly property var connected: st ? st.connected : []
  property var pendingCatalog: null
  readonly property var catalog: pendingCatalog || (st ? st.catalog.workspaces : [])
  readonly property var profiles: st ? st.profiles : []
  readonly property string activeProfile: st && st.active ? st.active : ""
  readonly property string detectedProfile: st && st.detected ? st.detected : ""

  // ---- editing ------------------------------------------------------------
  property var draft: null
  property string savedCanon: ""
  property string originalName: ""
  readonly property bool isNew: draft !== null && originalName === ""
  readonly property bool dirty: draft !== null && (isNew || pendingCatalog !== null || L.canon(L.stripTransient(draft)) !== savedCanon)
  readonly property var check: draft ? L.problems(draft) : ({ errors: [], warnings: [] })
  readonly property var columns: draft ? L.spatialOrder(draft.monitors).concat([-1]) : []
  readonly property var notInProfile: {
    if (!draft) return []
    var used = draft.monitors.map(function(m) { return m._live })
    return connected.filter(function(c) { return used.indexOf(c.name) < 0 })
  }

  property int selMonitor: -1
  property string selWorkspace: ""
  property string renaming: ""
  property var guides: []

  property string status: ""
  property bool statusError: false
  property bool identify: false
  property int tryLeft: 0

  // modal state
  property string confirmText: ""
  property string confirmOk: ""
  property var confirmAction: null
  property string pickerTitle: ""
  property var pickerItems: []
  property var pickerPick: null
  property var pickerCustom: null
  property string pickerCustomHint: ""

  // workspace drag
  property string dragName: ""
  property point dragPoint: Qt.point(0, 0)
  property int dropMonitor: -2   // -2 none, -1 parked, >=0 monitor index
  property int dropBefore: -1

  // ---- helpers --------------------------------------------------------------
  function setStatus(text, error) { status = text; statusError = !!error }
  function fail(err) { setStatus(String(err || "Something went wrong.").trim(), true) }
  function title(n) { return L.title(n) }
  function liveFor(m) {
    if (!m || !m._live) return null
    for (var i = 0; i < connected.length; i++) if (connected[i].name === m._live) return connected[i]
    return null
  }
  function colorFor(index, alpha) { return Qt.hsla(L.hue(index), 0.55, 0.62, alpha) }
  function catalogEntry(name) {
    for (var i = 0; i < catalog.length; i++) if (catalog[i].name === name) return catalog[i]
    return null
  }
  function edit(fn) { var d = L.clone(draft); fn(d); draft = d }
  function uniqueName(base) {
    var names = profiles.map(function(p) { return p.name })
    if (names.indexOf(base) < 0) return base
    for (var i = 2; i < 100; i++) if (names.indexOf(base + "-" + i) < 0) return base + "-" + i
    return base + "-x"
  }
  function ask(text, ok, action) { confirmText = text; confirmOk = ok; confirmAction = action }
  function pick(titleText, items, fn) { pickerCustom = null; pickerTitle = titleText; pickerItems = items; pickerPick = fn }

  // ---- jobs ---------------------------------------------------------------
  property var queue: []
  readonly property bool busy: job.running || queue.length > 0

  function run(args, cb) {
    queue = queue.concat([{ args: args, cb: cb }])
    Qt.callLater(nextJob)
  }

  // Keep the window on-screen: changing a monitor's resolution/scale can leave it
  // partly or fully off the display it sits on. Re-centre after any layout change.
  Process { id: centerProc }
  function centerSelf() {
    if (!opened) return
    centerProc.command = ["hyprctl", "dispatch", "hl.dsp.window.center({ window = \"title:Displays & Workspaces\" })"]
    centerProc.running = true
  }
  Timer { id: centerTimer; interval: 250; repeat: false; onTriggered: root.centerSelf() }
  function nextJob() {
    if (job.running || !queue.length) return
    var next = queue[0]
    queue = queue.slice(1)
    job.cb = next.cb
    job.command = ["omarchy-display-profiles"].concat(next.args)
    job.running = true
  }

  Process {
    id: job
    property var cb: null
    stdout: StdioCollector { id: jobOut; waitForEnd: true }
    stderr: StdioCollector { id: jobErr; waitForEnd: true }
    onExited: function(code, exitStatus) {
      var cb = job.cb
      job.cb = null
      var out = String(jobOut.text || ""), err = String(jobErr.text || "")
      if (cb) {
        try { cb(code === 0, out, err) } catch (e) { root.fail("Internal error: " + e) }
      }
      Qt.callLater(root.nextJob)
    }
  }

  function refresh(then) {
    run(["state"], function(ok, out, err) {
      if (!ok) { fail(err || "Could not read display state."); return }
      try { st = JSON.parse(out) } catch (e) { fail("Bad state from backend: " + e); return }
      if (then) then()
    })
  }

  // ---- profile selection ----------------------------------------------------
  function findProfile(name) {
    for (var i = 0; i < profiles.length; i++) if (profiles[i].name === name) return profiles[i]
    return null
  }

  function loadDraft(d, original) {
    draft = d
    originalName = original
    savedCanon = original ? L.canon(L.stripTransient(d)) : ""
    pendingCatalog = null
    selMonitor = -1
    selWorkspace = ""
    renaming = ""
  }

  function selectProfile(name, force) {
    if (!force && dirty && draft && name !== draft.name) {
      ask("Discard unsaved changes to “" + title(draft.name) + "”?", "Discard", function() { selectProfile(name, true) })
      return
    }
    var p = findProfile(name)
    if (!p) return
    var d = L.clone(p)
    d.monitors.forEach(function(m, i) { m._live = (p.status && p.status.matched[i]) || "" })
    delete d.status
    loadDraft(d, p.name)
  }

  function newFromCurrent(force) {
    if (!force && dirty) { ask("Discard unsaved changes?", "Discard", function() { newFromCurrent(true) }); return }
    if (!st) return
    var d = L.clone(st.current)
    d.name = uniqueName("new-profile")
    d.monitors.forEach(function(m) { m._live = m.match.output })
    loadDraft(d, "")
    setStatus("New profile from the connected displays. Name it, arrange, then Save.")
  }

  function duplicateProfile() {
    if (!draft) return
    var d = L.clone(draft)
    d.name = uniqueName(draft.name + "-copy")
    loadDraft(d, "")
    setStatus("Duplicated. Rename it and Save.")
  }

  function revertDraft() {
    if (isNew) { if (activeProfile) selectProfile(activeProfile, true); else newFromCurrent(true) }
    else selectProfile(originalName, true)
    setStatus("Changes discarded.")
  }

  function initialSelection() {
    var name = activeProfile || detectedProfile || (profiles.length ? profiles[0].name : "")
    if (name) selectProfile(name, true)
    else newFromCurrent(true)
  }

  // ---- save / apply / try ------------------------------------------------
  function saveDraft(andApply) {
    if (!draft) return
    if (check.errors.length) { fail(check.errors[0]); return }
    var doc = L.stripTransient(draft)
    var args = ["save", JSON.stringify(doc)]
    if (!isNew && originalName !== draft.name) args = args.concat(["--rename-from", originalName])
    var name = draft.name
    setStatus(andApply ? "Saving and applying…" : "Saving…")
    if (pendingCatalog) {
      var pending = pendingCatalog
      run(["catalog-save", JSON.stringify({ workspaces: pending, renames: {} })], function(ok, out, err) {
        if (!ok) { fail(err); return }
        pendingCatalog = null
        saveDraft(andApply)
      })
      return
    }
    run(args, function(ok, out, err) {
      if (!ok) { fail(err); return }
      tryLeft = 0
      var keepMonitor = selMonitor, keepWorkspace = selWorkspace
      var reload = function() {
        refresh(function() {
          selectProfile(name, true)
          if (keepMonitor >= 0 && draft && keepMonitor < draft.monitors.length) selMonitor = keepMonitor
          if (keepWorkspace && catalogEntry(keepWorkspace)) selWorkspace = keepWorkspace
        })
      }
      if (andApply) applyNamed(name, reload)
      else { setStatus("Saved “" + title(name) + "”."); reload() }
    })
  }

  function applyNamed(name, then) {
    setStatus("Applying “" + title(name) + "”…")
    run(["apply", name], function(ok, out, err) {
      if (!ok) { fail(err); return }
      var r = {}
      try { r = JSON.parse(out) } catch (e) {}
      var parts = ["Applied “" + title(name) + "”"]
      if (r.moved) parts.push(r.moved + " window" + (r.moved === 1 ? "" : "s") + " moved")
      if (r.missing && r.missing.length) parts.push("not connected: " + r.missing.join(", "))
      if (r.warnings && r.warnings.length) parts.push(r.warnings.join("; "))
      setStatus(parts.join(" · ") + ".", r.warnings && r.warnings.length > 0)
      centerTimer.restart()
      if (then) then(); else refresh(null)
    })
  }

  function tryDraft() {
    if (check.errors.length) { fail(check.errors[0]); return }
    setStatus("Trying the layout…")
    run(["apply-draft", JSON.stringify(L.stripTransient(draft))], function(ok, out, err) {
      if (!ok) { fail(err); return }
      tryLeft = 15
      centerTimer.restart()
      setStatus("Trying the new layout. Keep it or it will revert automatically.")
    })
  }

  function revertTry() {
    tryLeft = 0
    if (activeProfile) applyNamed(activeProfile, function() { refresh(null); setStatus("Reverted to “" + title(activeProfile) + "”.") })
    else run(["auto", "--force"], function() { refresh(null); centerTimer.restart(); setStatus("Reverted.") })
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.tryLeft > 0
    onTriggered: { root.tryLeft -= 1; if (root.tryLeft <= 0) root.revertTry() }
  }

  function deleteProfile() {
    if (!draft || isNew) return
    var name = originalName
    if (name === activeProfile) { fail("This profile is active. Apply another profile before deleting it."); return }
    ask("Delete profile “" + title(name) + "”? This cannot be undone.", "Delete", function() {
      run(["delete", name], function(ok, out, err) {
        if (!ok) { fail(err); return }
        setStatus("Deleted “" + title(name) + "”.")
        refresh(function() { initialSelection() })
      })
    })
  }

  // ---- catalog (global workspace names, numbers, apps) -------------------
  function catalogChange(mutate, patchDraft, renames, message) {
    var wasDirty = dirty
    var ws = L.clone(catalog)
    var error = mutate(ws)
    if (error) { fail(error); return }
    run(["catalog-save", JSON.stringify({ workspaces: ws, renames: renames || {} })], function(ok, out, err) {
      if (!ok) { fail(err); return }
      pendingCatalog = null
      setStatus(message)
      refresh(function() {
        if (draft && !isNew && !wasDirty) selectProfile(draft.name, true)
        else if (draft && patchDraft) {
          edit(patchDraft)
          if (!isNew) {
            var saved = findProfile(originalName)
            if (saved) { var s = L.clone(saved); delete s.status; savedCanon = L.canon(L.stripTransient(s)) }
          }
        }
      })
    })
  }

  function validName(name, except) {
    if (!/^[A-Za-z0-9][A-Za-z0-9_.-]{0,23}$/.test(name)) return "Workspace names: letters, digits, '-', '_' or '.', max 24."
    for (var i = 0; i < catalog.length; i++)
      if (catalog[i].name.toLowerCase() === name.toLowerCase() && catalog[i].name !== except) return "“" + name + "” already exists."
    return ""
  }

  function renameWorkspace(oldName, newName) {
    renaming = ""
    newName = newName.trim()
    if (!newName || newName === oldName) return
    var problem = validName(newName, oldName)
    if (problem) { fail(problem); return }
    var renames = {}
    renames[oldName] = newName
    if (selWorkspace === oldName) selWorkspace = newName
    catalogChange(function(ws) { ws.forEach(function(w) { if (w.name === oldName) w.name = newName }) },
                  function(d) { L.renameWorkspace(d, oldName, newName) }, renames,
                  "Renamed “" + oldName + "” to “" + newName + "” in every profile.")
  }

  function addWorkspace() {
    var n = 1, name = "workspace"
    while (validName(name)) { n += 1; name = "workspace-" + n }
    catalogChange(function(ws) {
      var used = ws.map(function(w) { return w.number })
      var num = 1
      while (used.indexOf(num) >= 0) num += 1
      ws.push({ name: name, number: num, apps: [] })
    }, function(d) {
      d.parked.push(name)
      var used = Object.keys(d.numbers).map(function(k) { return d.numbers[k] })
      var num = 1
      while (used.indexOf(num) >= 0) num += 1
      d.numbers[name] = num
    }, {}, "Added “" + name + "” (parked). Double-click to rename, drag onto a display.")
    selWorkspace = name
  }

  function deleteWorkspace(name) {
    if (catalog.length <= 1) { fail("Keep at least one workspace."); return }
    ask("Delete workspace “" + name + "” from every profile? Open windows stay where they are.", "Delete", function() {
      if (selWorkspace === name) selWorkspace = ""
      catalogChange(function(ws) { for (var i = ws.length - 1; i >= 0; i--) if (ws[i].name === name) ws.splice(i, 1) },
        function(d) {
          d.monitors.forEach(function(m) { m.workspaces = m.workspaces.filter(function(w) { return w !== name }) })
          d.parked = d.parked.filter(function(w) { return w !== name })
          delete d.numbers[name]
        }, {}, "Deleted workspace “" + name + "”.")
    })
  }

  function stageCatalog(mutate, message) {
    var ws = L.clone(catalog)
    mutate(ws)
    pendingCatalog = ws
    setStatus(message + " Save to keep it.")
  }

  function setApps(name, apps) {
    stageCatalog(function(ws) { ws.forEach(function(w) { if (w.name === name) w.apps = apps }) },
                 "Updated app rules for “" + name + "”.")
  }

  function setLaunch(name, app, command) {
    stageCatalog(function(ws) {
      ws.forEach(function(w) {
        if (w.name !== name) return
        w.launch = w.launch || {}
        if (command) w.launch[app] = command
        else delete w.launch[app]
      })
    }, command ? "Will run “" + command + "” at login." : "Removed launch command.")
  }

  // ---- workspace drag and drop --------------------------------------------
  function beginDrag(name, point) { dragName = name; dragPoint = point; selWorkspace = name; updateDrop(point) }
  function moveDrag(point) { dragPoint = point; updateDrop(point) }
  function endDrag() {
    if (dragName && dropMonitor > -2) {
      var name = dragName, mon = dropMonitor, before = dropBefore
      edit(function(d) { L.moveWorkspace(d, name, mon, before) })
    }
    dragName = ""
    dropMonitor = -2
  }
  function cancelDrag() { dragName = ""; dropMonitor = -2 }

  function updateDrop(point) {
    dropMonitor = -2
    dropBefore = -1
    for (var c = 0; c < boardRepeater.count; c++) {
      var col = boardRepeater.itemAt(c)
      if (!col) continue
      var p = col.mapFromItem(content, point.x, point.y)
      if (p.x >= 0 && p.y >= 0 && p.x <= col.width && p.y <= col.height) {
        dropMonitor = col.monitorIndex
        dropBefore = col.insertIndexAt(p.y)
        return
      }
    }
    for (var i = 0; i < cardRepeater.count; i++) {
      var card = cardRepeater.itemAt(i)
      if (!card) continue
      var q = card.mapFromItem(content, point.x, point.y)
      if (q.x >= 0 && q.y >= 0 && q.x <= card.width && q.y <= card.height) {
        dropMonitor = i
        dropBefore = -1
        return
      }
    }
  }

  // ---- monitor edits -------------------------------------------------------
  function addLiveMonitor(live) {
    edit(function(d) {
      var b = L.bounds(d.monitors.filter(function(m) { return m.enabled !== false }))
      var m = L.monitorFromLive(live, d.monitors.length ? Math.round(b.x + b.w) : 0, d.monitors.length ? Math.round(b.y) : 0)
      d.monitors.push(m)
    })
    selMonitor = draft.monitors.length - 1
    setStatus("Added " + live.label + ". Drag it into place.")
  }

  function pickMode(idx) {
    var m = draft.monitors[idx], live = liveFor(m)
    if (!live) { fail("Connect this display to change its mode."); return }
    pick("Resolution & refresh rate", live.modes.map(function(mode, i) {
      return { label: L.modeLabel(mode), sub: i === 0 ? "native (recommended)" : "", value: mode, current: mode === m.mode }
    }), function(mode) {
      edit(function(d) {
        var p = L.parseMode(mode), mm = d.monitors[idx]
        mm.mode = mode; mm.width = p.w; mm.height = p.h
        var scales = (live.scales[p.w + "x" + p.h] || []).map(function(s) { return s.scale })
        if (scales.length && scales.indexOf(mm.scale) < 0) mm.scale = 1
      })
    })
  }

  function pickScale(idx) {
    var m = draft.monitors[idx], live = liveFor(m)
    var list = live ? (live.scales[m.width + "x" + m.height] || []) : []
    if (!list.length) { fail("Connect this display to change its scale."); return }
    pick("Scale (sharp values only)", list.filter(function(s) { return s.scale >= 0.75 && s.scale <= 3 }).map(function(s) {
      return { label: L.percent(s.scale), sub: s.width + " × " + s.height + " logical", value: s.scale,
               current: Math.abs(s.scale - m.scale) < 0.001 }
    }), function(scale) { edit(function(d) { d.monitors[idx].scale = scale }) })
  }

  function pickNumber(name) {
    var count = Math.max(10, catalog.length)
    var owners = {}
    for (var key in draft.numbers) owners[draft.numbers[key]] = key
    var items = []
    for (var n = 1; n <= count; n++) {
      var owner = owners[n]
      items.push({ label: (n === 10 ? "0 / 10" : String(n)) + (n <= 10 ? "   Super + " + (n % 10) : ""),
                   sub: owner && owner !== name ? "swap with " + owner : (owner === name ? "current" : "free"),
                   value: n, current: owner === name })
    }
    pick("Number for “" + name + "”", items, function(n) { edit(function(d) { L.setNumber(d, name, n) }) })
  }

  // ---- lifecycle ------------------------------------------------------------
  function open(payload) {
    opened = true
    setStatus("")
    centerTimer.restart()
    refresh(function() { if (!draft) initialSelection(); else if (!dirty && !isNew) selectProfile(draft.name, true) })
  }

  function close() {
    if (tryLeft > 0) revertTry()
    cancelDrag()
    identify = false
    opened = false
  }

  function requestClose() {
    if (dirty) ask("Close and discard unsaved changes?", "Discard", function() { root.close() })
    else close()
  }

  IpcHandler {
    target: "yonathan.displays"
    function toggle(): void { if (root.opened) root.close(); else root.open("") }
    function open(): void { root.open("") }
    function close(): void { root.close() }
  }

  // ---- identify overlay ------------------------------------------------------
  Variants {
    model: root.opened && root.identify ? Quickshell.screens : []
    delegate: Component {
      PanelWindow {
        id: label
        required property var modelData
        readonly property int monitorIndex: {
          if (!root.draft) return -1
          for (var i = 0; i < root.draft.monitors.length; i++) if (root.draft.monitors[i]._live === modelData.name) return i
          return -1
        }
        screen: modelData
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "yonathan-displays-identify"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        anchors { top: true; bottom: true; left: true; right: true }
        mask: Region {}
        Rectangle {
          anchors.centerIn: parent
          width: idCol.implicitWidth + 64
          height: idCol.implicitHeight + 40
          radius: 18
          color: Qt.alpha(root.bg, 0.92)
          border.width: 4
          border.color: label.monitorIndex >= 0 ? root.colorFor(label.monitorIndex, 1) : root.dim
          Column {
            id: idCol
            anchors.centerIn: parent
            spacing: 4
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: label.monitorIndex >= 0 ? root.draft.monitors[label.monitorIndex].label : "Not in this profile"
              color: root.fg; font.family: root.font; font.pixelSize: Style.font.displayLarge; font.bold: true
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: label.modelData.name
              color: root.dim; font.family: root.font; font.pixelSize: Style.font.heading
            }
          }
        }
      }
    }
  }

  // ---- window ------------------------------------------------------------
  FloatingWindow {
    visible: root.opened
    title: "Displays & Workspaces"
    color: root.bg
    implicitWidth: 1360
    implicitHeight: 880
    onVisibleChanged: if (!visible && root.opened) root.close()

    FocusScope {
      id: content
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        var ctrl = event.modifiers & Qt.ControlModifier
        if (event.key === Qt.Key_Escape) {
          if (root.pickerPick) root.pickerPick = null
          else if (root.confirmAction) root.confirmAction = null
          else if (root.dragName) root.cancelDrag()
          else if (root.renaming) root.renaming = ""
          else if (root.selMonitor >= 0 || root.selWorkspace) { root.selMonitor = -1; root.selWorkspace = "" }
          else root.requestClose()
          event.accepted = true
        } else if (ctrl && event.key === Qt.Key_S) {
          root.saveDraft(false); event.accepted = true
        } else if (ctrl && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
          root.saveDraft(true); event.accepted = true
        } else if (ctrl && event.key === Qt.Key_Z) {
          root.revertDraft(); event.accepted = true
        }
      }

      // ================= header =================
      Rectangle {
        id: header
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: 58
        color: Qt.darker(root.bg, 1.12)
        Row {
          anchors.left: parent.left; anchors.leftMargin: 18; anchors.verticalCenter: parent.verticalCenter
          spacing: 12
          Text { text: "󰍹"; color: root.accent; font.pixelSize: Style.font.display; anchors.verticalCenter: parent.verticalCenter }
          Column {
            anchors.verticalCenter: parent.verticalCenter
            Text { text: "Displays & Workspaces"; color: root.fg; font.family: root.font; font.pixelSize: Style.font.heading; font.bold: true }
            Text {
              color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption
              text: (root.activeProfile ? "Active: " + root.title(root.activeProfile) + (root.st && root.st.manual ? " (chosen manually)" : " (automatic)") : "No profile active")
                    + (root.detectedProfile && root.detectedProfile !== root.activeProfile ? "   ·   Matches connected displays: " + root.title(root.detectedProfile) : "")
                    + "   ·   " + root.connected.length + " display" + (root.connected.length === 1 ? "" : "s") + " connected"
            }
          }
        }
        Row {
          anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter
          spacing: 8
          Btn { icon: "󰈈"; text: "Identify"; checked: root.identify; onClicked: root.identify = !root.identify }
          Btn { icon: "󰑐"; text: "Re-detect"; enabled: !root.busy; onClicked: root.refresh(function() { if (root.draft && !root.dirty && !root.isNew) root.selectProfile(root.draft.name, true); root.setStatus("Displays re-detected.") }) }
          Btn { icon: "󰅖"; onClicked: root.requestClose() }
        }
      }

      // ================= sidebar: profiles =================
      Rectangle {
        id: sidebar
        anchors { left: parent.left; top: header.bottom; bottom: footer.top }
        width: 244
        color: Qt.darker(root.bg, 1.06)

        Column {
          anchors.fill: parent
          anchors.margins: 12
          spacing: 8

          Item {
            width: parent.width; height: 28
            Text { text: "PROFILES"; color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1.2; anchors.verticalCenter: parent.verticalCenter }
            Btn { anchors.right: parent.right; compact: true; icon: "󰐕"; text: "New"; enabled: !!root.st; onClicked: root.newFromCurrent(false) }
          }

          Repeater {
            model: root.profiles
            delegate: Rectangle {
              id: prow
              required property var modelData
              readonly property bool selected: root.draft && !root.isNew && root.originalName === modelData.name
              readonly property bool isActive: root.activeProfile === modelData.name
              width: parent.width
              height: 58
              radius: 8
              color: selected ? Qt.alpha(root.accent, 0.16) : pma.containsMouse ? root.faint : "transparent"
              border.width: selected ? 1 : 0
              border.color: Qt.alpha(root.accent, 0.6)
              Column {
                anchors.left: parent.left; anchors.leftMargin: 12; anchors.right: applyBtn.left; anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3
                Row {
                  spacing: 6
                  Text { text: root.title(prow.modelData.name); color: root.fg; font.family: root.font; font.pixelSize: Style.font.title; font.bold: prow.selected }
                  Rectangle {
                    visible: prow.isActive; radius: 4; height: 16; width: activeText.implicitWidth + 10
                    color: Qt.alpha(root.accent, 0.3); anchors.verticalCenter: parent.verticalCenter
                    Text { id: activeText; anchors.centerIn: parent; text: "ACTIVE"; color: root.fg; font.family: root.font; font.pixelSize: Style.font.caption - 1; font.bold: true }
                  }
                }
                Text {
                  width: parent.width; elide: Text.ElideRight
                  font.family: root.font; font.pixelSize: Style.font.caption
                  color: prow.modelData.status.complete ? root.fg : root.dim
                  text: (prow.modelData.status.complete ? "● Connected" : "○ " + prow.modelData.status.missing + "/" + prow.modelData.monitors.length + " missing")
                        + (prow.modelData.auto ? "  ·  auto" : "")
                }
              }
              MouseArea { id: pma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.selectProfile(prow.modelData.name, false) }
              Btn {
                id: applyBtn
                anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                compact: true; icon: "󰐊"
                enabled: !root.busy
                onClicked: root.applyNamed(prow.modelData.name, null)
              }
            }
          }

          Rectangle {
            visible: root.isNew
            width: parent.width; height: 40; radius: 8
            color: Qt.alpha(root.accent, 0.16); border.width: 1; border.color: Qt.alpha(root.accent, 0.6)
            Text { anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter; text: "✚ " + (root.draft ? root.title(root.draft.name) : "") + "  (unsaved)"; color: root.fg; font.family: root.font; font.pixelSize: Style.font.body; font.bold: true }
          }

          Item { width: 1; height: 6 }
          Text {
            width: parent.width; wrapMode: Text.WordWrap
            color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption
            text: "Profiles marked auto switch on their own when their displays are connected. Click ▶ to apply a profile now."
          }
        }
      }

      // ================= inspector =================
      Rectangle {
        id: inspector
        anchors { right: parent.right; top: header.bottom; bottom: footer.top }
        width: 300
        color: Qt.darker(root.bg, 1.06)

        Flickable {
          anchors.fill: parent
          anchors.margins: 14
          contentHeight: inspectorCol.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: inspectorCol
            width: parent.width
            spacing: 10

            // ---------- monitor inspector ----------
            Column {
              id: monInspector
              visible: root.draft && root.selMonitor >= 0 && root.selMonitor < root.draft.monitors.length && !root.selWorkspace
              width: parent.width
              spacing: 10
              readonly property var m: visible ? root.draft.monitors[root.selMonitor] : null
              readonly property var live: m ? root.liveFor(m) : null

              Row {
                spacing: 8
                Rectangle { width: 12; height: 12; radius: 3; color: root.colorFor(root.selMonitor, 1); anchors.verticalCenter: parent.verticalCenter }
                Text { text: monInspector.m ? monInspector.m.label : ""; color: root.fg; font.family: root.font; font.pixelSize: Style.font.heading; font.bold: true; width: 240; elide: Text.ElideRight }
              }
              Text {
                width: parent.width; wrapMode: Text.WordWrap; color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption
                text: monInspector.m ? ((monInspector.live ? "Connected as " + monInspector.live.name : "Not connected") + "\n" + (monInspector.m.match.description || monInspector.m.match.output)) : ""
              }

              SectionLabel { text: "DISPLAY" }
              Row {
                spacing: 6
                Btn { text: "Enabled"; checked: monInspector.m && monInspector.m.enabled; onClicked: root.edit(function(d) { d.monitors[root.selMonitor].enabled = true }) }
                Btn { text: "Disabled"; checked: monInspector.m && !monInspector.m.enabled; onClicked: root.edit(function(d) { d.monitors[root.selMonitor].enabled = false }) }
              }

              SectionLabel { text: "RESOLUTION" }
              Btn {
                width: parent.width
                text: monInspector.m ? L.modeLabel(monInspector.m.mode) : ""
                icon: "󰍹"
                enabled: !!monInspector.live
                onClicked: root.pickMode(root.selMonitor)
              }

              SectionLabel { text: "SCALE" }
              Btn {
                width: parent.width
                enabled: !!monInspector.live
                text: monInspector.m ? L.percent(monInspector.m.scale) + "   →   " + Math.round(L.logicalSize(monInspector.m).w) + " × " + Math.round(L.logicalSize(monInspector.m).h) + " logical" : ""
                onClicked: root.pickScale(root.selMonitor)
              }

              SectionLabel { text: "ROTATION" }
              Row {
                spacing: 4
                Repeater {
                  model: L.ROTATIONS
                  delegate: Btn {
                    required property var modelData
                    text: modelData.short
                    checked: monInspector.m && (monInspector.m.transform % 4) === modelData.t
                    onClicked: { var t = modelData.t; root.edit(function(d) { var mm = d.monitors[root.selMonitor]; mm.transform = (mm.transform >= 4 ? 4 : 0) + t }) }
                  }
                }
                Btn {
                  text: "Mirror"
                  checked: monInspector.m && monInspector.m.transform >= 4
                  onClicked: root.edit(function(d) { var mm = d.monitors[root.selMonitor]; mm.transform = (mm.transform + 4) % 8 })
                }
              }

              SectionLabel { text: "POSITION (LOGICAL PX)" }
              Row {
                spacing: 8
                Text { text: "X"; color: root.dim; font.family: root.font; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter }
                Field {
                  id: posX; width: 90; numeric: true
                  text: monInspector.m ? String(monInspector.m.x) : ""
                  onAccepted: root.edit(function(d) { d.monitors[root.selMonitor].x = parseInt(posX.text) || 0 })
                }
                Text { text: "Y"; color: root.dim; font.family: root.font; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter }
                Field {
                  id: posY; width: 90; numeric: true
                  text: monInspector.m ? String(monInspector.m.y) : ""
                  onAccepted: root.edit(function(d) { d.monitors[root.selMonitor].y = parseInt(posY.text) || 0 })
                }
              }
              Text { text: "Align with nearest display"; color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption }
              Flow {
                width: parent.width
                spacing: 4
                Btn { compact: true; text: "Top"; onClicked: root.edit(function(d) { L.alignWith(d.monitors, root.selMonitor, "top") }) }
                Btn { compact: true; text: "Middle"; onClicked: root.edit(function(d) { L.alignWith(d.monitors, root.selMonitor, "middle") }) }
                Btn { compact: true; text: "Bottom"; onClicked: root.edit(function(d) { L.alignWith(d.monitors, root.selMonitor, "bottom") }) }
                Btn { compact: true; text: "◀ Left of"; onClicked: root.edit(function(d) { L.alignWith(d.monitors, root.selMonitor, "left") }) }
                Btn { compact: true; text: "Right of ▶"; onClicked: root.edit(function(d) { L.alignWith(d.monitors, root.selMonitor, "right") }) }
              }

              Item { width: 1; height: 6 }
              Btn {
                danger: true; icon: "󰆴"; text: "Remove from profile"
                onClicked: { var i = root.selMonitor; root.selMonitor = -1; root.edit(function(d) { L.removeMonitor(d, i) }) }
              }
            }

            // ---------- workspace inspector ----------
            Column {
              id: wsInspector
              visible: root.draft && root.selWorkspace !== "" && !!root.catalogEntry(root.selWorkspace)
              width: parent.width
              spacing: 10
              readonly property var entry: visible ? root.catalogEntry(root.selWorkspace) : null
              readonly property var where: visible ? L.locate(root.draft, root.selWorkspace) : null

              Text { text: "Workspace"; color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption }
              Field {
                id: wsName; width: parent.width; fontSize: Style.font.heading
                text: root.selWorkspace
                onAccepted: root.renameWorkspace(root.selWorkspace, wsName.text)
                onCancelled: wsName.text = root.selWorkspace
              }
              Text { width: parent.width; wrapMode: Text.WordWrap; text: "Press Enter to rename. Names are shared by all profiles."; color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption }

              SectionLabel { text: "NUMBER IN THIS PROFILE" }
              Btn {
                width: parent.width
                text: root.draft && root.draft.numbers[root.selWorkspace] !== undefined
                      ? root.draft.numbers[root.selWorkspace] + (root.draft.numbers[root.selWorkspace] <= 10 ? "    ·    Super + " + (root.draft.numbers[root.selWorkspace] % 10) : "") : ""
                onClicked: root.pickNumber(root.selWorkspace)
              }

              SectionLabel { text: "PLACED ON" }
              Btn {
                width: parent.width
                text: wsInspector.where ? (wsInspector.where.monitor < 0 ? "Parked (not on any display)" : root.draft.monitors[wsInspector.where.monitor].label) : ""
                onClicked: {
                  var name = root.selWorkspace
                  var items = root.draft.monitors.map(function(m, i) { return { label: m.label, sub: m._live || "not connected", value: i, current: wsInspector.where.monitor === i } })
                  items.push({ label: "Parked", sub: "reachable by number only", value: -1, current: wsInspector.where.monitor < 0 })
                  root.pick("Move “" + name + "” to", items, function(v) { root.edit(function(d) { L.moveWorkspace(d, name, v, -1) }) })
                }
              }

              SectionLabel { text: "APPS THAT OPEN HERE" }
              Repeater {
                model: wsInspector.entry ? wsInspector.entry.apps : []
                delegate: Column {
                  required property var modelData
                  required property int index
                  width: wsInspector.width; spacing: 3
                  Rectangle {
                    width: parent.width; height: 28; radius: 6; color: root.faint
                    Text { anchors.left: parent.left; anchors.leftMargin: 8; anchors.right: rm.left; anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight; text: modelData; color: root.fg; font.family: "monospace"; font.pixelSize: Style.font.caption }
                    Btn {
                      id: rm; compact: true; icon: "󰅖"; anchors.right: parent.right; anchors.rightMargin: 3; anchors.verticalCenter: parent.verticalCenter
                      onClicked: { var apps = wsInspector.entry.apps.slice(); apps.splice(index, 1); root.setApps(root.selWorkspace, apps) }
                    }
                  }
                  Field {
                    id: launchField; width: parent.width
                    placeholder: "run at login, e.g. ghostty -e herdr"
                    Binding {
                      target: launchField.input; property: "text"
                      value: (wsInspector.entry && wsInspector.entry.launch && wsInspector.entry.launch[modelData]) || ""
                    }
                    onAccepted: root.setLaunch(root.selWorkspace, modelData, launchField.text.trim())
                    onFocusLost: {
                      var saved = (wsInspector.entry && wsInspector.entry.launch && wsInspector.entry.launch[modelData]) || ""
                      if (launchField.text.trim() !== saved) root.setLaunch(root.selWorkspace, modelData, launchField.text.trim())
                    }
                  }
                }
              }
              Text { visible: wsInspector.entry && !wsInspector.entry.apps.length; text: "None. Apps with a rule open here and are moved here when a profile is applied."; width: parent.width; wrapMode: Text.WordWrap; color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption }
              Btn {
                width: parent.width
                icon: "󰐕"; text: "Add app…"
                onClicked: {
                  var name = root.selWorkspace
                  root.refresh(function() {
                    var addApp = function(rx) {
                      var apps = root.catalogEntry(name).apps
                      if (apps.indexOf(rx) < 0) root.setApps(name, apps.concat([rx]))
                    }
                    root.pick("Add an app to “" + name + "”", (root.st ? root.st.windows : []).map(function(w) {
                      return { label: w["class"], sub: w.title + (w.workspace ? "  ·  on " + w.workspace : ""), value: w["class"], current: false }
                    }), function(cls) { addApp("^" + cls.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "$") })
                    root.pickerCustom = addApp
                    root.pickerCustomHint = "or type a class regex, e.g. ^slack$"
                  })
                }
              }

              Item { width: 1; height: 6 }
              Btn { danger: true; icon: "󰆴"; text: "Delete workspace"; onClicked: root.deleteWorkspace(root.selWorkspace) }
            }

            // ---------- profile overview (nothing selected) ----------
            Column {
              visible: root.draft && root.selMonitor < 0 && !root.selWorkspace
              width: parent.width
              spacing: 10

              Text { text: "Profile"; color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption }
              Text { text: root.draft ? root.title(root.draft.name) : ""; color: root.fg; font.family: root.font; font.pixelSize: Style.font.heading; font.bold: true }

              SectionLabel { text: "CHECKS" }
              Repeater {
                model: root.check.errors
                delegate: Text { required property var modelData; width: 272; wrapMode: Text.WordWrap; text: "✖  " + modelData; color: root.red; font.family: root.font; font.pixelSize: Style.font.bodySmall }
              }
              Repeater {
                model: root.check.warnings
                delegate: Text { required property var modelData; width: 272; wrapMode: Text.WordWrap; text: "⚠  " + modelData; color: root.fg; font.family: root.font; font.pixelSize: Style.font.bodySmall }
              }
              Text { visible: !root.check.errors.length && !root.check.warnings.length; text: "✔  Layout looks good."; color: root.fg; font.family: root.font; font.pixelSize: Style.font.bodySmall }

              SectionLabel { text: "CONNECTED, NOT IN THIS PROFILE"; visible: root.notInProfile.length > 0 }
              Repeater {
                model: root.notInProfile
                delegate: Rectangle {
                  required property var modelData
                  width: 272; height: 44; radius: 8; color: root.faint
                  Column {
                    anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                    Text { text: modelData.label; color: root.fg; font.family: root.font; font.pixelSize: Style.font.body }
                    Text { text: modelData.name + "  ·  " + L.modeLabel(modelData.mode); color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption }
                  }
                  Btn { anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; compact: true; icon: "󰐕"; text: "Add"; onClicked: root.addLiveMonitor(modelData) }
                }
              }

              SectionLabel { text: "TIPS" }
              Text {
                width: 272; wrapMode: Text.WordWrap; color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption; lineHeight: 1.3
                text: "• Drag displays to arrange them; they snap to edges and centres. Hold Shift to place freely.\n"
                    + "• Click a display or workspace to edit it here.\n"
                    + "• Drag workspaces between columns (or onto a display) to move them; the order is the bar order.\n"
                    + "• Double-click a workspace to rename it; click its number to change Super+N.\n"
                    + "• Ctrl+S save · Ctrl+Enter save & apply · Ctrl+Z discard · Esc close"
              }
            }
          }
        }
      }

      // ================= main area =================
      Item {
        id: main
        anchors { left: sidebar.right; right: inspector.left; top: header.bottom; bottom: footer.top; margins: 14 }

        // profile header
        Item {
          id: profileBar
          anchors { left: parent.left; right: parent.right; top: parent.top }
          height: 34
          Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Field {
              id: profileName; width: 220; fontSize: Style.font.title
              text: root.draft ? root.draft.name : ""
              onEdited: { var t = profileName.text.toLowerCase().replace(/\s+/g, "-"); root.edit(function(d) { d.name = t }) }
            }
            Btn {
              text: "Auto-switch"; icon: root.draft && root.draft.auto ? "󰄬" : "󰄱"
              checked: root.draft && root.draft.auto
              onClicked: root.edit(function(d) { d.auto = !d.auto })
            }
            Text {
              visible: root.dirty
              text: "●  Unsaved changes"; color: root.accent; font.family: root.font; font.pixelSize: Style.font.bodySmall; font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }
          Row {
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            Btn { compact: true; icon: "󰆏"; text: "Duplicate"; enabled: !!root.draft; onClicked: root.duplicateProfile() }
            Btn { compact: true; danger: true; icon: "󰆴"; text: "Delete"; enabled: root.draft && !root.isNew; onClicked: root.deleteProfile() }
          }
        }

        // -------- canvas --------
        Rectangle {
          id: canvas
          anchors { left: parent.left; right: parent.right; top: profileBar.bottom; topMargin: 10 }
          height: Math.max(260, main.height * 0.46)
          radius: 10
          color: Qt.darker(root.bg, 1.3)
          border.width: 1
          border.color: Qt.alpha(root.fg, 0.1)
          clip: true

          readonly property real pad: 34
          property bool frozen: false
          property real fz: 0.1
          property real fox: 0
          property real foy: 0
          readonly property var bb: root.draft ? L.bounds(root.draft.monitors) : ({ x: 0, y: 0, w: 1920, h: 1080 })
          readonly property real fitZoom: Math.min((width - 2 * pad) / Math.max(bb.w, 1), (height - 2 * pad - 20) / Math.max(bb.h, 1), 0.3)
          readonly property real zoom: frozen ? fz : fitZoom
          readonly property real ox: frozen ? fox : (width - bb.w * fitZoom) / 2 - bb.x * fitZoom
          readonly property real oy: frozen ? foy : (height - 20 - bb.h * fitZoom) / 2 - bb.y * fitZoom
          function freeze() { fz = fitZoom; fox = ox; foy = oy; frozen = true }

          // background grid (every 500 logical px)
          Repeater {
            model: Math.max(0, Math.ceil(canvas.width / Math.max(canvas.zoom * 500, 8)) + 2)
            Rectangle { required property int index; x: canvas.ox % (canvas.zoom * 500) + index * canvas.zoom * 500; width: 1; height: canvas.height; color: Qt.alpha(root.fg, 0.04) }
          }
          Repeater {
            model: Math.max(0, Math.ceil(canvas.height / Math.max(canvas.zoom * 500, 8)) + 2)
            Rectangle { required property int index; y: canvas.oy % (canvas.zoom * 500) + index * canvas.zoom * 500; height: 1; width: canvas.width; color: Qt.alpha(root.fg, 0.04) }
          }

          MouseArea { anchors.fill: parent; onClicked: { root.selMonitor = -1; root.selWorkspace = "" } }

          Repeater {
            id: cardRepeater
            model: root.draft ? root.draft.monitors.length : 0
            delegate: Rectangle {
              id: card
              required property int index
              readonly property var m: root.draft && index < root.draft.monitors.length ? root.draft.monitors[index] : null
              readonly property bool online: !!(m && m._live && root.liveFor(m))
              readonly property bool selected: root.selMonitor === index && !root.selWorkspace
              readonly property bool dropHere: root.dragName !== "" && root.dropMonitor === index
              property bool dragging: false
              property real dx: 0
              property real dy: 0
              property bool bad: false
              readonly property var lr: m ? L.rect(m, dragging ? dx : m.x, dragging ? dy : m.y) : ({ x: 0, y: 0, w: 0, h: 0 })

              x: canvas.ox + lr.x * canvas.zoom
              y: canvas.oy + lr.y * canvas.zoom
              width: Math.max(lr.w * canvas.zoom, 20)
              height: Math.max(lr.h * canvas.zoom, 20)
              z: dragging ? 10 : selected ? 5 : 1
              radius: 6
              opacity: m && m.enabled ? (online ? 1 : 0.6) : 0.4
              color: root.colorFor(index, dragging ? 0.3 : dropHere ? 0.34 : 0.18)
              border.width: selected || dragging || dropHere ? 2 : 1
              border.color: bad ? root.red : (selected || dropHere) ? root.accent : root.colorFor(index, 0.85)

              Column {
                anchors.centerIn: parent
                width: parent.width - 16
                spacing: 2
                Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; text: card.m ? card.m.label : ""; color: root.fg; font.family: root.font; font.pixelSize: Style.font.body; font.bold: true }
                Text {
                  width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                  text: !card.m ? "" : !card.m.enabled ? "Disabled" : card.online ? card.m._live : "Not connected"
                  color: card.online ? root.dim : root.accent; font.family: root.font; font.pixelSize: Style.font.caption
                }
                Text {
                  visible: card.height > 70
                  width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                  text: card.m ? (card.m.width + "×" + card.m.height + " · " + L.percent(card.m.scale) + (card.m.transform % 4 ? " · " + L.ROTATIONS[card.m.transform % 4].short : "")) : ""
                  color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption
                }
                Flow {
                  visible: card.height > 90
                  width: parent.width
                  spacing: 3
                  Repeater {
                    model: card.m ? card.m.workspaces : []
                    delegate: Rectangle {
                      required property var modelData
                      width: chip.implicitWidth + 8; height: 16; radius: 4; color: Qt.alpha(root.bg, 0.6)
                      Text { id: chip; anchors.centerIn: parent; text: (root.draft.numbers[modelData] % 10) + " " + modelData; color: root.fg; font.family: root.font; font.pixelSize: Style.font.caption - 1 }
                    }
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: card.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                property point start: Qt.point(0, 0)
                property real sx: 0
                property real sy: 0
                onPressed: function(mouse) {
                  root.selMonitor = card.index
                  root.selWorkspace = ""
                  start = mapToItem(canvas, mouse.x, mouse.y)
                  sx = card.m.x; sy = card.m.y
                  card.dx = sx; card.dy = sy
                }
                onPositionChanged: function(mouse) {
                  if (!pressed) return
                  var p = mapToItem(canvas, mouse.x, mouse.y)
                  if (!card.dragging) {
                    if (Math.abs(p.x - start.x) + Math.abs(p.y - start.y) < 5) return
                    canvas.freeze()
                    card.dragging = true
                  }
                  var nx = sx + (p.x - start.x) / canvas.zoom
                  var ny = sy + (p.y - start.y) / canvas.zoom
                  var s = (mouse.modifiers & Qt.ShiftModifier)
                    ? { x: Math.round(nx), y: Math.round(ny), guides: [] }
                    : L.snap(root.draft.monitors, card.index, nx, ny, 16 / canvas.zoom)
                  card.dx = s.x; card.dy = s.y
                  root.guides = s.guides
                  card.bad = L.overlapsAny(root.draft.monitors, card.index, s.x, s.y)
                }
                onReleased: {
                  if (!card.dragging) return
                  var fx = card.dx, fy = card.dy, i = card.index
                  card.dragging = false
                  card.bad = false
                  root.guides = []
                  root.edit(function(d) { d.monitors[i].x = fx; d.monitors[i].y = fy; L.normalizeOrigin(d.monitors) })
                  canvas.frozen = false
                }
                onCanceled: { card.dragging = false; card.bad = false; root.guides = []; canvas.frozen = false }
              }
            }
          }

          // snap guides
          Repeater {
            model: root.guides
            delegate: Rectangle {
              required property var modelData
              color: root.accent
              opacity: 0.7
              x: modelData.axis === "x" ? canvas.ox + modelData.value * canvas.zoom : 0
              y: modelData.axis === "y" ? canvas.oy + modelData.value * canvas.zoom : 0
              width: modelData.axis === "x" ? 1 : canvas.width
              height: modelData.axis === "y" ? 1 : canvas.height
              z: 20
            }
          }

          // canvas toolbar
          Row {
            anchors { left: parent.left; bottom: parent.bottom; margins: 8 }
            spacing: 6
            Btn { compact: true; icon: "󰁌"; text: "Tidy (close gaps)"; enabled: !!root.draft; onClicked: root.edit(function(d) { L.tidy(d.monitors) }) }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Drag to arrange  ·  snaps to edges & centres  ·  Shift = free"
              color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption
            }
          }

          // try banner
          Rectangle {
            visible: root.tryLeft > 0
            anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 10 }
            z: 30
            width: tryRow.implicitWidth + 24; height: 40; radius: 8
            color: root.bg; border.width: 1; border.color: root.accent
            Row {
              id: tryRow
              anchors.centerIn: parent
              spacing: 10
              Text { text: "Keep this layout? Reverting in " + root.tryLeft + "s"; color: root.fg; font.family: root.font; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter }
              Btn { compact: true; primary: true; text: "Keep & save"; onClicked: root.saveDraft(true) }
              Btn { compact: true; text: "Revert now"; onClicked: root.revertTry() }
            }
          }
        }

        // -------- workspace board --------
        Item {
          id: boardArea
          anchors { left: parent.left; right: parent.right; top: canvas.bottom; bottom: parent.bottom; topMargin: 12 }

          Item {
            id: boardHeader
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 28
            Text { id: wsTitle; text: "WORKSPACES"; color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1.2; anchors.verticalCenter: parent.verticalCenter }
            Text {
              anchors { left: wsTitle.right; leftMargin: 10; right: boardButtons.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
              elide: Text.ElideRight
              text: "drag to move/reorder  ·  double-click to rename  ·  click the number to change Super+N"
              color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption
            }
            Row {
              id: boardButtons
              anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
              spacing: 6
              Btn { compact: true; icon: "󰎠"; text: "Number by position"; enabled: !!root.draft; onClicked: { root.edit(function(d) { L.autoNumber(d) }); root.setStatus("Numbered left to right, top to bottom, then parked.") } }
              Btn { compact: true; icon: "󰐕"; text: "Workspace"; enabled: !!root.draft && !root.busy; onClicked: root.addWorkspace() }
            }
          }

          Flickable {
            id: boardFlick
            anchors { left: parent.left; right: parent.right; top: boardHeader.bottom; bottom: parent.bottom; topMargin: 6 }
            contentWidth: boardRow.implicitWidth
            contentHeight: height
            clip: true
            interactive: root.dragName === ""
            boundsBehavior: Flickable.StopAtBounds

            Row {
              id: boardRow
              height: boardFlick.height
              spacing: 10
              readonly property real colWidth: Math.max(180, (boardFlick.width - (root.columns.length - 1) * 10) / Math.max(root.columns.length, 1))

              Repeater {
                id: boardRepeater
                model: root.columns
                delegate: Rectangle {
                  id: column
                  required property var modelData
                  readonly property int monitorIndex: modelData
                  readonly property var mon: monitorIndex >= 0 && root.draft ? root.draft.monitors[monitorIndex] : null
                  readonly property var items: !root.draft ? [] : monitorIndex >= 0 ? (mon ? mon.workspaces : []) : root.draft.parked
                  readonly property bool target: root.dragName !== "" && root.dropMonitor === monitorIndex
                  readonly property real rowH: 34
                  readonly property real rowGap: 4
                  readonly property real listTop: 46
                  function insertIndexAt(y) {
                    var i = Math.floor((y - listTop + wsList.contentY + (rowH + rowGap) / 2) / (rowH + rowGap))
                    return Math.max(0, Math.min(items.length, i))
                  }

                  width: boardRow.colWidth
                  height: boardRow.height
                  radius: 10
                  color: target ? Qt.alpha(root.accent, 0.1) : Qt.alpha(root.fg, 0.035)
                  border.width: 1
                  border.color: target ? root.accent : monitorIndex >= 0 ? root.colorFor(monitorIndex, 0.45) : Qt.alpha(root.fg, 0.12)

                  // column header
                  Rectangle {
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    height: 38; radius: 10
                    color: column.monitorIndex >= 0 ? root.colorFor(column.monitorIndex, 0.16) : Qt.alpha(root.fg, 0.05)
                    Column {
                      anchors.left: parent.left; anchors.leftMargin: 10; anchors.right: parent.right; anchors.rightMargin: 10
                      anchors.verticalCenter: parent.verticalCenter
                      Text {
                        width: parent.width; elide: Text.ElideRight
                        text: column.monitorIndex >= 0 ? (column.mon ? column.mon.label : "") : "Parked"
                        color: root.fg; font.family: root.font; font.pixelSize: Style.font.body; font.bold: true
                      }
                      Text {
                        width: parent.width; elide: Text.ElideRight
                        text: column.monitorIndex >= 0 ? (column.mon ? ((column.mon._live && root.liveFor(column.mon)) ? column.mon._live : "not connected — uses first display") + (column.mon.enabled ? "" : " · disabled") : "") : "not on a display · Super+N still works"
                        color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption
                      }
                    }
                    MouseArea {
                      anchors.fill: parent
                      enabled: column.monitorIndex >= 0
                      cursorShape: column.monitorIndex >= 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                      onClicked: { root.selMonitor = column.monitorIndex; root.selWorkspace = "" }
                    }
                  }

                  // drop indicator
                  Rectangle {
                    visible: column.target
                    x: 8; width: column.width - 16; height: 3; radius: 2; color: root.accent
                    y: column.listTop - wsList.contentY + Math.max(0, root.dropBefore < 0 ? column.items.length : root.dropBefore) * (column.rowH + column.rowGap) - 3
                    z: 5
                  }

                  Text {
                    visible: column.items.length === 0
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: column.listTop + 10
                    text: "Drop workspaces here"; color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption
                  }

                  Flickable {
                    id: wsList
                    anchors {
                      left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom
                      topMargin: column.listTop; leftMargin: 6; rightMargin: 6; bottomMargin: 6
                    }
                    clip: true
                    contentWidth: width
                    contentHeight: wsRows.height
                    interactive: root.dragName === "" && contentHeight > height
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                      id: wsRows
                      width: wsList.width
                      spacing: column.rowGap
                      Repeater {
                        model: column.items
                        delegate: Rectangle {
                          id: wrow
                          required property var modelData
                          required property int index
                          readonly property string name: modelData
                          readonly property bool selected: root.selWorkspace === name
                          readonly property var entry: root.catalogEntry(name)
                          width: parent.width
                          height: column.rowH
                          radius: 7
                          opacity: root.dragName === name ? 0.35 : 1
                          color: selected ? Qt.alpha(root.accent, 0.2) : rowArea.containsMouse ? Qt.alpha(root.fg, 0.1) : Qt.alpha(root.fg, 0.05)
                          border.width: selected ? 1 : 0
                          border.color: root.accent

                          MouseArea {
                            id: rowArea
                            anchors.fill: parent
                            hoverEnabled: true
                            preventStealing: true
                            cursorShape: root.dragName ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                            property point start: Qt.point(0, 0)
                            property bool moved: false
                            onPressed: function(mouse) { start = Qt.point(mouse.x, mouse.y); moved = false; root.selWorkspace = wrow.name; root.selMonitor = -1 }
                            onPositionChanged: function(mouse) {
                              if (!pressed) return
                              var p = mapToItem(content, mouse.x, mouse.y)
                              if (!moved) {
                                if (Math.abs(mouse.x - start.x) + Math.abs(mouse.y - start.y) < 6) return
                                moved = true
                                root.beginDrag(wrow.name, p)
                              } else root.moveDrag(p)
                            }
                            onReleased: if (moved) root.endDrag()
                            onCanceled: root.cancelDrag()
                            onDoubleClicked: { root.renaming = wrow.name }
                          }

                          Text { id: grip; x: 8; anchors.verticalCenter: parent.verticalCenter; text: "⠿"; color: root.dim; font.pixelSize: Style.font.title }

                          Rectangle {
                            id: badge
                            x: 24; anchors.verticalCenter: parent.verticalCenter
                            width: 26; height: 22; radius: 5
                            color: badgeArea.containsMouse ? root.accent : Qt.alpha(root.accent, 0.25)
                            Text {
                              anchors.centerIn: parent
                              text: root.draft && root.draft.numbers[wrow.name] !== undefined ? String(root.draft.numbers[wrow.name]) : "?"
                              color: badgeArea.containsMouse ? root.bg : root.fg; font.family: root.font; font.pixelSize: Style.font.bodySmall; font.bold: true
                            }
                            MouseArea { id: badgeArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.selWorkspace = wrow.name; root.pickNumber(wrow.name) } }
                          }

                          Text {
                            visible: root.renaming !== wrow.name
                            anchors.left: badge.right; anchors.leftMargin: 8; anchors.right: appsLabel.left; anchors.rightMargin: 4
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            text: wrow.name; color: root.fg; font.family: root.font; font.pixelSize: Style.font.body
                          }
                          Field {
                            id: renameField
                            visible: root.renaming === wrow.name
                            anchors.left: badge.right; anchors.leftMargin: 6; anchors.right: parent.right; anchors.rightMargin: 4
                            anchors.verticalCenter: parent.verticalCenter
                            height: 26
                            onVisibleChanged: if (visible) { text = wrow.name; input.forceActiveFocus(); input.selectAll() }
                            onAccepted: root.renameWorkspace(wrow.name, text)
                            onCancelled: root.renaming = ""
                            onFocusLost: if (root.renaming === wrow.name) root.renaming = ""
                          }
                          Text {
                            id: appsLabel
                            visible: root.renaming !== wrow.name
                            anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                            text: wrow.entry && wrow.entry.apps.length ? "󰀻 " + wrow.entry.apps.length : ""
                            color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }

      // ================= footer =================
      Rectangle {
        id: footer
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 56
        color: Qt.darker(root.bg, 1.12)
        Text {
          anchors { left: parent.left; leftMargin: 18; right: actions.left; rightMargin: 16; verticalCenter: parent.verticalCenter }
          text: (root.busy ? "⟳  " : "") + (root.status || (root.check.errors.length ? root.check.errors[0] : ""))
          color: root.statusError || (!root.status && root.check.errors.length) ? root.red : root.fg
          font.family: root.font; font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
          maximumLineCount: 2
          wrapMode: Text.WordWrap
        }
        Row {
          id: actions
          anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
          spacing: 8
          Btn { text: "Discard"; enabled: root.dirty && !root.busy; onClicked: root.revertDraft() }
          Btn { icon: "󰔟"; text: "Try 15 s"; enabled: !!root.draft && !root.busy && !root.check.errors.length && root.tryLeft === 0; onClicked: root.tryDraft() }
          Btn { text: "Save"; enabled: root.dirty && !root.busy && !root.check.errors.length; onClicked: root.saveDraft(false) }
          Btn {
            primary: true
            text: root.dirty ? "Save & Apply" : "Apply"
            enabled: !!root.draft && !root.busy && !root.check.errors.length
            onClicked: root.dirty ? root.saveDraft(true) : root.applyNamed(root.draft.name, null)
          }
        }
      }

      // ================= drag ghost =================
      Rectangle {
        visible: root.dragName !== ""
        z: 1000
        x: root.dragPoint.x - 20
        y: root.dragPoint.y - 17
        width: 190; height: 34; radius: 7
        color: root.bg
        border.width: 2
        border.color: root.accent
        Text {
          anchors.centerIn: parent
          text: (root.draft && root.draft.numbers[root.dragName] !== undefined ? root.draft.numbers[root.dragName] + "  " : "") + root.dragName
          color: root.fg; font.family: root.font; font.pixelSize: Style.font.body; font.bold: true
        }
      }

      // ================= picker sheet =================
      Rectangle {
        anchors.fill: parent
        visible: root.pickerPick !== null
        z: 2000
        color: Qt.rgba(0, 0, 0, 0.55)
        MouseArea { anchors.fill: parent; onClicked: root.pickerPick = null }
        Rectangle {
          anchors.centerIn: parent
          width: 420
          height: Math.min(parent.height - 120, pickerList.contentHeight + 70 + (root.pickerCustom ? 44 : 0))
          radius: 12
          color: root.bg
          border.width: 1
          border.color: Qt.alpha(root.fg, 0.2)
          MouseArea { anchors.fill: parent }
          Text { id: pickerTitleText; x: 18; y: 16; text: root.pickerTitle; color: root.fg; font.family: root.font; font.pixelSize: Style.font.title; font.bold: true }
          Field {
            id: pickerCustomField
            visible: !!root.pickerCustom
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 12 }
            placeholder: root.pickerCustomHint
            onAccepted: {
              var fn = root.pickerCustom, v = text.trim()
              if (!v) return
              try { new RegExp(v) } catch (e) { root.fail("Not a valid regex: " + v); return }
              root.pickerPick = null
              text = ""
              if (fn) fn(v)
            }
          }
          ListView {
            id: pickerList
            anchors { left: parent.left; right: parent.right; top: pickerTitleText.bottom; bottom: parent.bottom; margins: 12; topMargin: 10; bottomMargin: root.pickerCustom ? 56 : 12 }
            clip: true
            spacing: 2
            model: root.pickerItems
            boundsBehavior: Flickable.StopAtBounds
            delegate: Rectangle {
              required property var modelData
              width: pickerList.width
              height: modelData.sub ? 44 : 34
              radius: 7
              color: modelData.current ? Qt.alpha(root.accent, 0.22) : itemArea.containsMouse ? Qt.alpha(root.fg, 0.1) : "transparent"
              Column {
                anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter
                Text { text: modelData.label; color: root.fg; font.family: root.font; font.pixelSize: Style.font.body; font.bold: !!modelData.current }
                Text { visible: !!modelData.sub; text: modelData.sub || ""; color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption }
              }
              Text { visible: !!modelData.current; anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter; text: "󰄬"; color: root.accent; font.pixelSize: Style.font.title }
              MouseArea {
                id: itemArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: { var fn = root.pickerPick; root.pickerPick = null; if (fn) fn(modelData.value) }
              }
            }
          }
        }
      }

      // ================= confirm dialog =================
      Rectangle {
        anchors.fill: parent
        visible: root.confirmAction !== null
        z: 2100
        color: Qt.rgba(0, 0, 0, 0.55)
        MouseArea { anchors.fill: parent; onClicked: root.confirmAction = null }
        Rectangle {
          anchors.centerIn: parent
          width: 420; height: confirmCol.implicitHeight + 40
          radius: 12; color: root.bg; border.width: 1; border.color: Qt.alpha(root.fg, 0.2)
          MouseArea { anchors.fill: parent }
          Column {
            id: confirmCol
            anchors.centerIn: parent
            width: parent.width - 40
            spacing: 18
            Text { width: parent.width; wrapMode: Text.WordWrap; text: root.confirmText; color: root.fg; font.family: root.font; font.pixelSize: Style.font.title }
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

  component SectionLabel: Text {
    color: root.dim
    font.family: root.font
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.1
    topPadding: 4
  }
}
