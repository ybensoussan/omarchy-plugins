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
  property var parsed: null

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color accent: Color.accent

  function open() {
    opened = true
    input.text = ""
    input.forceActiveFocus()
  }

  function close() {
    opened = false
  }

  // Accepts: "pizza in 15m", "15m pizza", "nag tea 1h30m", "call mom at 14:30", "5" (minutes)
  function parse(raw) {
    var s = raw.trim().replace(/^(nag|remind( me)?|alarm|timer)\s+/i, "")
    if (!s) return null
    var minutes = null
    var m = /\bat\s+(\d{1,2})(?::|\.)?(\d{2})?\b/i.exec(s)
    if (m) {
      var now = new Date()
      var t = new Date(now.getFullYear(), now.getMonth(), now.getDate(), parseInt(m[1]), parseInt(m[2] || "0"))
      if (t <= now) t = new Date(t.getTime() + 86400000)
      minutes = Math.ceil((t - now) / 60000)
      s = s.replace(m[0], " ")
    } else {
      var re = /(\d+(?:\.\d+)?)\s*(h(?:ours?|rs?)?|m(?:in(?:ute)?s?)?|s(?:ec(?:ond)?s?)?)(?![a-z])/gi
      var total = 0, found = false, hit
      var rest = s
      while ((hit = re.exec(s)) !== null) {
        found = true
        var n = parseFloat(hit[1]), u = hit[2][0].toLowerCase()
        total += u === "h" ? n * 60 : (u === "m" ? n : n / 60)
        rest = rest.replace(hit[0], " ")
      }
      if (found) {
        minutes = Math.max(1, Math.ceil(total - 1e-9))
        s = rest
      } else {
        var bare = /(^|\s)(\d+)(\s|$)/.exec(s)
        if (!bare) return null
        minutes = parseInt(bare[2])
        s = s.replace(bare[0], " ")
      }
    }
    var msg = s.replace(/\b(in|for|to)\b\s*$/i, "").replace(/\bin\b/i, " ").replace(/\s+/g, " ").trim()
    if (!msg) msg = "Timer"
    if (minutes < 1) minutes = 1
    return { minutes: minutes, message: msg.charAt(0).toUpperCase() + msg.slice(1) }
  }

  function describe(p) {
    if (!p) return "e.g. “pizza in 15m”, “tea 1h30m”, “call mom at 14:30”"
    var due = new Date(Date.now() + p.minutes * 60000)
    var hh = ("0" + due.getHours()).slice(-2), mm = ("0" + due.getMinutes()).slice(-2)
    return "⏰ " + p.message + " — in " + p.minutes + "m (" + hh + ":" + mm + ")"
  }

  function submit() {
    var p = parse(input.text)
    if (!p) return
    close()
    Quickshell.execDetached(["omarchy", "reminder", String(p.minutes), p.message])
  }

  IpcHandler {
    target: "yonathan.nag"
    function toggle(): void { if (root.opened) root.close(); else root.open() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
  }

  FloatingWindow {
    visible: root.opened
    title: "Disposable Alarms"
    color: root.background
    width: 640
    height: 120

    onVisibleChanged: if (!visible) root.opened = false

    FocusScope {
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.close()

      Column {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 12

        TextField {
          id: input
          width: parent.width
          placeholderText: "nag pizza in 15m"
          foreground: root.foreground
          onTextChanged: root.parsed = root.parse(text)
          onAccepted: root.submit()
          Keys.onEscapePressed: root.close()
        }

        Text {
          text: root.describe(root.parsed)
          color: root.parsed ? root.accent : Qt.alpha(root.foreground, 0.6)
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body !== undefined ? Style.font.body : 14
          elide: Text.ElideRight
          width: parent.width
        }
      }
    }
  }
}
