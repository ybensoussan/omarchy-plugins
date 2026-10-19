import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "yonathan.monitor-profile"

  readonly property string profileFile: Quickshell.env("HOME") + "/.config/hypr/workspace-profile.lua"
  property string profile: "Unknown"
  property string profileLabel: "Unknown"

  function readProfile(raw) {
    var match = /workspace-profiles\.([\w-]+)/.exec(raw || "")
    if (!match) {
      profile = "Unknown"
      profileLabel = profile
      return
    }
    profile = match[1].replace(/-/g, " ").replace(/\b\w/g, function(letter) { return letter.toUpperCase() })
    profileLabel = profile === "Factory Office" ? "Office" : profile
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  FileView {
    id: profileFile
    path: root.profileFile
    watchChanges: true
    printErrors: false
    onLoaded: root.readProfile(text())
    onFileChanged: reload()
    onLoadFailed: root.readProfile("")
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍹 " + root.profileLabel
    tooltipText: "Active monitor profile: " + root.profile
    onPressed: function() {
       Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "yonathan.displays", ""])
    }
  }
}
