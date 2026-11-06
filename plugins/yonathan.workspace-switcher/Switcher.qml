import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "SwitcherModel.js" as M

// Workspace switcher: every connected monitor's visible workspaces in columns laid out like the
// monitors, each in the colour the Displays & Workspaces manager gives that monitor.
//   omarchy-shell shell toggle yonathan.workspace-switcher switch   go to a workspace
//   omarchy-shell shell toggle yonathan.workspace-switcher move     move the focused window there
// Enter does the mode's action, Shift+Enter the other one; 1-0 picks that slot in the column.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  property string mode: "switch"          // "switch" | "move"
  property var order: null
  property var blocks: ({})
  property var columns: []
  property var activeWindow: null
  property var sel: ({ col: 0, row: 0 })
  property string query: ""

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color accent: Color.accent
  readonly property color scrim: Color.menu.scrim
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property string font: Style.font.menuFamily
  readonly property color dim: Qt.alpha(foreground, 0.55)

  readonly property int colWidth: Style.space(290)
  readonly property int colGap: Style.space(14)
  readonly property int tileHeight: Style.space(72)
  readonly property int tileGap: Style.space(6)
  readonly property int iconSize: Style.space(22)
  // Hover only selects once the pointer moves, so a resting pointer can't steal the cursor on open.
  property bool pointerMoved: false

  function hueColor(index, alpha) { return Qt.hsla(M.hue(index), 0.55, 0.62, alpha === undefined ? 1 : alpha) }
  function tileAt(s) { var c = columns[s.col]; return c ? c.tiles[s.row] || null : null }
  readonly property var current: tileAt(sel)
  readonly property bool hasWindow: !!(activeWindow && activeWindow.address)
  readonly property bool moving: mode === "move" && hasWindow

  // ---- icons -------------------------------------------------------------
  property var iconCache: ({})
  function iconFor(cls) {
    if (iconCache[cls] !== undefined) return iconCache[cls]
    var entry = DesktopEntries.heuristicLookup(cls)
    var name = entry && entry.icon ? String(entry.icon) : cls
    var path = name.charAt(0) === "/" ? Util.fileUrl(name) : Quickshell.iconPath(name, true)
    if (!path) path = Quickshell.iconPath(String(cls).toLowerCase(), true)
    iconCache[cls] = path || ""
    return iconCache[cls]
  }
  function appName(cls) {
    var entry = DesktopEntries.heuristicLookup(cls)
    if (entry && entry.name) return String(entry.name)
    var parts = String(cls || "").split(".")
    return parts[parts.length - 1]
  }
  // One icon per app, most recent first.
  function uniqueApps(apps) {
    var seen = {}, out = []
    apps.forEach(function(a) { if (!seen[a.cls]) { seen[a.cls] = 1; out.push(a) } })
    return out
  }

  // ---- data --------------------------------------------------------------
  FileView {
    path: Quickshell.env("HOME") + "/.config/hypr/workspace-order.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { root.order = JSON.parse(text()) } catch (e) { root.order = null } }
    onLoadFailed: root.order = null
  }

  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/monitor-workspaces"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var next = {}
      String(text() || "").split("\n").forEach(function(line) {
        var f = line.split("\t")
        if (f.length >= 3 && f[1] !== "") next[f[1]] = parseInt(f[0], 10)
      })
      root.blocks = next
    }
    onLoadFailed: root.blocks = ({})
  }

  Process {
    id: snapshot
    command: ["sh", "-c", "printf '{\"clients\":%s,\"monitors\":%s,\"active\":%s}' \"$(hyprctl -j clients)\" \"$(hyprctl -j monitors)\" \"$(hyprctl -j activewindow)\""]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = null
        try { data = JSON.parse(text) } catch (e) { console.warn("workspace-switcher: bad hyprctl output", e); return }
        root.activeWindow = data.active && data.active.address ? data.active : null
        root.columns = M.buildColumns(root.order, root.blocks, data.clients, data.monitors)
        root.sel = M.initialSelection(root.columns)
      }
    }
  }

  // ---- lifecycle -----------------------------------------------------------
  function open(payload) {
    var wanted = String(payload || "")
    try { var parsed = JSON.parse(wanted); wanted = parsed.mode || parsed } catch (e) {}
    mode = wanted === "move" ? "move" : "switch"
    pointerMoved = false
    query = ""
    filter.text = ""
    opened = true
    snapshot.running = true
  }

  function close() { opened = false }

  // ---- actions -------------------------------------------------------------
  function activate(alternate) {
    var column = columns[sel.col]
    var tile = current
    if (!column || !tile || !M.valid(columns, sel, query)) return
    var move = (mode === "move") !== !!alternate
    var ref = column.output + ":" + tile.slot
    close()
    if (move && hasWindow) Quickshell.execDetached(["omarchy-display-profiles", "send", ref])
    else Quickshell.execDetached(["hyprctl", "dispatch", "o.workspaces.focus(" + tile.slot + ", \"" + column.output + "\")"])
  }

  function select(next) { if (next) sel = next }

  onQueryChanged: if (!M.valid(columns, sel, query)) select(M.firstMatch(columns, sel, query))

  // ---- window --------------------------------------------------------------
  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "yonathan-workspace-switcher"

    onContentRevealedChanged: if (contentRevealed) filter.forceActiveFocus()

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.close() }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.max(Style.space(420), Math.max(1, root.columns.length) * (root.colWidth + root.colGap) - root.colGap + 2 * padding)
      height: content.implicitHeight + 2 * padding
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      opacity: panel.contentRevealed ? 1 : 0
      scale: panel.contentRevealed ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

      MouseArea { anchors.fill: parent }

      Item {
        id: keys
        Keys.onPressed: function(event) {
          var shift = event.modifiers & Qt.ShiftModifier
          switch (event.key) {
          case Qt.Key_Escape: root.close(); break
          case Qt.Key_Up: root.select(M.step(root.columns, root.sel, 0, -1, root.query)); break
          case Qt.Key_Down: root.select(M.step(root.columns, root.sel, 0, 1, root.query)); break
          case Qt.Key_Left: root.select(M.step(root.columns, root.sel, -1, 0, root.query)); break
          case Qt.Key_Right: root.select(M.step(root.columns, root.sel, 1, 0, root.query)); break
          case Qt.Key_Tab: root.select(M.step(root.columns, root.sel, 0, 1, root.query)); break
          case Qt.Key_Backtab: root.select(M.step(root.columns, root.sel, 0, -1, root.query)); break
          case Qt.Key_Return:
          case Qt.Key_Enter: root.activate(shift); break
          default:
            // With nothing typed, a digit is Super+N on the cursor's monitor.
            var slot = root.query === "" ? M.slotForKey(event.text) : 0
            if (!slot) return
            var hit = M.slotInColumn(root.columns, root.sel, slot)
            if (hit) { root.sel = hit; root.activate(shift) }
          }
          event.accepted = true
        }
      }

      Column {
        id: content
        x: card.padding
        y: card.padding
        width: card.width - 2 * card.padding
        spacing: Style.space(14)

        // ---------- header: mode, the window being moved, search ----------
        Item {
          width: parent.width
          height: Style.space(40)

          Row {
            id: modeRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.moving ? "󰁔" : "󰕰"
              color: root.accent
              font.pixelSize: Style.font.display
            }
            Column {
              anchors.verticalCenter: parent.verticalCenter
              Text {
                text: root.moving ? "Move window" : "Switch workspace"
                color: root.foreground; font.family: root.font; font.pixelSize: Style.font.title; font.bold: true
              }
              Text {
                text: root.moving ? "Enter moves it · Shift+Enter just goes there" : "Enter goes there · Shift+Enter brings the focused window"
                color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption
              }
            }
          }

          // The window being moved.
          Rectangle {
            visible: root.moving
            anchors.left: modeRow.right
            anchors.leftMargin: Style.space(16)
            anchors.right: search.left
            anchors.rightMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            height: Style.space(34)
            radius: height / 2
            color: Qt.alpha(root.accent, 0.12)
            border.width: 1
            border.color: Qt.alpha(root.accent, 0.35)
            Row {
              anchors.left: parent.left; anchors.leftMargin: Style.space(10)
              anchors.right: parent.right; anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)
              Image {
                width: Style.space(20); height: width
                anchors.verticalCenter: parent.verticalCenter
                source: root.activeWindow ? root.iconFor(root.activeWindow["class"]) : ""
                sourceSize.width: width * 2; sourceSize.height: height * 2
                visible: status === Image.Ready
              }
              Text {
                width: parent.width - Style.space(28)
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: root.activeWindow ? (root.appName(root.activeWindow["class"]) + "  —  " + root.activeWindow.title) : ""
                color: root.foreground; font.family: root.font; font.pixelSize: Style.font.bodySmall
              }
            }
          }

          Rectangle {
            id: search
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(220)
            height: Style.space(34)
            radius: Math.min(Style.cornerRadius + 4, height / 2)
            color: Qt.alpha(root.foreground, 0.05)
            border.width: 1
            border.color: filter.text ? Qt.alpha(root.accent, 0.7) : Qt.alpha(root.foreground, 0.12)
            Text {
              id: searchGlyph
              anchors.left: parent.left; anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: "󰍉"; color: root.dim; font.pixelSize: Style.font.title
            }
            FilterInput {
              id: filter
              anchors.left: searchGlyph.right; anchors.leftMargin: Style.space(8)
              anchors.right: parent.right; anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              keyHandler: keys
              focus: root.opened
              color: root.foreground
              font.family: root.font
              font.pixelSize: Style.font.body
              onTextChanged: root.query = text
              Text {
                visible: !filter.text
                anchors.verticalCenter: parent.verticalCenter
                text: "name, app or monitor"
                color: Qt.alpha(root.foreground, 0.35); font.family: root.font; font.pixelSize: Style.font.body
              }
            }
          }
        }

        // ---------- monitors ----------
        Row {
          spacing: root.colGap

          Repeater {
            model: root.columns

            delegate: Rectangle {
              id: column
              required property var modelData
              required property int index
              readonly property color hue: root.hueColor(modelData.index)

              width: root.colWidth
              height: columnContent.implicitHeight + Style.space(12)
              radius: Math.max(Style.cornerRadius, 8)
              color: Qt.alpha(column.hue, 0.05)
              border.width: 1
              border.color: Qt.alpha(column.hue, modelData.focused ? 0.55 : 0.22)

              // A thin band in the monitor's colour.
              Rectangle {
                anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: parent.radius; rightMargin: parent.radius }
                height: 3
                color: column.hue
                opacity: column.modelData.focused ? 1 : 0.6
              }

              Column {
                id: columnContent
                x: Style.space(6)
                y: Style.space(6)
                width: parent.width - Style.space(12)
                spacing: root.tileGap

                // header
                Item {
                  width: parent.width
                  height: Style.space(50)
                  Text {
                    id: glyph
                    anchors.left: parent.left; anchors.leftMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: column.modelData.internal ? "󰌢" : "󰍹"
                    rotation: column.modelData.portrait ? 90 : 0
                    color: column.hue
                    font.pixelSize: Style.font.display
                  }
                  Column {
                    anchors.left: glyph.right; anchors.leftMargin: Style.space(10)
                    anchors.right: focusPill.left; anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                      width: parent.width; elide: Text.ElideRight
                      text: column.modelData.short
                      color: root.foreground; font.family: root.font; font.pixelSize: Style.font.heading; font.bold: true
                    }
                    Text {
                      width: parent.width; elide: Text.ElideRight
                      text: column.modelData.label + "  ·  " + column.modelData.output
                      color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption
                    }
                  }
                  Rectangle {
                    id: focusPill
                    visible: column.modelData.focused
                    anchors.right: parent.right; anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    width: visible ? pillText.implicitWidth + Style.space(12) : 0
                    height: Style.space(18); radius: height / 2
                    color: Qt.alpha(column.hue, 0.22)
                    Text {
                      id: pillText
                      anchors.centerIn: parent
                      text: "FOCUSED"; color: column.hue
                      font.family: root.font; font.pixelSize: Style.font.caption - 2; font.bold: true; font.letterSpacing: 1
                    }
                  }
                }

                Repeater {
                  model: column.modelData.tiles

                  delegate: Rectangle {
                    id: tile
                    required property var modelData
                    required property int index
                    readonly property bool selected: root.sel.col === column.index && root.sel.row === index
                    readonly property bool match: M.matches(modelData, column.modelData, root.query)
                    readonly property var apps: root.uniqueApps(modelData.apps)

                    width: columnContent.width
                    height: root.tileHeight
                    radius: Math.max(Style.cornerRadius, 7)
                    opacity: match ? 1 : 0.22
                    color: selected ? Qt.alpha(root.accent, 0.16)
                         : hover.containsMouse ? Qt.alpha(root.foreground, 0.07)
                         : Qt.alpha(root.foreground, modelData.apps.length ? 0.04 : 0.02)
                    border.width: selected ? 2 : modelData.focused ? 1 : 0
                    border.color: selected ? root.accent : Qt.alpha(column.hue, 0.7)
                    Behavior on color { ColorAnimation { duration: 90 } }
                    Behavior on opacity { NumberAnimation { duration: 120 } }

                    MouseArea {
                      id: hover
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onPositionChanged: {
                        if (!root.pointerMoved) { root.pointerMoved = true; return }
                        if (tile.match && !tile.selected) root.sel = { col: column.index, row: tile.index }
                      }
                      onClicked: function(mouse) {
                        root.sel = { col: column.index, row: tile.index }
                        root.activate(mouse.modifiers & Qt.ShiftModifier)
                      }
                    }

                    // keycap: Super + this key reaches the workspace on its monitor
                    Rectangle {
                      id: keycap
                      x: Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(38); height: width
                      radius: Math.max(Style.cornerRadius, 7)
                      color: tile.modelData.shown ? column.hue : Qt.alpha(column.hue, 0.14)
                      border.width: 1
                      border.color: Qt.alpha(column.hue, tile.modelData.shown ? 1 : 0.45)
                      Text {
                        anchors.centerIn: parent
                        text: tile.modelData.key
                        color: tile.modelData.shown ? root.background : root.foreground
                        font.family: root.font; font.pixelSize: Style.font.title; font.bold: true
                      }
                    }

                    Column {
                      anchors.left: keycap.right; anchors.leftMargin: Style.space(12)
                      anchors.right: stateMark.left; anchors.rightMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(4)

                      Text {
                        width: parent.width; elide: Text.ElideRight
                        text: tile.modelData.label
                        color: tile.modelData.name ? root.foreground : root.dim
                        font.family: root.font; font.pixelSize: Style.font.title; font.bold: tile.modelData.shown
                        font.italic: !tile.modelData.name
                      }

                      Row {
                        spacing: Style.space(6)
                        height: root.iconSize
                        Repeater {
                          model: tile.apps.slice(0, 6)
                          delegate: Item {
                            required property var modelData
                            width: root.iconSize; height: width
                            Image {
                              id: appIcon
                              anchors.fill: parent
                              source: root.iconFor(modelData.cls)
                              sourceSize.width: width * 2; sourceSize.height: height * 2
                              smooth: true
                              visible: status === Image.Ready
                            }
                            Rectangle {
                              anchors.fill: parent
                              visible: appIcon.status !== Image.Ready
                              radius: 4
                              color: Qt.alpha(column.hue, 0.3)
                              Text {
                                anchors.centerIn: parent
                                text: root.appName(modelData.cls).charAt(0).toUpperCase()
                                color: root.foreground; font.family: root.font; font.pixelSize: Style.font.caption - 1; font.bold: true
                              }
                            }
                          }
                        }
                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          visible: tile.apps.length > 6 || tile.modelData.apps.length === 0 || tile.modelData.apps.length > tile.apps.length
                          text: tile.modelData.apps.length === 0 ? "empty"
                                : tile.apps.length > 6 ? "+" + (tile.apps.length - 6)
                                : "×" + tile.modelData.apps.length
                          color: Qt.alpha(root.foreground, 0.4)
                          font.family: root.font; font.pixelSize: Style.font.caption
                        }
                      }
                    }

                    // on screen / focused marker
                    Item {
                      id: stateMark
                      anchors.right: parent.right; anchors.rightMargin: Style.space(12)
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(10); height: width
                      Rectangle {
                        anchors.centerIn: parent
                        visible: tile.modelData.shown
                        width: tile.modelData.focused ? Style.space(10) : Style.space(7)
                        height: width; radius: width / 2
                        color: tile.modelData.focused ? root.accent : column.hue
                        SequentialAnimation on opacity {
                          running: tile.modelData.focused && root.opened
                          loops: Animation.Infinite
                          NumberAnimation { from: 1; to: 0.35; duration: 900; easing.type: Easing.InOutSine }
                          NumberAnimation { from: 0.35; to: 1; duration: 900; easing.type: Easing.InOutSine }
                        }
                      }
                    }
                  }
                }

                Text {
                  visible: column.modelData.tiles.length === 0
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  topPadding: Style.space(8); bottomPadding: Style.space(8)
                  text: "No visible workspaces"
                  color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        // ---------- key hints ----------
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(18)
          Repeater {
            model: [
              { keys: "↑ ↓ ← →", text: "move" },
              { keys: "1 – 0", text: "slot on this monitor" },
              { keys: "⏎", text: root.moving ? "move window" : "switch" },
              { keys: "⇧ ⏎", text: root.moving ? "switch only" : "bring window" },
              { keys: "esc", text: "close" }
            ]
            delegate: Row {
              required property var modelData
              spacing: Style.space(6)
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: keyText.implicitWidth + Style.space(12); height: Style.space(20)
                radius: Math.max(Style.cornerRadius, 4)
                color: Qt.alpha(root.foreground, 0.06)
                border.width: 1; border.color: Qt.alpha(root.foreground, 0.16)
                Text {
                  id: keyText
                  anchors.centerIn: parent
                  text: modelData.keys
                  color: root.foreground; font.family: root.font; font.pixelSize: Style.font.caption
                }
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.text
                color: root.dim; font.family: root.font; font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }
}
