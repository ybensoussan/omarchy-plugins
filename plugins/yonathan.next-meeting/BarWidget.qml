import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "yonathan.next-meeting"

  readonly property string dir: Quickshell.env("HOME") + "/.config/omarchy/plugins/yonathan.next-meeting"
  readonly property string teamsAppId: "ompifgpmddkgmclendfeacglnodjjndh"
  property var meeting: ({})
  property int now: Math.floor(Date.now() / 1000)

  readonly property bool hasMeeting: meeting.start !== undefined
  readonly property int secsToStart: hasMeeting ? meeting.start - now : 0
  readonly property bool inProgress: hasMeeting && secsToStart <= 0

  function countdown(s) {
    if (s <= 0) return "now"
    var m = Math.ceil(s / 60)
    if (m < 60) return "in " + m + "m"
    var h = Math.floor(m / 60)
    return "in " + h + "h" + (m % 60 ? " " + (m % 60) + "m" : "")
  }

  function shortTitle(t) {
    return t.length > 24 ? t.substring(0, 23) + "…" : t
  }

  function launch() {
    var cmd = ["chromium", "--profile-directory=Default", "--app-id=" + teamsAppId]
    if (meeting.url) cmd.push(meeting.url)
    Quickshell.execDetached(cmd)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  visible: hasMeeting

  Process {
    id: fetcher
    command: [root.dir + "/.venv/bin/python", root.dir + "/next-meeting.py"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.meeting = JSON.parse(text) } catch (e) { root.meeting = ({}) }
      }
    }
  }

  Timer { interval: 300000; running: true; repeat: true; triggeredOnStart: true; onTriggered: fetcher.running = true }
  Timer {
    interval: 15000; running: true; repeat: true
    onTriggered: {
      root.now = Math.floor(Date.now() / 1000)
      if (root.hasMeeting && root.meeting.end <= root.now) fetcher.running = true
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: (root.meeting.url ? "󰊻 " : "󰃭 ") + root.shortTitle(root.meeting.title || "") + " · " + root.countdown(root.secsToStart)
    tooltipText: root.meeting.url ? "Join in Teams: " + root.meeting.title : (root.meeting.title || "") + " (no Teams link)"
    onPressed: function() { root.launch() }
  }
}
