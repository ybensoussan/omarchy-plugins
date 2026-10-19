import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root
    property var all: []
    property var filtered: []

    function refilter() {
        const q = search.text.toLowerCase().trim().split(/\s+/)
        filtered = all.filter(e => q.every(t => (e.name + " " + e.proto + " " + e.server).toLowerCase().includes(t)))
        list.currentIndex = 0
    }

    function launch(e) {
        if (!e) return
        Quickshell.execDetached(["remmina", "-c", e.file])
        Qt.quit()
    }

    Process {
        running: true
        command: [Quickshell.shellDir + "/list.sh"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.all = text.split("\n").filter(l => l).map(l => {
                    const p = l.split("\t")
                    return { name: p[0], proto: p[1], server: p[2], file: p[3] }
                })
                root.refilter()
            }
        }
    }

    PanelWindow {
        id: win
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        MouseArea { anchors.fill: parent; onClicked: Qt.quit() }

        Rectangle {
            width: 560; height: 460
            anchors.centerIn: parent
            radius: 12
            color: "#1e1e2e"
            border.color: "#89b4fa"; border.width: 2

            Column {
                anchors.fill: parent; anchors.margins: 14; spacing: 10

                TextField {
                    id: search
                    width: parent.width
                    placeholderText: "Search Remmina connections…"
                    font.pixelSize: 18
                    color: "#cdd6f4"
                    focus: true
                    background: Rectangle { color: "#313244"; radius: 8 }
                    onTextChanged: root.refilter()
                    Component.onCompleted: forceActiveFocus()
                    Keys.onEscapePressed: Qt.quit()
                    Keys.onDownPressed: list.incrementCurrentIndex()
                    Keys.onUpPressed: list.decrementCurrentIndex()
                    Keys.onTabPressed: list.incrementCurrentIndex()
                    Keys.onReturnPressed: root.launch(root.filtered[list.currentIndex])
                    Keys.onEnterPressed: root.launch(root.filtered[list.currentIndex])
                }

                ListView {
                    id: list
                    width: parent.width
                    height: parent.height - search.height - 10
                    clip: true
                    model: root.filtered
                    currentIndex: 0
                    highlightMoveDuration: 0
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        width: list.width; height: 40; radius: 6
                        color: ListView.isCurrentItem ? "#45475a" : "transparent"
                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left; anchors.leftMargin: 10
                            spacing: 10
                            Text { text: modelData.name; color: "#cdd6f4"; font.pixelSize: 16 }
                            Text { text: modelData.proto + "  " + modelData.server; color: "#7f849c"; font.pixelSize: 12
                                   anchors.verticalCenter: parent.verticalCenter }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.launch(modelData)
                        }
                    }
                }
            }
        }
    }
}
