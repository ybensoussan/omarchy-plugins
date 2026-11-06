import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "WorkspaceOrder.js" as WorkspaceOrder

// Each bar shows its own monitor's workspaces: Omarchy gives every monitor 1-10 of its own
// (a block of ten Hyprland ids), and the active display profile names them and hides the
// ones it does not use (~/.config/hypr/workspace-order.json).
BarWidget {
  id: root
  moduleName: "yonathan.workspaces"

  readonly property var monitor: {
    var window = root.QsWindow.window
    var screen = window ? window.screen : null
    return screen ? Hyprland.monitorFor(screen) : Hyprland.focusedMonitor
  }
  readonly property string monitorName: root.monitor ? root.monitor.name : ""

  property var order: null
  property var blocks: ({})
  property int workspaceRevision: 0

  FileView {
    path: Quickshell.env("HOME") + "/.config/hypr/workspace-order.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.order = JSON.parse(text()) }
      catch (error) { root.order = null }
    }
    onLoadFailed: root.order = null
  }

  // Connector -> block, from the file Omarchy keeps them in.
  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/monitor-workspaces"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var next = {}
      var lines = String(text() || "").split("\n")
      for (var i = 0; i < lines.length; i++) {
        var fields = lines[i].split("\t")
        if (fields.length >= 3 && fields[1] !== "") next[fields[1]] = parseInt(fields[0], 10)
      }
      root.blocks = next
    }
    onLoadFailed: root.blocks = ({})
  }

  // Until Omarchy has written the file, the workspace a monitor shows is in its own block.
  readonly property int block: {
    var known = root.blocks[root.monitorName]
    if (known !== undefined) return known
    var active = root.monitor && root.monitor.activeWorkspace ? root.monitor.activeWorkspace.id : 0
    return active > 0 ? WorkspaceOrder.blockOf(active) : 0
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (Number(values[i].id) === Number(id)) return values[i]
    }
    return null
  }

  function buttons() {
    var _ = root.workspaceRevision
    var live = Hyprland.workspaces.values.map(function(w) {
      return { id: Number(w.id), name: String(w.name || ""), monitor: w.monitor ? String(w.monitor.name || "") : "" }
    })
    return WorkspaceOrder.entries(root.order, root.monitorName, root.block, live)
  }

  function dispatch(expression) {
    if (root.bar) root.bar.run("hyprctl dispatch " + Util.shellQuote(expression))
  }

  // Omarchy's focus brings a slot's workspace back to its own monitor if an unplug left it elsewhere.
  function focusEntry(entry) {
    if (entry.guest) root.dispatch("hl.dsp.focus({ workspace = \"" + entry.id + "\" })")
    else root.dispatch("o.workspaces.focus(" + entry.slot + ", \"" + root.monitorName + "\")")
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      // Quickshell misses workspaces that move between monitors or change number, so ask Hyprland.
      if (name === "moveworkspacev2" || name === "changeworkspaceid" || name === "renameworkspace"
          || (name === "workspacev2" && root.monitor !== null && root.monitor.focused)) {
        Hyprland.refreshMonitors()
        Hyprland.refreshWorkspaces()
        root.workspaceRevision++
      }
    }
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.buttons().length
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.buttons()

      WidgetButton {
        required property var modelData
        required property int index

        readonly property var workspace: root.workspaceById(modelData.id)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool focused: root.monitor !== null && root.monitor.activeWorkspace !== null
          && root.monitor.activeWorkspace.id === modelData.id
        readonly property bool firstGuest: modelData.guest && index > 0 && !root.buttons()[index - 1].guest

        // A gap sets workspaces visiting from an unplugged monitor apart from this one's own.
        Layout.leftMargin: firstGuest && !root.vertical ? Style.space(6) : 0
        Layout.topMargin: firstGuest && root.vertical ? Style.space(6) : 0

        bar: root.bar
        text: modelData.label
        active: focused
        activeColor: "#ff8800"
        foreground: focused ? "#ff8800" : root.bar.barForeground
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : -1
        fixedHeight: root.barSize
        onPressed: function() { root.focusEntry(modelData) }
      }
    }
  }
}
