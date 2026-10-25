import QtQuick
import qs.Commons
import qs.Commons as Commons

// A page of text: Claude's answer, a manual section, a script's output, the
// agenda. Markdown arrives sanitized by the backend (no images, no HTML).
Item {
  id: view

  property var launcher: null
  readonly property var detail: launcher ? launcher.detail : null

  function scrollTop() { flick.contentY = 0 }
  function scrollBy(dy) {
    flick.contentY = Math.max(0, Math.min(Math.max(0, flick.contentHeight - flick.height), flick.contentY + dy))
  }

  Flickable {
    id: flick
    anchors.fill: parent
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    contentWidth: width
    contentHeight: body.implicitHeight + Style.space(12)
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    TextEdit {
      id: body
      width: flick.width
      readOnly: true
      selectByMouse: true
      wrapMode: TextEdit.Wrap
      textFormat: view.detail && view.detail.format === "markdown" ? TextEdit.MarkdownText : TextEdit.PlainText
      text: view.detail ? (view.detail.text || (view.detail.done ? "" : "…")) : ""
      color: view.launcher.foreground
      selectionColor: Util.alpha(view.launcher.accent, 0.35)
      selectedTextColor: view.launcher.foreground
      font.family: view.detail && view.detail.format === "markdown" ? Style.font.family : view.launcher.fontFamily
      font.pixelSize: Style.font.subtitle
      // Links are shown, never followed: the text comes from outside.
      onLinkActivated: function(link) {}
    }
  }

  // Follow a streaming answer as it grows, unless scrolled up to read.
  property bool atBottom: true
  Connections {
    target: flick
    function onContentYChanged() {
      view.atBottom = flick.contentY >= flick.contentHeight - flick.height - Style.space(30)
    }
  }
  Connections {
    target: body
    function onImplicitHeightChanged() {
      if (view.detail && !view.detail.done && view.atBottom && flick.contentHeight > flick.height)
        flick.contentY = flick.contentHeight - flick.height
    }
  }

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Style.space(24)
    visible: flick.contentHeight > flick.height && flick.contentY < flick.contentHeight - flick.height - 2
    gradient: Gradient {
      GradientStop { position: 0; color: Util.alpha(view.launcher.background, 0) }
      GradientStop { position: 1; color: view.launcher.background }
    }
  }
}
