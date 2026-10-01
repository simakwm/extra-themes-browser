import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.simakwm.extra-themes"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "Extra themes"
    onPressed: function(b) {
      if (b === Qt.LeftButton)
        Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "io.github.simakwm.extra-themes"])
    }

    // A 2×2 swatch of the active theme's own colors, so the icon always matches
    // the theme it opens, and changes when the theme does. The top-right tile
    // is nudged out of the grid as if it were being picked.
    iconComponent: Component {
      Item {
        // Glyph icons paint at roughly 3/4 of the icon canvas; match that so the
        // swatch sits at the same visual size as its neighbours.
        Item {
          id: swatch
          anchors.centerIn: parent
          width: Math.round(parent.width * 0.7)
          height: width
          readonly property real gap: Math.max(1, Math.round(width / 8))
          readonly property real tile: (width - gap) / 2
          readonly property var tiles: [
            { x: 0, y: 0, c: Color.foreground },
            { x: 1, y: 0, c: Color.accent },
            { x: 0, y: 1, c: Color.urgent },
            { x: 1, y: 1, c: Color.muted }
          ]
          Repeater {
            model: swatch.tiles
            Rectangle {
              required property var modelData
              width: swatch.tile
              height: swatch.tile
              radius: Math.max(1, swatch.tile / 4)
              x: modelData.x * (swatch.tile + swatch.gap)
              y: modelData.y * (swatch.tile + swatch.gap) - (modelData.x === 1 && modelData.y === 0 ? swatch.gap : 0)
              color: modelData.c
            }
          }
        }
      }
    }
  }
}
