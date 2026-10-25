import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// One result: icon (glyph, app icon or image), title, subtitle, accessory.
BorderSurface {
  id: row

  property var launcher: null
  property var entry: ({})
  // Rows can outlive their data for a moment while the list is rebuilt.
  readonly property var e: entry || ({})
  property bool current: false

  signal hoveredRow()
  signal activated()

  readonly property bool hasAppIcon: !!e.appIcon && !e.image
  readonly property bool hasImage: !!e.image
  readonly property color textColor: current ? launcher.selectedText : launcher.foreground

  radius: launcher.cornerRadius
  color: current ? launcher.selectedBackground : "transparent"
  borderSpec: current ? launcher.selectedBorderSpec : Border.none()

  Item {
    id: iconBox
    width: Style.space(36)
    height: parent.height
    anchors.left: parent.left
    anchors.leftMargin: Border.left(launcher.selectedBorderSpec) + Style.space(8)

    Text {
      visible: !row.hasAppIcon && !row.hasImage
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: row.e.icon || "󰘳"
      color: row.textColor
      font.family: launcher.fontFamily
      font.pixelSize: Style.font.iconLarge
      horizontalAlignment: Text.AlignHCenter
    }

    Image {
      visible: row.hasAppIcon
      anchors.centerIn: parent
      width: Style.font.iconLarge * 1.35
      height: width
      fillMode: Image.PreserveAspectFit
      sourceSize.width: width * Screen.devicePixelRatio
      sourceSize.height: height * Screen.devicePixelRatio
      asynchronous: true
      source: row.hasAppIcon && launcher.appLibrary ? launcher.appLibrary.iconSource(row.e.appIcon) : ""
    }

    Image {
      visible: row.hasImage
      anchors.centerIn: parent
      width: Style.space(32)
      height: width
      fillMode: Image.PreserveAspectCrop
      sourceSize.width: width * Screen.devicePixelRatio
      sourceSize.height: height * Screen.devicePixelRatio
      asynchronous: true
      source: row.hasImage ? Util.fileUrl(row.e.image) : ""
    }
  }

  Column {
    anchors.left: iconBox.right
    anchors.leftMargin: Style.space(8)
    anchors.right: trail.left
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: row.e.title || ""
      color: row.textColor
      font.family: launcher.fontFamily
      font.pixelSize: Style.font.heading
      font.weight: Font.Medium
      elide: Text.ElideRight
      maximumLineCount: 1
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: launcher.showSubtitles && !!row.e.subtitle
      text: row.e.subtitle || ""
      color: launcher.foreground
      opacity: 0.5
      font.family: launcher.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideMiddle
      maximumLineCount: 1
    }
  }

  Row {
    id: trail
    anchors.right: parent.right
    anchors.rightMargin: Border.right(launcher.selectedBorderSpec) + Style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(8)

    Text {
      visible: row.e.fav === true
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: "󰓎"
      color: launcher.accent
      opacity: 0.8
      font.family: launcher.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, row.width * 0.32)
      text: row.e.accessory || ""
      color: row.textColor
      opacity: row.current ? 0.8 : 0.42
      font.family: launcher.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    // Only a real move selects: a list scrolling under a still pointer doesn't.
    property point last: Qt.point(-1, -1)
    onPositionChanged: function(mouse) {
      if (last.x >= 0 && (mouse.x !== last.x || mouse.y !== last.y)) row.hoveredRow()
      last = Qt.point(mouse.x, mouse.y)
    }
    onExited: last = Qt.point(-1, -1)
    onClicked: row.activated()
  }
}
