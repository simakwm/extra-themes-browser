import QtQuick
import qs.Commons

// Labelled chip: "⏎ Install". The key hint is part of the label so the
// shortcut is discoverable right where the action is.
Rectangle {
  id: chip
  property string label
  property color ink
  property color fill: "transparent"
  property color outline
  property string family
  property bool flat: false      // no border; hover shows a soft background instead
  signal clicked()

  width: text.implicitWidth + Style.space(16)
  height: Style.space(24)
  radius: Style.cornerRadius
  color: mouse.containsMouse ? (fill === "transparent" ? Color.menu.selectedBackground : Qt.lighter(fill, 1.15)) : fill
  border.width: flat ? 0 : 1
  border.color: outline
  opacity: mouse.containsMouse ? 1 : 0.85

  Text {
    id: text
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: chip.label
    color: chip.ink
    font.family: chip.family
    font.pixelSize: Style.font.bodySmall
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: chip.clicked()
  }
}
