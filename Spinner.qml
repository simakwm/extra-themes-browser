import QtQuick

// Thin rotating arc over a faint track; scales with `size`.
Canvas {
  id: spinner
  property real size: 28
  property color tint: "white"
  property bool spinning: true

  width: size
  height: size
  antialiasing: true

  onTintChanged: requestPaint()
  onSizeChanged: requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    var line = Math.max(2, size / 9)
    var r = (size - line) / 2
    ctx.reset()
    ctx.lineWidth = line
    ctx.lineCap = "round"
    ctx.strokeStyle = Qt.rgba(tint.r, tint.g, tint.b, 0.18)
    ctx.beginPath()
    ctx.arc(size / 2, size / 2, r, 0, Math.PI * 2)
    ctx.stroke()
    ctx.strokeStyle = tint
    ctx.beginPath()
    ctx.arc(size / 2, size / 2, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 1.1)
    ctx.stroke()
  }

  RotationAnimator on rotation {
    from: 0; to: 360
    duration: 800
    loops: Animation.Infinite
    running: spinner.spinning && spinner.visible
  }
}
