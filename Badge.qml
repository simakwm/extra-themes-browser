import QtQuick
import qs.Commons

Rectangle {
  property string label
  property color fill
  property color ink
  property string family

  width: text.implicitWidth + Style.space(12)
  height: Style.space(18)
  radius: height / 2
  color: fill

  Text {
    id: text
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: parent.label
    color: parent.ink
    font.family: parent.family
    font.pixelSize: Style.font.caption
    font.bold: true
  }
}
