import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "WorkspaceOrder.js" as WorkspaceOrder

BarWidget {
  id: root
  moduleName: "yonathan.workspaces"

  property string barScreenName: ""
  property string activeProfile: ""
  property var appliedOrder: null
  property int workspaceRevision: 0

  FileView {
    path: Quickshell.env("HOME") + "/.config/hypr/workspace-profile.lua"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var match = /workspace-profiles\.([a-z0-9-]+)/.exec(text())
      root.activeProfile = match ? match[1] : ""
    }
    onLoadFailed: root.activeProfile = ""
  }

  FileView {
    path: Quickshell.env("HOME") + "/.config/hypr/workspace-order.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.appliedOrder = JSON.parse(text()) }
      catch (error) { root.appliedOrder = null }
    }
    onLoadFailed: root.appliedOrder = null
  }

  function updateBarScreen() {
    var point = root.mapToGlobal(0, 0)
    var monitors = Hyprland.monitors.values
    for (var i = 0; i < monitors.length; i++) {
      var monitor = monitors[i]
      var scale = monitor.scale || 1
      if (point.x >= monitor.x && point.x < monitor.x + monitor.width / scale
          && point.y >= monitor.y && point.y < monitor.y + monitor.height / scale) {
        barScreenName = String(monitor.name || "")
        return
      }
    }
    barScreenName = ""
  }

  Component.onCompleted: Qt.callLater(updateBarScreen)

  Timer {
    interval: 500
    running: true
    repeat: true
    onTriggered: {
      root.updateBarScreen()
      // Workspace monitor moves do not always notify Quickshell's model.
      root.workspaceRevision++
    }
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (Number(values[i].id) === Number(id)) return values[i]
    }
    return null
  }

  function workspaceName(id) {
    if (appliedOrder && Array.isArray(appliedOrder.assignments)) {
      for (var i = 0; i < appliedOrder.assignments.length; i++) {
        if (Number(appliedOrder.assignments[i].id) === Number(id)) return appliedOrder.assignments[i].name
      }
    }
    return WorkspaceOrder.nameForId(id)
  }

  function workspaceMonitorName(workspace) {
    var monitor = workspace.monitor
    if (monitor && typeof monitor === "object") return String(monitor.name || "")
    return String(monitor || workspace.monitorName || "")
  }

  function workspaceIds() {
    var _ = workspaceRevision
    var ids = WorkspaceOrder.ids(appliedOrder, activeProfile)
    var values = Hyprland.workspaces.values
    if (!barScreenName) return []

    return ids.filter(function(id) {
      if (appliedOrder && appliedOrder.profile === activeProfile && Array.isArray(appliedOrder.assignments)) {
        for (var a = 0; a < appliedOrder.assignments.length; a++) {
          if (appliedOrder.assignments[a].id === id && appliedOrder.assignments[a].output === null)
            return false
        }
      }
      for (var i = 0; i < values.length; i++) {
        var workspace = values[i]
        if (Number(workspace.id) === Number(id)) {
          var monitorName = workspaceMonitorName(workspace)
          // On a single-display setup, some Quickshell versions expose no
          // monitor object on persistent workspace entries. They still belong
          // on the only bar; assignments above continue to hide parked slots.
          if (!monitorName && Hyprland.monitors.values.length === 1) return true
          return monitorName === barScreenName
        }
      }
      return false
    })
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.workspaceIds().length
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.workspaceIds()

      WidgetButton {
        required property int modelData

        readonly property var workspace: root.workspaceById(modelData)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool focused: workspace !== null && workspace.active
          && workspace.monitor !== null && workspace.monitor.name === root.barScreenName

        readonly property string workspaceName: {
          var _ = Hyprland.workspaces.values  // establish reactive dependency
          var ws = root.workspaceById(modelData)
          if (ws !== null && ws !== undefined && ws.name && ws.name !== ""
              && String(ws.name) !== String(modelData)) return ws.name
          return root.workspaceName(modelData)
        }

        bar: root.bar
        text: workspaceName
        active: focused
        activeColor: "#ff8800"
        foreground: focused ? "#ff8800" : root.bar.barForeground
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : -1
        fixedHeight: root.barSize
        onPressed: function() { root.focusWorkspace(modelData) }
      }
    }
  }
}
