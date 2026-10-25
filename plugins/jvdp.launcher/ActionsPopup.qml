import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The actions of the selected result (Tab or Ctrl+K), with their shortcuts.
BorderSurface {
  id: popup

  property var launcher: null
  readonly property int rowH: Math.max(Style.space(32), Style.font.body + Style.spacing.controlPaddingY * 2)

  width: Math.min(parent.width, Style.space(340))
  height: Math.min(parent.height, list.contentHeight + padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec))
  radius: launcher.cornerRadius
  color: Commons.Color.popups.background
  borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.normalBorderWidth))
  padding: Style.spacing.sm
  z: 50

  ListView {
    id: list
    anchors.fill: parent
    anchors.topMargin: popup.contentTopInset
    anchors.bottomMargin: popup.contentBottomInset
    anchors.leftMargin: popup.contentLeftInset
    anchors.rightMargin: popup.contentRightInset
    model: popup.launcher ? popup.launcher.actions : []
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    currentIndex: popup.launcher ? popup.launcher.actionIndex : 0
    onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

    delegate: Rectangle {
      required property var modelData
      required property int index
      readonly property bool current: popup.launcher && index === popup.launcher.actionIndex
      width: ListView.view.width
      height: popup.rowH
      radius: popup.launcher.cornerRadius
      color: current ? popup.launcher.selectedBackground : "transparent"

      Text {
        id: glyph
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(22)
        text: modelData.icon || ""
        color: current ? popup.launcher.selectedText : popup.launcher.foreground
        font.family: popup.launcher.fontFamily
        font.pixelSize: Style.font.icon
      }

      Text {
        textFormat: Text.PlainText
        anchors.left: glyph.right
        anchors.right: keyText.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: modelData.title || ""
        color: current ? popup.launcher.selectedText : popup.launcher.foreground
        font.family: popup.launcher.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        id: keyText
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: index === 0 ? "↵" : prettyKeys(modelData.shortcut || "")
        color: popup.launcher.foreground
        opacity: 0.5
        font.family: popup.launcher.fontFamily
        font.pixelSize: Style.font.caption

        function prettyKeys(sc) {
          if (!sc) return ""
          return sc.split("+").map(function(k) {
            return { ctrl: "Ctrl", shift: "Shift", alt: "Alt", enter: "↵", delete: "Del" }[k] || k.toUpperCase()
          }).join("+")
        }
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: popup.launcher.actionIndex = index
        onClicked: popup.launcher.runAction(modelData)
      }
    }
  }
}
