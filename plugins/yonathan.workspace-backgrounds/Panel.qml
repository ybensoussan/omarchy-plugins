import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "yonathan.workspace-backgrounds"
  manageIpc: false

  property var anchorItem: null
  property var assignments: ({})
  property string stateFile: ""
  property string currentBackground: ""
  property int selectedWorkspace: 1

  readonly property var workspaces: {
    var values = Hyprland.workspaces.values || []
    return values
      .filter(function(workspace) { return workspace.id > 0 && workspace.name.indexOf("special:") !== 0 })
      .sort(function(a, b) { return a.id - b.id })
  }
  readonly property string selectedPath: String(assignments[String(selectedWorkspace)] || "")

  function refreshCurrentBackground() {
    currentBackgroundProc.running = true
  }

  function save(path) {
    var next = {}
    for (var key in assignments) next[key] = assignments[key]
    if (path) next[String(selectedWorkspace)] = path
    else delete next[String(selectedWorkspace)]
    assignments = next
    saveProc.command = ["bash", "-c", "mkdir -p \"$(dirname " + Util.shellQuote(stateFile) + ")\" && printf '%s\\n' " + Util.shellQuote(JSON.stringify(next)) + " > " + Util.shellQuote(stateFile)]
    saveProc.running = true
  }

  function useCurrentBackground() {
    if (currentBackground) save(currentBackground)
  }

  function chooseBackground() {
    chooseProc.running = true
  }

  onOpenedChanged: if (opened) refreshCurrentBackground()

  Process {
    id: currentBackgroundProc
    command: ["readlink", "-f", Quickshell.env("HOME") + "/.local/state/omarchy/current/background"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.currentBackground = String(text || "").trim()
    }
  }

  Process { id: saveProc }

  Process {
    id: chooseProc
    command: ["omarchy-theme-bg-switcher"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = String(text || "").trim()
        if (path) root.save(path)
      }
    }
  }

  KeyboardPanel {
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: fittedContentWidth(420)
    contentHeight: fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: content
        width: parent.width
        spacing: Style.space(12)

        Text {
          text: "Workspace backgrounds"
          color: root.barForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.title
        }

        Text {
          width: parent.width
          text: "Choose a workspace, then assign the current wallpaper or pick another one. Assigned images apply when that workspace gains focus."
          wrapMode: Text.WordWrap
          color: Qt.darker(root.barForeground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        GridLayout {
          width: parent.width
          columns: 3
            columnSpacing: Style.space(6)
            rowSpacing: Style.space(6)
            Repeater {
              model: root.workspaces
              delegate: Rectangle {
                required property var modelData
                readonly property int workspaceId: modelData.id
                Layout.fillWidth: true
                Layout.preferredHeight: Style.space(28)
                radius: Style.cornerRadius
                color: root.selectedWorkspace === workspaceId ? Color.accent : "transparent"
                border.width: Style.spacing.hairline
                border.color: root.barForeground
                opacity: root.assignments[String(workspaceId)] ? 1 : 0.65

                Text {
                  id: workspaceText
                  anchors.centerIn: parent
                  text: modelData.name
                  color: root.selectedWorkspace === workspaceId ? Color.background : root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectedWorkspace = workspaceId
              }
            }
          }
        }

        Text {
          width: parent.width
          text: root.selectedPath ? "Assigned: " + root.selectedPath.split("/").pop() : "No background assigned"
          elide: Text.ElideMiddle
          color: root.barForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Row {
          spacing: Style.space(8)
          Button {
            text: "Use current"
            enabled: root.currentBackground !== ""
            onClicked: root.useCurrentBackground()
          }
          Button {
            text: "Pick image"
            onClicked: root.chooseBackground()
          }
          Button {
            text: "Clear"
            enabled: root.selectedPath !== ""
            onClicked: root.save("")
          }
        }
      }
    }
  }
}
