import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "bw-vault"

  property bool running: false
  readonly property string pidFile: Quickshell.env("XDG_RUNTIME_DIR") + "/bw-vault.pid"

  function refresh() {
    statusProc.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: statusProc
    command: ["bash", "-lc", "test -s '" + root.pidFile + "' && kill -0 \"$(< '" + root.pidFile + "')\" 2>/dev/null"]
    onExited: function(code) { root.running = code === 0 }
  }

  Process { id: toggleProc; command: ["bw-vault-toggle"] }
  Process { id: exitProc; command: ["bw-vault-exit"] }

  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.running ? "󰟶" : "󰟵"
    tooltipText: root.running ? "Bitwarden vault active. Right-click to exit." : "Open Bitwarden vault"
    onPressed: function(mouse) {
      if (mouse.button === Qt.RightButton) exitProc.running = true
      else toggleProc.running = true
      root.refresh()
    }
  }
}
