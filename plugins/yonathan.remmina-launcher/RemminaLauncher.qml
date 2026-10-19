import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property var connections: []
  property var matches: []
  property int selected: 0

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color border: Color.menu.border
  readonly property color accent: Color.accent

  function refresh() {
    loadConnections.running = true
  }

  function open() {
    opened = true
    search.text = ""
    refresh()
  }

  function close() {
    opened = false
  }

  function updateMatches() {
    var terms = search.text.trim().toLowerCase().split(/\s+/).filter(function(t) { return t })
    matches = connections.filter(function(entry) {
      var haystack = (entry.name + " " + entry.proto + " " + entry.server).toLowerCase()
      return terms.every(function(term) { return haystack.indexOf(term) >= 0 })
    })
    selected = 0
  }

  function activate(index) {
    var entry = matches[index]
    if (!entry) return
    close()
    Quickshell.execDetached(["uwsm-app", "--", "remmina", "-c", entry.file])
  }

  Process {
    id: loadConnections
    command: [Quickshell.env("HOME") + "/.config/omarchy/plugins/yonathan.remmina-launcher/list.sh"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.connections = text.split("\n").filter(function(l) { return l }).map(function(l) {
          var p = l.split("\t")
          return { name: p[0], proto: p[1], server: p[2], file: p[3] }
        })
        root.updateMatches()
        search.forceActiveFocus()
      }
    }
  }

  IpcHandler {
    target: "yonathan.remmina-launcher"
    function toggle(): void { if (root.opened) root.close(); else root.open() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
  }

  FloatingWindow {
    id: popup
    visible: root.opened
    title: "Remmina Launcher"
    color: root.background
    width: 1020
    height: 510

    onVisibleChanged: if (!visible) root.opened = false

    FocusScope {
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.close()
      Keys.onDownPressed: root.selected = Math.min(root.selected + 1, root.matches.length - 1)
      Keys.onUpPressed: root.selected = Math.max(root.selected - 1, 0)

      Column {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 14

        Text {
          text: "Remmina Launcher"
          color: root.foreground
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        TextField {
          id: search
          width: parent.width
          placeholderText: "Search connections, protocols, or servers"
          foreground: root.foreground
          onTextChanged: root.updateMatches()
          onAccepted: root.activate(root.selected)
          Keys.onEscapePressed: root.close()
          Keys.onDownPressed: root.selected = Math.min(root.selected + 1, root.matches.length - 1)
          Keys.onUpPressed: root.selected = Math.max(root.selected - 1, 0)
        }

        ListView {
          id: list
          width: parent.width
          height: 58 * 5 + 4 * 4
          model: root.matches
          clip: true
          spacing: 4
          currentIndex: root.selected

          onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

          delegate: Rectangle {
            required property var modelData
            required property int index
            readonly property bool current: index === root.selected
            readonly property color rowSecondary: current ? Qt.alpha(root.foreground, 0.82) : Qt.alpha(root.foreground, 0.6)
            width: list.width
            height: 58
            radius: 7
            color: current ? Qt.alpha(root.accent, 0.22) : root.background
            border.color: current ? root.accent : root.border
            border.width: current ? 2 : 1

            Rectangle {
              visible: parent.current
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: 5
              radius: 4
              color: root.accent
            }

            Column {
              anchors.left: parent.left
              anchors.right: proto.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: 16
              anchors.rightMargin: 12
              spacing: 2
              Text {
                width: parent.width
                text: modelData.name
                color: root.foreground
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                text: modelData.server
                color: parent.parent.rowSecondary
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
            Text {
              id: proto
              anchors.right: parent.right
              anchors.rightMargin: 16
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.proto
              color: root.foreground
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onEntered: root.selected = index
              onClicked: root.activate(index)
            }
          }
        }

        Text {
          visible: root.matches.length === 0
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "No connections match your search"
          color: Qt.alpha(root.foreground, 0.6)
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
        }

        Text {
          text: "Enter to connect  •  Esc to close"
          color: Qt.alpha(root.foreground, 0.5)
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
