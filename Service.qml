import QtQuick
import Quickshell
import Quickshell.Io

// Headless: wakes up every hour and asks the backend to look for new theme
// updates. The backend decides: it does nothing, and uses no network, unless the
// user switched the notifications on in Settings, and even then it looks at most
// once a day (it remembers when it last did). Waking hourly rather than daily
// means a restarted shell or a laptop that was asleep still checks on time.
Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string backend: Qt.resolvedUrl("bin/extra-themes").toString().replace("file://", "")

  readonly property int firstCheckMs: 2 * 60 * 1000          // let the session settle after login
  readonly property int intervalMs: 60 * 60 * 1000

  function check() {
    if (!checker.running) checker.running = true
  }

  Process {
    id: checker
    command: [root.backend, "check-updates"]
  }

  Timer { interval: root.firstCheckMs; running: true; onTriggered: root.check() }
  Timer { interval: root.intervalMs; running: true; repeat: true; onTriggered: root.check() }
}
