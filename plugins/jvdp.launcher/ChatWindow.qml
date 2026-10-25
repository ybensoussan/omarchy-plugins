import Quickshell
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Ask Claude or Ask OpenCode as a conversation: a window of its own, on top of the others,
// that stays while you work. Each question is a turn; follow-ups resume the
// same Claude session (the backend passes --resume). Answers arrive sanitized
// Markdown; code blocks get their own Copy button.
//
//   Enter          send            Ctrl+N        new conversation
//   Ctrl+Shift+C   copy last answer Esc          close (the conversation stays)
Item {
  id: chat

  property var launcher: null

  // Which backend answers: "claude" or "opencode" (one window of each).
  property string agent: "claude"
  readonly property string agentName: agent === "opencode" ? "OpenCode" : "Claude"
  readonly property string agentGlyph: agent === "opencode" ? "󰆍" : "󰚩"
  readonly property string windowTitle: "Ask " + agentName
  readonly property string readOnlyNote: agent === "opencode"
    ? (String(launcher.look("opencode", "agent", "plan") || "default") + " agent")
    : "read-only"

  property string session: ""     // Claude's session id, once the first answer started
  property int generation: 0       // bumped by New: late events from an old conversation are ignored
  readonly property bool busy: turns.count > 0 && !turns.get(turns.count - 1).done
  property string notice: ""

  ListModel { id: turns }          // {turnId, q, text, status, done}

  function ask(q) {
    q = String(q || "").trim()
    if (!q) return
    chat.show()
    if (chat.busy) return
    var turnId = chat.generation + "-" + turns.count
    turns.append({ turnId: turnId, q: q, text: "", status: "Thinking…", done: false })
    launcher.send({ op: "chat", agent: chat.agent, turn: turnId, q: q, session: chat.session })
    Qt.callLater(function() { input.forceActiveFocus(); list.positionViewAtEnd() })
  }

  function onBackend(msg) {
    for (var i = turns.count - 1; i >= 0; i--) {
      if (turns.get(i).turnId !== msg.turn) continue
      if (msg.session) chat.session = String(msg.session)
      if (msg.text !== undefined) turns.setProperty(i, "text", String(msg.text))
      if (msg.status !== undefined) turns.setProperty(i, "status", String(msg.status))
      if (msg.done) turns.setProperty(i, "done", true)
      return
    }
  }

  // The launcher closes right after asking, and Hyprland hands focus back to
  // the window from before; take it once the overlay is gone.
  function show() {
    window.visible = true
    focusTimer.restart()
  }
  Timer {
    id: focusTimer
    interval: 150
    onTriggered: {
      Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ window = \"title:^" + chat.windowTitle + "$\" })"])
      input.forceActiveFocus()
    }
  }

  function newChat() {
    if (chat.busy) launcher.send({ op: "stop", agent: chat.agent })
    chat.generation += 1
    chat.session = ""
    turns.clear()
    input.text = ""
    input.forceActiveFocus()
  }

  function close() {
    if (chat.busy) launcher.send({ op: "stop", agent: chat.agent })
    window.visible = false
  }

  function copy(text, what) {
    if (!text) return
    launcher.send({ op: "copy", text: text })
    chat.notice = what + " copied"
    noticeTimer.restart()
  }

  function copyLast() {
    for (var i = turns.count - 1; i >= 0; i--)
      if (turns.get(i).text) { chat.copy(turns.get(i).text, "Answer"); return }
  }

  Timer { id: noticeTimer; interval: 1600; onTriggered: chat.notice = "" }

  // Prose and fenced code blocks, in order; an unclosed fence (still
  // streaming) counts as code up to the end.
  function segments(text) {
    var out = [], prose = [], code = null
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      if (/^\s*(```|~~~)/.test(lines[i])) {
        if (code === null) {
          if (prose.join("\n").trim()) out.push({ code: false, text: prose.join("\n") })
          prose = []
          code = []
        } else {
          out.push({ code: true, text: code.join("\n") })
          code = null
        }
        continue
      }
      if (code !== null) code.push(lines[i])
      else prose.push(lines[i])
    }
    if (code !== null) out.push({ code: true, text: code.join("\n") })
    if (prose.join("\n").trim()) out.push({ code: false, text: prose.join("\n") })
    return out
  }

  FloatingWindow {
    id: window
    title: chat.windowTitle
    color: chat.launcher.background
    implicitWidth: 900
    implicitHeight: 700
    minimumSize: Qt.size(520, 360)
    visible: false

    // Closed by the compositor (Super+W): stop a running answer, keep the rest.
    onVisibleChanged: if (!visible && chat.busy) chat.launcher.send({ op: "stop", agent: chat.agent })

    FocusScope {
      id: scope
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        var ctrl = event.modifiers & Qt.ControlModifier
        if (event.key === Qt.Key_Escape) { chat.close(); event.accepted = true }
        else if (ctrl && event.key === Qt.Key_N) { chat.newChat(); event.accepted = true }
        else if (ctrl && (event.modifiers & Qt.ShiftModifier) && event.key === Qt.Key_C) { chat.copyLast(); event.accepted = true }
      }

      // ---- Header ---------------------------------------------------------------
      Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: chat.launcher.headerHeight
        anchors.margins: chat.launcher.contentMargin

        Text {
          id: titleText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: chat.agentGlyph + "  " + chat.windowTitle
          color: chat.launcher.foreground
          font.family: chat.launcher.fontFamily
          font.pixelSize: Style.font.heading
        }

        Text {
          anchors.left: titleText.right
          anchors.leftMargin: Style.spacing.md
          anchors.right: buttons.left
          anchors.rightMargin: Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: chat.notice || ("from " + chat.launcher.look(chat.agent, "folder", "~") + " · " + chat.readOnlyNote)
          color: chat.notice ? chat.launcher.accent : chat.launcher.foreground
          opacity: chat.notice ? 1 : 0.55
          font.family: chat.launcher.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Row {
          id: buttons
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.sm

          Button {
            text: "Copy last"
            tooltipText: "Ctrl+Shift+C"
            foreground: chat.launcher.foreground
            accent: chat.launcher.accent
            fontFamily: chat.launcher.fontFamily
            bordered: true
            enabled: turns.count > 0
            onClicked: chat.copyLast()
          }
          Button {
            text: "New"
            tooltipText: "Ctrl+N"
            foreground: chat.launcher.foreground
            accent: chat.launcher.accent
            fontFamily: chat.launcher.fontFamily
            bordered: true
            onClicked: chat.newChat()
          }
          Button {
            text: "✕"
            tooltipText: "Esc"
            foreground: chat.launcher.foreground
            accent: chat.launcher.accent
            fontFamily: chat.launcher.fontFamily
            bordered: true
            onClicked: chat.close()
          }
        }
      }

      Rectangle {
        id: rule
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Util.alpha(chat.launcher.foreground, 0.12)
      }

      // ---- Conversation ---------------------------------------------------------
      ListView {
        id: list
        anchors.top: rule.bottom
        anchors.bottom: inputBox.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: chat.launcher.contentMargin
        clip: true
        spacing: Style.space(18)
        model: turns
        boundsBehavior: Flickable.StopAtBounds

        // Follow a growing answer, unless scrolled up to read.
        property bool atBottom: true
        onContentYChanged: atBottom = contentY >= contentHeight - height - Style.space(40)
        onContentHeightChanged: if (atBottom) positionViewAtEnd()

        delegate: Column {
          id: turn
          width: list.width
          spacing: Style.spacing.md

          required property int index
          required property string q
          required property string text
          required property string status
          required property bool done

          // The question.
          Rectangle {
            width: Math.min(turn.width, qText.implicitWidth + Style.spacing.md * 2)
            height: qText.implicitHeight + Style.spacing.sm * 2
            radius: chat.launcher.cornerRadius
            color: Util.alpha(chat.launcher.accent, 0.14)
            Text {
              id: qText
              anchors.fill: parent
              anchors.margins: Style.spacing.sm
              anchors.leftMargin: Style.spacing.md
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: turn.q
              color: chat.launcher.foreground
              font.family: chat.launcher.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          // The answer: prose and code blocks.
          Repeater {
            model: chat.segments(turn.text)

            delegate: Loader {
              required property var modelData
              width: turn.width
              sourceComponent: modelData.code ? codeBlock : proseBlock
              property var seg: modelData
            }
          }

          Text {
            visible: !turn.done || turn.status !== ""
            textFormat: Text.PlainText
            text: turn.status || "…"
            color: chat.launcher.foreground
            opacity: 0.55
            font.family: chat.launcher.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            visible: turn.done && turn.text !== ""
            text: "󰆏  Copy answer"
            foreground: chat.launcher.foreground
            accent: chat.launcher.accent
            fontFamily: chat.launcher.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: chat.copy(turn.text, "Answer")
          }
        }
      }

      Component {
        id: proseBlock
        TextEdit {
          width: parent ? parent.width : 0
          readOnly: true
          selectByMouse: true
          wrapMode: TextEdit.Wrap
          textFormat: TextEdit.MarkdownText
          text: parent ? parent.seg.text : ""
          color: chat.launcher.foreground
          selectionColor: Util.alpha(chat.launcher.accent, 0.35)
          selectedTextColor: chat.launcher.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          // Links are shown, never followed: the text comes from outside.
          onLinkActivated: function(link) {}
        }
      }

      Component {
        id: codeBlock
        Rectangle {
          id: codeRect
          readonly property string code: parent ? parent.seg.text : ""
          width: parent ? parent.width : 0
          height: Math.max(codeText.implicitHeight, copyCode.implicitHeight) + Style.spacing.md * 2
          radius: chat.launcher.cornerRadius
          color: Util.alpha(chat.launcher.foreground, 0.07)
          border.width: 1
          border.color: Util.alpha(chat.launcher.foreground, 0.12)

          TextEdit {
            id: codeText
            anchors.left: parent.left
            anchors.right: copyCode.left
            anchors.top: parent.top
            anchors.margins: Style.spacing.md
            readOnly: true
            selectByMouse: true
            wrapMode: TextEdit.WrapAnywhere
            textFormat: TextEdit.PlainText
            text: codeRect.code
            color: chat.launcher.foreground
            selectionColor: Util.alpha(chat.launcher.accent, 0.35)
            selectedTextColor: chat.launcher.foreground
            font.family: chat.launcher.fontFamily
            font.pixelSize: Style.font.body
          }

          Button {
            id: copyCode
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.spacing.sm
            text: "Copy"
            foreground: chat.launcher.foreground
            accent: chat.launcher.accent
            fontFamily: chat.launcher.fontFamily
            fontSize: Style.font.bodySmall
            bordered: true
            onClicked: chat.copy(codeRect.code, "Code")
          }
        }
      }

      // ---- Follow-up --------------------------------------------------------------
      Item {
        id: inputBox
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: chat.launcher.contentMargin
        height: input.implicitHeight

        TextField {
          id: input
          anchors.fill: parent
          focus: true
          foreground: chat.launcher.foreground
          accent: chat.launcher.accent
          font.family: chat.launcher.fontFamily
          font.pixelSize: Style.font.body
          placeholderText: chat.busy ? chat.agentName + " is answering…" : (turns.count ? "Ask a follow-up…  (Enter)" : chat.windowTitle + "…  (Enter)")
          onAccepted: {
            if (chat.busy) return
            var q = text
            text = ""
            chat.ask(q)
          }
        }
      }
    }
  }
}
