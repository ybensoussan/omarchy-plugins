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
  property var windows: []
  property var applications: []
  property var matches: []
  property var iconIndex: ({})
  property var pendingIconIndex: ({})
  property int selected: 0

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color border: Color.menu.border
  readonly property color accent: Color.accent

  function pwaInfo(value) {
    var normalized = String(value || "").toLowerCase()
    if (normalized.indexOf("faolnafnngnfdaknnbpnkhgohbobgegn") >= 0 || normalized.indexOf("outlook") >= 0) {
      return { name: "Outlook (PWA)", icon: "chrome-faolnafnngnfdaknnbpnkhgohbobgegn-Default", appId: "faolnafnngnfdaknnbpnkhgohbobgegn" }
    }
    if (normalized.indexOf("ompifgpmddkgmclendfeacglnodjjndh") >= 0 || normalized.indexOf("microsoft teams") >= 0) {
      return { name: "Microsoft Teams (PWA)", icon: "chrome-ompifgpmddkgmclendfeacglnodjjndh-Default", appId: "ompifgpmddkgmclendfeacglnodjjndh" }
    }
    return null
  }

  function localPwaIcon(iconName) {
    var path = "/home/yonathan/.local/share/icons/hicolor/512x512/apps/" + iconName + ".png"
    return Util.fileUrl(path)
  }

  function desktopEntryForClass(appClass) {
    var normalizedClass = String(appClass || "").toLowerCase()
    var entries = DesktopEntries.applications.values || []
    var pwaId = ""
    if (normalizedClass.indexOf("crx_") === 0) {
      pwaId = normalizedClass.slice(4)
    } else if (normalizedClass.indexOf("chrome-") === 0) {
      pwaId = normalizedClass.slice(7).split("-")[0]
    }
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      var id = String(entry.id || "").toLowerCase().replace(/\.desktop$/, "")
      var name = String(entry.name || "").toLowerCase()
      if (id === normalizedClass || name === normalizedClass) return entry
      // Chromium reports installed PWAs as crx_<web-app-id>, while their
      // desktop-entry IDs are chrome-<web-app-id>-<profile>.
      if (pwaId && id.indexOf("chrome-" + pwaId + "-") === 0) return entry
    }
    return null
  }

  function indexIconLine(path) {
    var value = String(path || "").trim()
    if (!value) return
    var file = value.slice(value.lastIndexOf("/") + 1)
    var dot = file.lastIndexOf(".")
    var name = dot > 0 ? file.slice(0, dot) : file
    if (name && pendingIconIndex[name] === undefined) pendingIconIndex[name] = value
  }

  function iconSource(iconName, appClass) {
    var normalizedClass = String(appClass || "").toLowerCase()
    var pwa = pwaInfo(appClass) || pwaInfo(iconName)
    if (pwa) {
      var pwaIcon = localPwaIcon(pwa.icon)
      if (pwaIcon) return pwaIcon
    }
    if (normalizedClass === "org.omarchy.agent") {
      return Quickshell.iconPath("utilities-terminal", true)
    }
    if (normalizedClass === "com.mitchellh.ghostty" || normalizedClass === "ghostty") {
      return Quickshell.iconPath("com.mitchellh.ghostty", true)
    }
    if (normalizedClass === "virt-manager" || normalizedClass === "virtual machine manager") {
      return Quickshell.iconPath("virt-manager", true)
    }
    if (normalizedClass === "storageexplorer") {
      return Quickshell.iconPath("azure-storage-explorer", true)
    }
    var entry = desktopEntryForClass(appClass)
    var resolvedIcon = String(iconName || (entry && entry.icon) || "")
    if (resolvedIcon.indexOf("file://") === 0 || resolvedIcon.indexOf("image://") === 0) return resolvedIcon
    if (resolvedIcon.charAt(0) === "/") return Util.fileUrl(resolvedIcon)
    var indexedIcon = iconIndex[resolvedIcon]
    if (indexedIcon) return Util.fileUrl(indexedIcon)
    var directIcon = Quickshell.iconPath(resolvedIcon, true)
    if (directIcon.length > 0) return directIcon
    var icon = Quickshell.iconPath(appClass, true)
    return icon.length > 0 ? icon : Quickshell.iconPath("application-x-executable", true)
  }

  function appName(appClass) {
    var pwa = pwaInfo(appClass)
    if (pwa) return pwa.name
    var entry = desktopEntryForClass(appClass)
    if (entry) return String(entry.name || appClass)
    var parts = String(appClass || "Unknown").split(".")
    return parts[parts.length - 1]
  }

  function iconIndexScanCommand() {
    return [
      'dirs="$HOME/.icons $HOME/.local/share/icons";',
      'IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS;',
      'for ext in svg png; do',
      '  for base in $dirs; do',
      '    [[ -d $base ]] && find "$base" \\( -path "*/apps/*" -o -path "*/devices/*" \\) -name "*.$ext" 2>/dev/null;',
      '  done;',
      '  find /usr/share/pixmaps -maxdepth 1 -name "*.$ext" 2>/dev/null;',
      'done'
    ].join(' ')
  }

  function refresh() {
    loadWindows.running = true
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
    var query = search.text.trim().toLowerCase()
    var entries = windows.concat(applications)
    matches = entries.filter(function(entry) {
      return !query || (entry.title + " " + entry.appClass + " " + root.appName(entry.appClass) + " " + entry.workspace).toLowerCase().indexOf(query) >= 0
    })
    selected = 0
  }

  function activate(index) {
    var entry = matches[index]
    if (!entry) return
    close()
    if (entry.kind === "window") {
      Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.focus({ window = "address:' + entry.address + '" })'])
    } else if (entry.command) {
      Quickshell.execDetached(entry.command)
    } else {
      var pwa = pwaInfo(entry.appClass + " " + entry.desktopId)
      if (pwa) {
        Quickshell.execDetached(["uwsm-app", "--", "/usr/bin/chromium", "--profile-directory=Default", "--app-id=" + pwa.appId])
      } else {
        Quickshell.execDetached(["uwsm-app", "--", "gtk-launch", entry.desktopId + (entry.desktopId.endsWith(".desktop") ? "" : ".desktop")])
      }
    }
  }

  Process {
    id: iconIndexScan
    command: ["bash", "-c", root.iconIndexScanCommand()]
    stdout: SplitParser { onRead: function(line) { root.indexIconLine(line) } }
    onStarted: root.pendingIconIndex = ({})
    onExited: root.iconIndex = root.pendingIconIndex
  }

  Process {
    id: loadWindows
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.windows = JSON.parse(text)
            .filter(function(client) {
              return client.mapped
                && client.workspace
                && client.workspace.name.indexOf("special:") !== 0
                && client.class !== "org.quickshell"
            })
            .sort(function(a, b) { return a.focusHistoryID - b.focusHistoryID })
            .map(function(client) {
              var rawClass = client.class || "Unknown"
              var title = client.title || "Untitled"
              var normalizedTitle = title.toLowerCase()
              var displayName = ""
              var icon = ""
              if (normalizedTitle.indexOf("outlook") >= 0 || rawClass.indexOf("faolnafnngnfdaknnbpnkhgohbobgegn") >= 0) {
                displayName = "Outlook (PWA)"
                icon = "file:///home/yonathan/.local/share/icons/hicolor/512x512/apps/chrome-faolnafnngnfdaknnbpnkhgohbobgegn-Default.png"
              } else if (normalizedTitle.indexOf("microsoft teams") >= 0 || rawClass.indexOf("ompifgpmddkgmclendfeacglnodjjndh") >= 0) {
                displayName = "Microsoft Teams (PWA)"
                icon = "file:///home/yonathan/.local/share/icons/hicolor/512x512/apps/chrome-ompifgpmddkgmclendfeacglnodjjndh-Default.png"
              }
              return {
                kind: "window",
                address: client.address,
                title: title,
                appClass: rawClass,
                workspace: client.workspace.name,
                icon: icon,
                displayName: displayName
              }
            })
          var activeClasses = root.windows.map(function(window) { return window.appClass.toLowerCase() })
          var applicationsByName = {}
          ;(DesktopEntries.applications.values || [])
            .filter(function(entry) { return entry && entry.id && entry.name })
            .forEach(function(entry) {
              var desktopId = String(entry.id).replace(/\.desktop$/, "")
              var name = String(entry.name)
              var key = name.toLowerCase()
              var candidate = { kind: "application", desktopId: desktopId, title: "Start new instance", appClass: name, workspace: "", icon: String(entry.icon || "") }
              var existing = applicationsByName[key]
              var matchesActiveClass = activeClasses.indexOf(desktopId.toLowerCase()) >= 0
              if (!existing || matchesActiveClass) applicationsByName[key] = candidate
            })
          root.applications = Object.keys(applicationsByName).map(function(key) { return applicationsByName[key] })
          var hasAgent = root.applications.some(function(entry) { return entry.appClass === "Omarchy Agent" })
          if (!hasAgent) {
            root.applications.push({
              kind: "application",
              title: "Start new instance",
              appClass: "Omarchy Agent",
              workspace: "",
              icon: "utilities-terminal",
              command: ["omarchy-agent", "--pick"]
            })
          }
          root.applications.sort(function(a, b) { return a.appClass.localeCompare(b.appClass) })
          root.updateMatches()
          search.forceActiveFocus()
        } catch (error) {
          console.warn("workspace-launcher: could not read windows:", error)
        }
      }
    }
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { if (!iconIndexScan.running) iconIndexScan.running = true }
  }

  IpcHandler {
    target: "yonathan.workspace-launcher"
    function toggle(): void { if (root.opened) root.close(); else root.open() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
  }

  FloatingWindow {
    id: popup
    visible: root.opened
    title: "App Launcher"
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
        id: content
        anchors.fill: parent
        anchors.margins: 24
        spacing: 14

        Text {
          text: "App Launcher"
          color: root.foreground
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        TextField {
          id: search
          width: parent.width
          placeholderText: "Search applications, titles, or workspaces"
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
            readonly property var pwa: root.pwaInfo(String(modelData.appClass || "") + " " + String(modelData.title || ""))
            readonly property color rowBackground: current ? Qt.alpha(root.accent, 0.22) : root.background
            readonly property color rowForeground: root.foreground
            readonly property color rowSecondary: current ? Qt.alpha(root.foreground, 0.82) : Qt.alpha(root.foreground, 0.6)
            width: list.width
            height: 58
            radius: 7
            color: rowBackground
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

            Image {
              id: appIcon
              anchors.left: parent.left
              anchors.leftMargin: 16
              anchors.verticalCenter: parent.verticalCenter
              width: 28
              height: 28
              source: {
                var className = String(modelData.appClass || "").toLowerCase()
                var title = String(modelData.title || "").toLowerCase()
                if (className.indexOf("faolnafnngnfdaknnbpnkhgohbobgegn") >= 0 || title.indexOf("outlook") >= 0)
                  return "file:///home/yonathan/.local/share/icons/hicolor/512x512/apps/chrome-faolnafnngnfdaknnbpnkhgohbobgegn-Default.png"
                if (className.indexOf("ompifgpmddkgmclendfeacglnodjjndh") >= 0 || title.indexOf("microsoft teams") >= 0)
                  return "file:///home/yonathan/.local/share/icons/hicolor/512x512/apps/chrome-ompifgpmddkgmclendfeacglnodjjndh-Default.png"
                return modelData.icon || root.iconSource(modelData.icon, modelData.appClass)
              }
              sourceSize.width: width
              sourceSize.height: height
              fillMode: Image.PreserveAspectFit
            }
            Column {
              anchors.left: appIcon.right
              anchors.right: workspace.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: 12
              spacing: 2
              Text {
                width: parent.width
                text: {
                  var className = String(modelData.appClass || "").toLowerCase()
                  var title = String(modelData.title || "").toLowerCase()
                  if (className.indexOf("faolnafnngnfdaknnbpnkhgohbobgegn") >= 0 || title.indexOf("outlook") >= 0) return "Outlook (PWA)"
                  if (className.indexOf("ompifgpmddkgmclendfeacglnodjjndh") >= 0 || title.indexOf("microsoft teams") >= 0) return "Microsoft Teams (PWA)"
                  return modelData.displayName || root.appName(modelData.appClass)
                }
                color: parent.parent.rowForeground
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }
              Text { width: parent.width; text: modelData.title; color: parent.parent.rowSecondary; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
            }
            Text {
              id: workspace
              anchors.right: parent.right
              anchors.rightMargin: 16
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.kind === "window" ? modelData.workspace : "New"
              color: parent.rowForeground
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
          text: "No open windows match your search"
          color: Qt.alpha(root.foreground, 0.6)
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
        }

        Text {
          text: "Enter to switch  •  Esc to close"
          color: Qt.alpha(root.foreground, 0.5)
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  Component.onCompleted: iconIndexScan.running = true
}
