import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "SwitcherModel.js" as M

// Workspace switcher: every connected monitor's visible workspaces in columns laid out like the
// monitors. Styled like Omarchy's menu: the search line is the header, rows are transparent and
// only the cursor row takes the theme's selected colours.
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

  // The same theme values Omarchy's menu uses ([menu] in shell.toml).
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color scrim: Color.menu.scrim
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", Color.menu.selectedBorder, 0)
  readonly property string font: Style.font.menuFamily
  readonly property int cornerRadius: Style.cornerRadius
  readonly property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  readonly property int rowHeight: Math.max(Style.space(50), Style.font.body + Style.spacing.rowPaddingX * 2)

  readonly property int colWidth: Style.space(300)
  readonly property int colGap: Style.space(12)
  readonly property int tileGap: Style.spacing.xs
  readonly property int iconSize: Style.font.iconLarge
  // A single monitor lays its tiles out two per row, so the card isn't a tall narrow strip.
  readonly property int tilesPerRow: columns.length === 1 ? 2 : 1
  // Hover only selects once the pointer moves, so a resting pointer can't steal the cursor on open.
  property bool pointerMoved: false

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

    // The card opens centred; once revealed its top stays put, so filtering shrinks it
    // downwards instead of re-centring on every keystroke (as Omarchy's menu does).
    property int cardTop: -1
    readonly property int centeredTop: Math.max(Style.gapsOut, Math.round((height - card.height) / 2))
    onShownChanged: if (!shown) cardTop = -1
    onContentRevealedChanged: if (contentRevealed) { cardTop = centeredTop; filter.forceActiveFocus() }

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.close() }

    BorderSurface {
      id: card
      anchors.horizontalCenter: parent.horizontalCenter
      y: panel.cardTop >= 0 ? panel.cardTop : panel.centeredTop
      width: Math.max(Style.space(300), monitorsRow.implicitWidth) + 2 * padding
      height: content.implicitHeight + 2 * padding
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent }

      Item {
        id: keys
        Keys.onPressed: function(event) {
          var shift = event.modifiers & Qt.ShiftModifier
          switch (event.key) {
          case Qt.Key_Escape: root.close(); break
          case Qt.Key_Up: root.select(M.step(root.columns, root.sel, 0, -1, root.query, root.tilesPerRow)); break
          case Qt.Key_Down: root.select(M.step(root.columns, root.sel, 0, 1, root.query, root.tilesPerRow)); break
          case Qt.Key_Left: root.select(M.step(root.columns, root.sel, -1, 0, root.query, root.tilesPerRow)); break
          case Qt.Key_Right: root.select(M.step(root.columns, root.sel, 1, 0, root.query, root.tilesPerRow)); break
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
        spacing: Style.spacing.md

        // ---------- header: the search line, prompting with the mode ----------
        Item {
          width: parent.width
          height: root.headerHeight

          FilterInput {
            id: filter
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            keyHandler: keys
            color: root.foreground
            font.family: root.font
            font.pixelSize: Style.font.heading
            onTextChanged: root.query = text
          }

          Text {
            textFormat: Text.PlainText
            anchors.fill: filter
            verticalAlignment: Text.AlignVCenter
            visible: !filter.text && !filter.preeditText
            text: root.moving ? "Move " + root.appName(root.activeWindow["class"]) + " to…" : "Switch workspace…"
            color: root.foreground
            opacity: 0.58
            font.family: root.font
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        // ---------- one column per monitor, hairlines between ----------
        Row {
          id: monitorsRow
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: root.colGap

          Repeater {
            model: root.columns

            delegate: Row {
              id: columnBox
              required property var modelData
              required property int index
              spacing: root.colGap

              // Zero-height holder, so the hairline can span the tallest column without
              // feeding back into the row's own height.
              Item {
                visible: columnBox.index > 0
                width: Style.spacing.hairline
                height: 0
                Rectangle {
                  width: parent.width
                  height: monitorsRow.height
                  color: Util.alpha(root.foreground, 0.2)
                }
              }

              Column {
                id: column
                readonly property var info: columnBox.modelData
                readonly property int colIndex: columnBox.index
                width: root.colWidth * root.tilesPerRow + root.tileGap * (root.tilesPerRow - 1)
                spacing: root.tileGap

                // section header, as in Omarchy's panels
                Row {
                  spacing: Style.space(6)
                  leftPadding: Style.space(8)
                  bottomPadding: Style.space(4)
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: column.info.internal ? "󰌢" : "󰍹"
                    rotation: column.info.portrait ? 90 : 0
                    color: column.info.focused ? root.foreground : Qt.darker(root.foreground, 1.4)
                    font.family: root.font
                    font.pixelSize: Style.font.body
                  }
                  PanelSectionHeader {
                    anchors.verticalCenter: parent.verticalCenter
                    width: column.width - Style.space(40)
                    elide: Text.ElideRight
                    foreground: column.info.focused ? Qt.lighter(root.foreground, 1.4) : root.foreground
                    fontFamily: root.font
                    text: column.info.short.toUpperCase() + "  ·  " + column.info.label
                  }
                }

                Grid {
                  id: tileGrid
                  width: parent.width
                  columns: root.tilesPerRow
                  columnSpacing: root.tileGap
                  rowSpacing: root.tileGap

                  Repeater {
                    model: column.info.tiles

                    delegate: BorderSurface {
                      id: row
                      required property var modelData
                      required property int index
                      readonly property bool hasCursor: root.sel.col === column.colIndex && root.sel.row === index
                      readonly property var apps: root.uniqueApps(modelData.apps)
                      readonly property color ink: hasCursor ? root.selectedText : root.foreground

                      // Filtering leaves rows out, as Omarchy's menu does.
                      visible: M.matches(modelData, column.info, root.query)
                      width: (tileGrid.width - root.tileGap * (root.tilesPerRow - 1)) / root.tilesPerRow
                      height: root.rowHeight
                      radius: root.cornerRadius
                      color: hasCursor ? root.selectedBackground : "transparent"
                      borderSpec: hasCursor ? root.selectedBorderSpec : Border.none()

                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        // Hover only selects once the pointer moves, so a resting pointer can't
                        // steal the cursor on open.
                        onPositionChanged: {
                          if (!root.pointerMoved) { root.pointerMoved = true; return }
                          if (!row.hasCursor) root.sel = { col: column.colIndex, row: row.index }
                        }
                        onClicked: function(mouse) {
                          root.sel = { col: column.colIndex, row: row.index }
                          root.activate(mouse.modifiers & Qt.ShiftModifier)
                        }
                      }

                      // Super + this key reaches the workspace on its monitor; it sits where
                      // Omarchy's menu puts a row's icon.
                      Text {
                        id: keyText
                        textFormat: Text.PlainText
                        anchors.left: parent.left
                        anchors.leftMargin: Border.left(root.selectedBorderSpec) + Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(36)
                        horizontalAlignment: Text.AlignHCenter
                        text: row.modelData.key
                        color: row.ink
                        opacity: row.hasCursor || row.modelData.shown ? 1 : 0.45
                        font.family: root.font
                        font.pixelSize: Style.font.iconLarge
                      }

                      Text {
                        textFormat: Text.PlainText
                        anchors.left: keyText.right
                        anchors.leftMargin: Style.space(6)
                        anchors.right: trail.left
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.modelData.label
                        color: row.ink
                        opacity: row.modelData.name ? 1 : 0.58
                        font.family: root.font
                        font.pixelSize: Style.font.heading
                        font.weight: Font.Medium
                        elide: Text.ElideRight
                      }

                      // open apps, then a dot on the workspace this monitor shows
                      Row {
                        id: trail
                        anchors.right: parent.right
                        anchors.rightMargin: Border.right(root.selectedBorderSpec) + Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(6)

                        Repeater {
                          model: row.apps.slice(0, 4)
                          delegate: Item {
                            required property var modelData
                            width: root.iconSize; height: width
                            anchors.verticalCenter: parent.verticalCenter
                            Image {
                              id: appIcon
                              anchors.fill: parent
                              source: root.iconFor(modelData.cls)
                              sourceSize.width: width * Screen.devicePixelRatio
                              sourceSize.height: height * Screen.devicePixelRatio
                              fillMode: Image.PreserveAspectFit
                              asynchronous: true
                              visible: status === Image.Ready
                            }
                            Text {
                              anchors.centerIn: parent
                              visible: appIcon.status !== Image.Ready
                              textFormat: Text.PlainText
                              text: root.appName(modelData.cls).charAt(0).toUpperCase()
                              color: row.ink
                              opacity: 0.58
                              font.family: root.font
                              font.pixelSize: Style.font.body
                              font.bold: true
                            }
                          }
                        }
                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          visible: row.apps.length > 4
                          textFormat: Text.PlainText
                          text: "+" + (row.apps.length - 4)
                          color: row.ink
                          opacity: 0.45
                          font.family: root.font
                          font.pixelSize: Style.font.bodySmall
                        }
                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(8)
                          horizontalAlignment: Text.AlignHCenter
                          textFormat: Text.PlainText
                          text: row.modelData.shown ? "●" : ""
                          color: row.ink
                          opacity: row.modelData.focused ? 1 : 0.45
                          font.family: root.font
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }
                  }
                }

                Text {
                  visible: !column.info.tiles.some(function(t) { return M.matches(t, column.info, root.query) })
                  leftPadding: Style.space(8)
                  textFormat: Text.PlainText
                  text: root.query ? "No match" : "No visible workspaces"
                  color: root.foreground
                  opacity: 0.45
                  font.family: root.font
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }
        }
      }
    }
  }
}
