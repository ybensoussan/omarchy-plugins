import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "yonathan.workspace-backgrounds"

  readonly property string stateFile: Quickshell.env("HOME") + "/.local/state/omarchy/workspace-backgrounds.json"
  property var assignments: ({})
  property string appliedWorkspace: ""
  property string appliedPath: ""

  function readAssignments(raw) {
    try { assignments = JSON.parse(raw || "{}") } catch (e) { assignments = ({}) }
  }

  function activeWorkspaceId() {
    return Hyprland.focusedWorkspace ? String(Hyprland.focusedWorkspace.id) : ""
  }

  function applyWorkspaceBackground() {
    var workspace = activeWorkspaceId()
    var path = String(assignments[workspace] || "")
    if (!workspace || (workspace === appliedWorkspace && path === appliedPath)) return
    appliedWorkspace = workspace
    appliedPath = path
    if (path) applyProc.command = ["omarchy-theme-bg-set", path]
    if (path) applyProc.running = true
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.anchorItem = button
    target.assignments = root.assignments
    target.stateFile = root.stateFile
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onAssignmentsChanged: {
    injectPanel()
    applyWorkspaceBackground()
  }

  Connections {
    target: Hyprland
    function onFocusedWorkspaceChanged() { root.applyWorkspaceBackground() }
  }

  FileView {
    id: assignmentsFile
    path: root.stateFile
    watchChanges: true
    printErrors: false
    onLoaded: root.readAssignments(text())
    onFileChanged: reload()
    onLoadFailed: root.readAssignments("")
  }

  Process { id: applyProc }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: root.injectPanel()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰸉"
    tooltipText: "Workspace backgrounds"
    onPressed: function() {
      if (panelLoader.item) panelLoader.item.toggle()
    }
  }
}
