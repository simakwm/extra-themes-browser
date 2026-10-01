import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string backend: Qt.resolvedUrl("bin/extra-themes").toString().replace("file://", "")

  // ── state ──────────────────────────────────────────────────
  property bool opened: false
  property bool loading: false
  property bool checking: false          // update check (git fetch) in flight
  property string loadError: ""
  property string filterText: ""
  property string tab: "all"             // all | installed | favorites | updates
  readonly property var tabs: ["all", "installed", "favorites", "updates"]
  property string selectedSlug: ""
  property int selectedIndex: 0
  property string confirmSlug: ""        // theme awaiting a second Ctrl+X
  property string message: ""
  property bool messageIsError: false
  property bool keyNavRecent: false      // ignore hover while the grid scrolls under a still mouse
  property var themes: []
  property var outdated: []
  property var busy: ({})                // slug -> verb in progress
  property var filtered: []

  // fullscreen preview
  property int previewIndex: -1          // index into `filtered`, -1 = closed
  readonly property bool previewing: previewIndex >= 0

  // settings view
  property string view: "browse"         // browse | settings
  property var settings: ({ bar: { section: "hidden", index: 0, count: 0 }, menu: false, shortcut: "", suggested: "", notify: false })
  property int settingsRow: 0            // 0 bar icon · 1 menu entry · 2 shortcut · 3 update notifications · 4 remove
  property bool editingShortcut: false
  property bool cleanupPending: false    // waiting for the confirming second Enter
  property string shortcutDraft: ""
  readonly property var barOptions: ["hidden", "left", "center", "right"]

  // ── look ───────────────────────────────────────────────────
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color accent: Color.accent
  property color urgent: Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int gap: Style.spacing.md
  property int cardWidth: Math.min(Style.space(1100), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(740), panel.height - Style.gapsOut * 2)
  property int columns: Math.max(2, Math.min(4, Math.floor(cardWidth / Style.space(340))))

  // ── lifecycle ──────────────────────────────────────────────
  function open(payloadJson) {
    opened = true
    view = "browse"
    cleanupPending = false
    previewIndex = -1
    editingShortcut = false
    filterText = ""
    tab = "all"
    selectedSlug = ""
    selectedIndex = 0
    confirmSlug = ""
    clearMessage()
    loadCatalog(false)
    checkUpdates()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function dismiss() {
    opened = false
    if (shell && typeof shell.hide === "function")
      shell.hide((manifest && manifest.id) || "io.github.simakwm.extra-themes")
  }

  function toggle() {
    if (opened) dismiss()
    else open("{}")
  }

  // ── status line ────────────────────────────────────────────
  function notify(text, isError) {
    message = text
    messageIsError = !!isError
    messageTimer.interval = isError ? 12000 : 5000
    messageTimer.restart()
  }

  function clearMessage() {
    messageTimer.stop()
    message = ""
    messageIsError = false
  }

  Timer { id: messageTimer; onTriggered: root.clearMessage() }

  // ── backend calls ──────────────────────────────────────────
  Component {
    id: procFactory
    Process {
      id: proc
      property var done: null
      stdout: StdioCollector {}
      onExited: {
        var parsed = null
        try { parsed = JSON.parse(stdout.text) } catch (e) {}
        if (done) done(parsed)
        proc.destroy()
      }
    }
  }

  function call(args, done) {
    var p = procFactory.createObject(root, { command: [backend].concat(args), done: done })
    p.running = true
  }

  function loadCatalog(force) {
    loading = true
    call(force ? ["catalog", "--refresh"] : ["catalog"], function(rows) {
      loading = false
      if (Array.isArray(rows)) {
        loadError = ""
        themes = rows
        rebuild()
      } else {
        loadError = (rows && rows.error) || "Could not load the theme list"
      }
    })
  }

  function checkUpdates() {
    checking = true
    call(["status"], function(res) {
      checking = false
      if (res && Array.isArray(res.outdated)) {
        outdated = res.outdated
        rebuild()
      }
    })
  }

  function setBusy(slug, verb) {
    var b = Object.assign({}, busy)
    if (verb) b[slug] = verb
    else delete b[slug]
    busy = b
  }

  // Runs one backend verb; resolves with {ok, error}.
  function run(verb, t, done) {
    var args = {
      install: ["install", t.repo], uninstall: ["uninstall", t.slug],
      update: ["update", t.slug], apply: ["apply", t.slug]
    }[verb]
    call(args, function(res) { done(res && res.ok ? { ok: true, switched: res.switched || "" } : { ok: false, error: (res && res.error) || verb + " failed" }) })
  }

  // Install also applies, update re-applies when the theme is the active one,
  // so the user never has to press Enter twice to see the result.
  function act(verb, t) {
    if (!t || busy[t.slug]) return
    var steps = verb === "install" ? ["install", "apply"]
      : verb === "update" && t.active ? ["update", "apply"]
      : [verb]
    var past = { install: "Installed and applied", update: "Updated", uninstall: "Removed", apply: "Applied" }
    var ing = { install: "Installing", update: "Updating", uninstall: "Removing", apply: "Applying" }
    setBusy(t.slug, ing[verb].toLowerCase())
    notify(ing[verb] + " " + t.name + "…", false)

    var switchedTo = ""
    function next(i) {
      if (i >= steps.length) {
        setBusy(t.slug, "")
        notify(past[verb] + " " + t.name + (switchedTo ? " and switched to " + switchedTo : ""), false)
        if (verb === "update") outdated = outdated.filter(function(s) { return s !== t.slug })
        loadCatalog(false)
        return
      }
      run(steps[i], t, function(r) {
        if (r.ok) { if (r.switched) switchedTo = r.switched; return next(i + 1) }
        setBusy(t.slug, "")
        notify("Could not " + verb + " " + t.name + ": " + r.error, true)
        loadCatalog(false)
      })
    }
    next(0)
  }

  function requestUninstall(t) {
    if (!t || !t.installed) return
    if (!t.git) { notify(t.name + " was not installed from git, so it is not removed from here.", true); return }
    if (confirmSlug === t.slug) { confirmSlug = ""; clearMessage(); act("uninstall", t); return }
    confirmSlug = t.slug
    messageTimer.stop()
    message = "Remove " + t.name + "? Press Ctrl+X again to confirm, any other key cancels."
    messageIsError = true
  }

  function cancelConfirm() {
    if (!confirmSlug) return false
    confirmSlug = ""
    clearMessage()
    return true
  }

  function toggleFavorite(t) {
    if (!t) return
    call(["favorite", t.slug], function(res) {
      if (!(res && res.ok)) return
      themes = themes.map(function(x) { return x.slug === t.slug ? Object.assign({}, x, { favorite: res.favorite }) : x })
      rebuild()
    })
  }

  // Both close the popup so the page or window they open is not hidden behind it.
  function openRepo(t) {
    if (!t || t.repo.indexOf("https://github.com/") !== 0) return
    Quickshell.execDetached(["xdg-open", t.repo])
    dismiss()
  }

  function openThemesFolder() {
    call(["open-folder"], function() {})
    dismiss()
  }

  // ── fullscreen preview ─────────────────────────────────────
  function openPreview(i) {
    if (i < 0 || i >= filtered.length) return
    cancelConfirm()
    previewIndex = i
  }

  // Leaving with `select` puts the cursor on the theme that was being viewed.
  function closePreview(select) {
    var at = previewIndex
    previewIndex = -1
    if (select && at >= 0) selectIndex(at, true)
  }

  function stepPreview(d) {
    previewIndex = Math.max(0, Math.min(filtered.length - 1, previewIndex + d))
  }

  function previewKey(event) {
    if (event.key === Qt.Key_Escape) closePreview(false)
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) closePreview(true)
    else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) stepPreview(-1)
    else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) stepPreview(1)
    else if (event.key === Qt.Key_Home) previewIndex = 0
    else if (event.key === Qt.Key_End) previewIndex = filtered.length - 1
  }

  // ── settings ───────────────────────────────────────────────
  function loadSettings() {
    call(["settings"], function(r) { if (r && r.bar) settings = r })
  }

  function openSettings() {
    cancelConfirm()
    view = "settings"
    settingsRow = 0
    editingShortcut = false
    loadSettings()
  }

  function closeSettings() {
    view = "browse"
    editingShortcut = false
  }

  // Runs a settings command, reports the outcome, then re-reads the real state.
  function change(args, okText, onFail) {
    call(args, function(r) {
      if (r && r.ok) { if (okText) notify(okText, false) }
      else {
        notify((r && r.error) || "Could not change that setting", true)
        if (onFail) onFail()
      }
      loadSettings()
    })
  }

  function setBarSection(section) {
    change(["bar", section], section === "hidden" ? "Icon removed from the bar" : "Icon placed on the " + section + " of the bar")
  }

  function cycleBarSection(d) {
    var i = barOptions.indexOf(settings.bar.section)
    setBarSection(barOptions[(i + d + barOptions.length) % barOptions.length])
  }

  function nudgeIcon(d) {
    if (settings.bar.section !== "hidden") change(["bar-move", String(d)], "")
  }

  function toggleMenuEntry() {
    change(["menu", settings.menu ? "off" : "on"],
      settings.menu ? "Removed from the Omarchy menu" : "Added to the Omarchy menu under Style › Extra Themes")
  }

  function toggleNotify() {
    change(["notify", settings.notify ? "off" : "on"],
      settings.notify ? "Update notifications turned off" : "You will be notified when installed themes have updates")
  }

  function startShortcutEdit() {
    shortcutDraft = settings.shortcut || settings.suggested || ""
    editingShortcut = true
  }

  function saveShortcut() {
    var draft = shortcutDraft
    editingShortcut = false
    change(["shortcut-set", draft], "Shortcut registered", function() { shortcutDraft = draft; editingShortcut = true })
  }

  function requestCleanup() {
    cleanupPending = true
    messageTimer.stop()
    message = "This removes the bar icon, menu entry, shortcut, favorites and cache. Press Enter again to confirm, any other key cancels."
    messageIsError = true
  }

  function runCleanup() {
    cleanupPending = false
    change(["cleanup"], "Bar icon, menu entry, shortcut and data removed. Now run: omarchy plugin remove io.github.simakwm.extra-themes")
  }

  function clearShortcut() {
    if (settings.shortcut) change(["shortcut-clear"], "Shortcut removed")
  }

  function settingsKey(event) {
    var ctrl = event.modifiers & Qt.ControlModifier
    var shift = event.modifiers & Qt.ShiftModifier
    var printable = !ctrl && event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127

    if (editingShortcut) {
      if (event.key === Qt.Key_Escape) editingShortcut = false
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) saveShortcut()
      else if (event.key === Qt.Key_Backspace) shortcutDraft = ctrl ? shortcutDraft.replace(/\s*\S+\s*$/, "") : shortcutDraft.slice(0, -1)
      else if (printable) shortcutDraft += event.text
      return
    }

    if (cleanupPending) {
      if (settingsRow === 4 && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { runCleanup(); return }
      cleanupPending = false
      clearMessage()
      if (event.key === Qt.Key_Escape) return
    }

    if (event.key === Qt.Key_Escape || (ctrl && event.key === Qt.Key_Comma)) closeSettings()
    else if (event.key === Qt.Key_Up) settingsRow = Math.max(0, settingsRow - 1)
    else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) settingsRow = Math.min(4, settingsRow + 1)
    else if (settingsRow === 3 && (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space)) toggleNotify()
    else if (settingsRow === 4 && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) requestCleanup()
    else if (event.key === Qt.Key_Backtab) settingsRow = Math.max(0, settingsRow - 1)
    else if (settingsRow === 0 && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
      var d = event.key === Qt.Key_Left ? -1 : 1
      if (shift) nudgeIcon(d)
      else cycleBarSection(d)
    }
    else if (settingsRow === 1 && (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space)) toggleMenuEntry()
    else if (settingsRow === 2 && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) startShortcutEdit()
    else if (settingsRow === 2 && (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace)) clearShortcut()
  }

  // ── filtering & selection ──────────────────────────────────
  function isOutdated(t) { return outdated.indexOf(t.slug) >= 0 }

  function rebuild() {
    var q = filterText.toLowerCase()
    var out = themes.filter(function(t) {
      if (tab === "installed" && !t.installed) return false
      if (tab === "favorites" && !t.favorite) return false
      if (tab === "updates" && !isOutdated(t)) return false
      return !q || t.name.toLowerCase().indexOf(q) >= 0 || t.slug.indexOf(q) >= 0 || t.author.toLowerCase().indexOf(q) >= 0
    })
    // Favorites first, then installed, then catalog order.
    out = out.map(function(t, i) { return { t: t, i: i } }).sort(function(a, b) {
      return (b.t.favorite - a.t.favorite) || (b.t.installed - a.t.installed) || (a.i - b.i)
    }).map(function(x) { return x.t })
    filtered = out

    // The selection follows the theme, not the row, so reordering never
    // moves the cursor onto a different theme.
    var at = out.findIndex(function(t) { return t.slug === selectedSlug })
    selectedIndex = at >= 0 ? at : 0
    selectedSlug = out.length ? out[selectedIndex].slug : ""
  }

  function setFilter(s) { filterText = s; selectedSlug = ""; rebuild(); grid.positionViewAtBeginning() }
  function setTab(name) { tab = name; selectedSlug = ""; rebuild(); grid.positionViewAtBeginning() }
  function cycleTab(d) { setTab(tabs[(tabs.indexOf(tab) + d + tabs.length) % tabs.length]) }
  function current() { return filtered[selectedIndex] || null }

  function selectIndex(i, viaKeyboard) {
    if (filtered.length === 0) return
    selectedIndex = Math.max(0, Math.min(filtered.length - 1, i))
    selectedSlug = filtered[selectedIndex].slug
    if (confirmSlug && confirmSlug !== selectedSlug) cancelConfirm()
    if (viaKeyboard) {
      keyNavRecent = true
      navTimer.restart()
      grid.positionViewAtIndex(selectedIndex, GridView.Contain)
    }
  }

  Timer { id: navTimer; interval: 250; onTriggered: root.keyNavRecent = false }

  function primary(t) {
    if (!t) return
    if (!t.installed) act("install", t)
    else if (!t.active) act("apply", t)
  }

  function tabLabel(name) {
    var n = name === "all" ? themes.length
      : name === "installed" ? themes.filter(function(t) { return t.installed }).length
      : name === "favorites" ? themes.filter(function(t) { return t.favorite }).length
      : themes.filter(isOutdated).length
    var label = name.charAt(0).toUpperCase() + name.slice(1)
    return label + " " + (name === "updates" && checking ? "…" : n)
  }

  readonly property var hints: view === "settings"
    ? (editingShortcut
        ? [["⏎", "save"], ["Esc", "cancel"]]
        : [["↑↓", "select"], ["←→", "change"], ["⇧←→", "move icon"], ["⏎", "edit / toggle / confirm"], ["Del", "remove shortcut"], ["Esc", "back"]])
    : [["⏎", "install / apply"], ["^F", "favorite"], ["^D", "update"], ["^X", "remove"],
       ["^P", "preview"], ["^O", "GitHub"], ["^T", "themes folder"], ["^,", "settings"], ["Tab", "filter"], ["^R", "refresh"], ["Esc", "close"]]

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "extra-themes-browser"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          var ctrl = event.modifiers & Qt.ControlModifier
          var t = root.current()
          var rows = Math.max(1, Math.floor(grid.height / grid.cellHeight))
          event.accepted = true

          if (root.previewing) { root.previewKey(event); return }
          if (root.view === "settings") { root.settingsKey(event); return }

          // A pending uninstall survives only the confirming Ctrl+X.
          if (root.confirmSlug && !(ctrl && event.key === Qt.Key_X)) {
            root.cancelConfirm()
            if (event.key === Qt.Key_Escape) return
          }

          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
          } else if (Util.editsFilter(event, root.filterText)) root.setFilter(Util.editedFilter(event, root.filterText))
          else if (ctrl && event.key === Qt.Key_F) root.toggleFavorite(t)
          else if (ctrl && event.key === Qt.Key_D) { if (t && t.git) root.act("update", t) }
          else if (ctrl && event.key === Qt.Key_X) root.requestUninstall(t)
          else if (ctrl && event.key === Qt.Key_O) root.openRepo(t)
          else if (ctrl && event.key === Qt.Key_Comma) root.openSettings()
          else if (ctrl && event.key === Qt.Key_T) root.openThemesFolder()
          else if (ctrl && event.key === Qt.Key_P) root.openPreview(root.selectedIndex)
          else if (ctrl && event.key === Qt.Key_R) { root.loadCatalog(true); root.checkUpdates() }
          else if (event.key === Qt.Key_Tab) root.cycleTab(1)
          else if (event.key === Qt.Key_Backtab) root.cycleTab(-1)
          else if (event.key === Qt.Key_Left) root.selectIndex(root.selectedIndex - 1, true)
          else if (event.key === Qt.Key_Right) root.selectIndex(root.selectedIndex + 1, true)
          else if (event.key === Qt.Key_Up) root.selectIndex(root.selectedIndex - root.columns, true)
          else if (event.key === Qt.Key_Down) root.selectIndex(root.selectedIndex + root.columns, true)
          else if (event.key === Qt.Key_PageUp) root.selectIndex(root.selectedIndex - root.columns * rows, true)
          else if (event.key === Qt.Key_PageDown) root.selectIndex(root.selectedIndex + root.columns * rows, true)
          else if (event.key === Qt.Key_Home) root.selectIndex(0, true)
          else if (event.key === Qt.Key_End) root.selectIndex(root.filtered.length - 1, true)
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.primary(t)
          else if (!ctrl && event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127)
            root.setFilter(root.filterText + event.text)
          else event.accepted = false
        }
      }

      Item {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        // ── search box ──
        Rectangle {
          id: searchBox
          visible: root.view === "browse"
          anchors { top: parent.top; left: parent.left; right: parent.right }
          height: Style.space(40)
          radius: root.cornerRadius
          color: "transparent"
          border.width: 1
          border.color: root.accent

          Text {
            id: searchIcon
            anchors { left: parent.left; leftMargin: Style.space(12); verticalCenter: parent.verticalCenter }
            text: "󰍉"
            color: root.foreground
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          Row {
            anchors { left: searchIcon.right; leftMargin: Style.space(10); right: searchMeta.left; rightMargin: Style.space(10); verticalCenter: parent.verticalCenter }
            clip: true
            Text {
              textFormat: Text.PlainText
              text: root.filterText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
            }
            Rectangle {
              width: Style.space(2)
              height: Style.font.heading
              color: root.accent
              anchors.verticalCenter: parent.verticalCenter
              SequentialAnimation on opacity {
                loops: Animation.Infinite
                running: root.opened
                NumberAnimation { to: 0; duration: 500 }
                NumberAnimation { to: 1; duration: 500 }
              }
            }
            Text {
              visible: !root.filterText
              leftPadding: Style.space(6)
              text: "Search by name or author…"
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
            }
          }

          Row {
            id: searchMeta
            anchors { right: parent.right; rightMargin: Style.space(12); verticalCenter: parent.verticalCenter }
            spacing: Style.space(10)
            Text {
              text: root.filtered.length + " / " + root.themes.length
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              visible: root.filterText !== ""
              text: "✕"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              anchors.verticalCenter: parent.verticalCenter
              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setFilter("")
              }
            }
          }
        }

        // ── tabs ──
        Row {
          id: tabRow
          visible: root.view === "browse"
          anchors { top: searchBox.bottom; topMargin: root.gap; left: parent.left }
          spacing: root.gap
          Repeater {
            model: root.tabs
            Rectangle {
              required property string modelData
              readonly property bool active: root.tab === modelData
              width: tabText.implicitWidth + Style.space(24)
              height: Style.space(28)
              radius: root.cornerRadius
              color: active ? root.selectedBackground : "transparent"
              Text {
                id: tabText
                anchors.centerIn: parent
                text: root.tabLabel(parent.modelData)
                color: parent.active ? root.selectedText : root.foreground
                opacity: parent.active ? 1 : 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.setTab(parent.modelData) }
            }
          }
        }


        // ── settings ──
        Column {
          visible: root.view === "settings"
          anchors { top: parent.top; left: parent.left; right: parent.right }
          spacing: root.gap

          Row {
            spacing: Style.space(12)
            Text {
              text: "Settings"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }
            Text {
              anchors.baseline: parent.children[0].baseline
              text: "Esc to go back"
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          // 0 — bar icon
          Rectangle {
            width: parent.width
            height: barCol.implicitHeight + Style.space(24)
            radius: root.cornerRadius
            color: root.settingsRow === 0 ? root.selectedBackground : "transparent"
            border.width: 1
            border.color: root.settingsRow === 0 ? root.accent : root.border
            MouseArea { anchors.fill: parent; onClicked: root.settingsRow = 0 }
            Column {
              id: barCol
              anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(12) }
              spacing: Style.space(8)
              Text { text: "Top bar icon"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true }
              Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: "Choose where the Extra Themes icon sits on the top bar, or hide it. Clicking it opens this popup."
                color: root.foreground; opacity: 0.65; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
              }
              Flow {
                width: parent.width
                spacing: Style.space(6)
                Repeater {
                  model: root.barOptions
                  ActionButton {
                    required property string modelData
                    readonly property bool on: root.settings.bar.section === modelData
                    label: modelData.charAt(0).toUpperCase() + modelData.slice(1)
                    ink: on ? root.background : root.foreground
                    fill: on ? root.accent : "transparent"
                    outline: on ? root.accent : root.border
                    family: root.fontFamily
                    onClicked: { root.settingsRow = 0; root.setBarSection(modelData) }
                  }
                }
                ActionButton {
                  visible: root.settings.bar.section !== "hidden"
                  label: "◀ Earlier  ⇧←"; ink: root.foreground; outline: root.border; family: root.fontFamily
                  onClicked: { root.settingsRow = 0; root.nudgeIcon(-1) }
                }
                ActionButton {
                  visible: root.settings.bar.section !== "hidden"
                  label: "Later ▶  ⇧→"; ink: root.foreground; outline: root.border; family: root.fontFamily
                  onClicked: { root.settingsRow = 0; root.nudgeIcon(1) }
                }
              }
            }
          }

          // 1 — menu entry
          Rectangle {
            width: parent.width
            height: menuCol.implicitHeight + Style.space(24)
            radius: root.cornerRadius
            color: root.settingsRow === 1 ? root.selectedBackground : "transparent"
            border.width: 1
            border.color: root.settingsRow === 1 ? root.accent : root.border
            MouseArea { anchors.fill: parent; onClicked: root.settingsRow = 1 }
            Column {
              id: menuCol
              anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(12) }
              spacing: Style.space(8)
              Text { text: "Omarchy menu entry"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true }
              Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: "Adds “Extra Themes” under Style in the Omarchy menu (written to extensions/omarchy-menu.jsonc)."
                color: root.foreground; opacity: 0.65; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
              }
              ActionButton {
                label: root.settings.menu ? "✔ In the menu  ⏎ remove" : "Not in the menu  ⏎ add"
                ink: root.settings.menu ? root.background : root.foreground
                fill: root.settings.menu ? root.accent : "transparent"
                outline: root.settings.menu ? root.accent : root.border
                family: root.fontFamily
                onClicked: { root.settingsRow = 1; root.toggleMenuEntry() }
              }
            }
          }

          // 2 — shortcut
          Rectangle {
            width: parent.width
            height: keyCol.implicitHeight + Style.space(24)
            radius: root.cornerRadius
            color: root.settingsRow === 2 ? root.selectedBackground : "transparent"
            border.width: 1
            border.color: root.settingsRow === 2 ? root.accent : root.border
            MouseArea { anchors.fill: parent; onClicked: root.settingsRow = 2 }
            Column {
              id: keyCol
              anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(12) }
              spacing: Style.space(8)
              Text { text: "Keyboard shortcut"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true }
              Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: "Opens or closes this popup from anywhere (written to hypr/bindings.lua). Type it like SUPER + CTRL + T; shortcuts already in use are refused."
                color: root.foreground; opacity: 0.65; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
              }
              Rectangle {
                width: parent.width
                height: Style.space(36)
                radius: root.cornerRadius
                color: "transparent"
                border.width: 1
                border.color: root.editingShortcut ? root.accent : root.border
                Row {
                  anchors { left: parent.left; leftMargin: Style.space(12); verticalCenter: parent.verticalCenter }
                  Text {
                    textFormat: Text.PlainText
                    text: root.editingShortcut ? root.shortcutDraft : (root.settings.shortcut || "Not set")
                    color: root.foreground
                    opacity: root.editingShortcut || root.settings.shortcut ? 1 : 0.55
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                  }
                  Rectangle {
                    visible: root.editingShortcut
                    width: Style.space(2); height: Style.font.heading
                    color: root.accent
                    anchors.verticalCenter: parent.verticalCenter
                    SequentialAnimation on opacity {
                      loops: Animation.Infinite
                      running: root.editingShortcut
                      NumberAnimation { to: 0; duration: 500 }
                      NumberAnimation { to: 1; duration: 500 }
                    }
                  }
                }
              }
              Row {
                spacing: Style.space(6)
                ActionButton {
                  visible: !root.editingShortcut
                  label: root.settings.shortcut ? "⏎ Change" : "⏎ Set shortcut"
                  ink: root.background; fill: root.accent; outline: root.accent; family: root.fontFamily
                  onClicked: { root.settingsRow = 2; root.startShortcutEdit() }
                }
                ActionButton {
                  visible: !root.editingShortcut && root.settings.shortcut !== ""
                  label: "Del Remove"; ink: root.urgent; outline: root.urgent; family: root.fontFamily
                  onClicked: { root.settingsRow = 2; root.clearShortcut() }
                }
                ActionButton {
                  visible: root.editingShortcut
                  label: "⏎ Save"; ink: root.background; fill: root.accent; outline: root.accent; family: root.fontFamily
                  onClicked: root.saveShortcut()
                }
                ActionButton {
                  visible: root.editingShortcut
                  label: "Esc Cancel"; ink: root.foreground; outline: root.border; family: root.fontFamily
                  onClicked: root.editingShortcut = false
                }
              }
            }
          }
          // 3 — update notifications
          Rectangle {
            width: parent.width
            height: notifyCol.implicitHeight + Style.space(24)
            radius: root.cornerRadius
            color: root.settingsRow === 3 ? root.selectedBackground : "transparent"
            border.width: 1
            border.color: root.settingsRow === 3 ? root.accent : root.border
            MouseArea { anchors.fill: parent; onClicked: root.settingsRow = 3 }
            Column {
              id: notifyCol
              anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(12) }
              spacing: Style.space(8)
              Text { text: "Update notifications"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true }
              Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: "Get a desktop notification when an installed theme has new updates. Checked in the background once a day, and announced once per update; clicking the notification opens this popup."
                color: root.foreground; opacity: 0.65; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
              }
              ActionButton {
                label: root.settings.notify ? "✔ Notifications on  ⏎ turn off" : "Notifications off  ⏎ turn on"
                ink: root.settings.notify ? root.background : root.foreground
                fill: root.settings.notify ? root.accent : "transparent"
                outline: root.settings.notify ? root.accent : root.border
                family: root.fontFamily
                onClicked: { root.settingsRow = 3; root.toggleNotify() }
              }
            }
          }

          // 4 — clean up before removing the plugin
          Rectangle {
            width: parent.width
            height: cleanCol.implicitHeight + Style.space(24)
            radius: root.cornerRadius
            color: root.settingsRow === 4 ? root.selectedBackground : "transparent"
            border.width: 1
            border.color: root.settingsRow === 4 ? root.urgent : root.border
            MouseArea { anchors.fill: parent; onClicked: root.settingsRow = 4 }
            Column {
              id: cleanCol
              anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(12) }
              spacing: Style.space(8)
              Text { text: "Remove integrations"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true }
              Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: "Before uninstalling the plugin, remove everything it added elsewhere: bar icon, menu entry, shortcut, favorites and cache. Installed themes are not touched."
                color: root.foreground; opacity: 0.65; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
              }
              ActionButton {
                label: root.cleanupPending ? "⏎ Confirm removal" : "⏎ Remove integrations"
                ink: root.cleanupPending ? root.background : root.urgent
                fill: root.cleanupPending ? root.urgent : "transparent"
                outline: root.urgent; family: root.fontFamily
                onClicked: { root.settingsRow = 4; if (root.cleanupPending) root.runCleanup(); else root.requestCleanup() }
              }
            }
          }
        }

        // ── footer: status line + key hints ──
        Column {
          id: footer
          anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
          spacing: Style.space(4)

          Text {
            width: parent.width
            visible: root.message !== ""
            textFormat: Text.PlainText
            text: root.message
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            color: root.messageIsError ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: root.messageIsError
          }

          Flow {
            width: parent.width
            spacing: Style.space(16)
            Repeater {
              model: root.hints
              Row {
                required property var modelData
                spacing: Style.space(5)
                Text {
                  text: parent.modelData[0]
                  color: root.selectedText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
                Text {
                  text: parent.modelData[1]
                  color: root.foreground
                  opacity: 0.75
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }
        }

        ActionButton {
          visible: root.view === "browse"
          anchors { right: settingsButton.left; rightMargin: root.gap; verticalCenter: tabRow.verticalCenter }
          label: "󰉋 Themes folder"; flat: true; ink: root.foreground; outline: root.border; family: root.fontFamily
          onClicked: root.openThemesFolder()
        }

        ActionButton {
          id: settingsButton
          visible: root.view === "browse"
          anchors { right: parent.right; verticalCenter: tabRow.verticalCenter }
          label: "⚙ Settings"; flat: true; ink: root.foreground; outline: root.border; family: root.fontFamily
          onClicked: root.openSettings()
        }

        // ── grid ──
        Item {
          visible: root.view === "browse"
          anchors { top: tabRow.bottom; topMargin: root.gap; bottom: footer.top; bottomMargin: root.gap; left: parent.left; right: parent.right }

          GridView {
            id: grid
            anchors.fill: parent
            anchors.rightMargin: Style.space(8)
            model: root.filtered.length
            clip: true
            cellWidth: Math.floor(width / root.columns)
            cellHeight: Math.round((cellWidth - Style.space(20)) * 9 / 16) + Style.space(112)
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
              id: cell
              required property int index
              readonly property var t: root.filtered[index]
              readonly property bool selected: index === root.selectedIndex
              readonly property string verb: (t && root.busy[t.slug]) || ""
              readonly property bool confirming: t && root.confirmSlug === t.slug
              width: grid.cellWidth
              height: grid.cellHeight

              Rectangle {
                anchors.fill: parent
                anchors.margins: Style.space(4)
                radius: root.cornerRadius
                color: cell.selected ? root.selectedBackground : "transparent"
                border.width: cell.selected ? 1 : 0
                border.color: root.accent

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  onPositionChanged: if (!root.keyNavRecent) root.selectIndex(cell.index, false)
                  onClicked: root.selectIndex(cell.index, false)
                  onDoubleClicked: root.primary(cell.t)
                }

                Column {
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  spacing: Style.space(6)

                  // preview
                  Item {
                    width: parent.width
                    height: width * 9 / 16
                    Rectangle { anchors.fill: parent; radius: root.cornerRadius; color: root.border; opacity: 0.2 }
                    Image {
                      id: preview
                      anchors.fill: parent
                      source: cell.t ? cell.t.image : ""
                      asynchronous: true
                      fillMode: Image.PreserveAspectCrop
                      opacity: cell.verb ? 0.35 : 1
                    }
                    Text {
                      anchors.centerIn: parent
                      visible: preview.status !== Image.Ready && !cell.verb
                      text: preview.status === Image.Error ? "no preview" : "…"
                      color: root.foreground
                      opacity: 0.5
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                    Row {
                      anchors { top: parent.top; left: parent.left; margins: Style.space(6) }
                      spacing: Style.space(4)
                      Badge { visible: cell.t && cell.t.active; label: "ACTIVE"; fill: root.accent; ink: root.background; family: root.fontFamily }
                      Badge { visible: cell.t && cell.t.installed && !cell.t.active; label: "INSTALLED"; fill: root.foreground; ink: root.background; family: root.fontFamily }
                    }
                    Badge {
                      visible: cell.t && root.isOutdated(cell.t)
                      anchors { top: parent.top; right: parent.right; margins: Style.space(6) }
                      label: "UPDATE"; fill: root.urgent; ink: root.background; family: root.fontFamily
                    }
                    Rectangle {
                      visible: !cell.verb
                      anchors { bottom: parent.bottom; right: parent.right; margins: Style.space(6) }
                      width: Style.space(26); height: width; radius: width / 2
                      color: Qt.rgba(0, 0, 0, expandMouse.containsMouse ? 0.85 : 0.55)
                      Text {
                        anchors.centerIn: parent
                        text: "⤢"
                        color: "white"
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.title
                      }
                      MouseArea {
                        id: expandMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openPreview(cell.index)
                      }
                    }
                    Column {
                      visible: cell.verb !== ""
                      anchors.centerIn: parent
                      spacing: Style.space(4)
                      Spinner {
                        anchors.horizontalCenter: parent.horizontalCenter
                        size: Style.space(30)
                        tint: root.accent
                        spinning: cell.verb !== ""
                      }
                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: cell.verb + "…"
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }
                    }
                  }

                  // title row
                  Item {
                    width: parent.width
                    height: Style.space(34)
                    Column {
                      anchors { left: parent.left; right: star.left; rightMargin: Style.space(6); verticalCenter: parent.verticalCenter }
                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: cell.t ? cell.t.name : ""
                        color: cell.selected ? root.selectedText : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                      }
                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: cell.t ? "by " + cell.t.author : ""
                        color: root.foreground
                        opacity: 0.6
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                      }
                    }
                    Text {
                      id: star
                      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                      text: cell.t && cell.t.favorite ? "★" : "☆"
                      color: cell.t && cell.t.favorite ? root.accent : root.foreground
                      opacity: cell.t && cell.t.favorite ? 1 : 0.6
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.heading
                      MouseArea {
                        anchors.fill: parent
                        anchors.margins: -Style.space(8)
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleFavorite(cell.t)
                      }
                    }
                  }

                  // actions for the selected card
                  Flow {
                    width: parent.width
                    spacing: Style.space(6)
                    visible: cell.selected && !cell.verb
                    ActionButton {
                      visible: cell.t && !cell.t.installed
                      label: "⏎ Install & apply"; ink: root.background; fill: root.accent; outline: root.accent; family: root.fontFamily
                      onClicked: root.act("install", cell.t)
                    }
                    ActionButton {
                      visible: cell.t && cell.t.installed && !cell.t.active
                      label: "⏎ Apply"; ink: root.background; fill: root.accent; outline: root.accent; family: root.fontFamily
                      onClicked: root.act("apply", cell.t)
                    }
                    ActionButton {
                      visible: cell.t && cell.t.git
                      label: "^D Update"; ink: root.foreground; outline: root.border; family: root.fontFamily
                      onClicked: root.act("update", cell.t)
                    }
                    ActionButton {
                      visible: cell.t && cell.t.git
                      label: cell.confirming ? "^X Confirm remove" : "^X Remove"
                      ink: cell.confirming ? root.background : root.urgent
                      fill: cell.confirming ? root.urgent : "transparent"
                      outline: root.urgent; family: root.fontFamily
                      onClicked: root.requestUninstall(cell.t)
                    }
                    ActionButton {
                      label: "^O GitHub"; ink: root.foreground; outline: root.border; family: root.fontFamily
                      onClicked: root.openRepo(cell.t)
                    }
                  }
                }
              }
            }
          }

          // scroll indicator
          Rectangle {
            visible: grid.contentHeight > grid.height
            anchors.right: parent.right
            width: Style.space(3)
            radius: width / 2
            color: root.foreground
            opacity: 0.35
            y: grid.visibleArea.yPosition * parent.height
            height: Math.max(Style.space(24), grid.visibleArea.heightRatio * parent.height)
          }

          // empty / loading / error states
          Column {
            anchors.centerIn: parent
            width: parent.width * 0.7
            spacing: Style.space(6)
            visible: root.filtered.length === 0
            Spinner {
              visible: root.loading || (root.tab === "updates" && root.checking)
              anchors.horizontalCenter: parent.horizontalCenter
              size: Style.space(30)
              tint: root.accent
            }
            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              text: root.loading ? "Loading themes…"
                : root.loadError ? "Could not load the theme list"
                : root.tab === "updates" && root.checking ? "Checking for updates…"
                : root.tab === "favorites" && !root.filterText ? "No favorites yet — press Ctrl+F on a theme"
                : root.tab === "installed" && !root.filterText ? "Nothing installed yet"
                : root.tab === "updates" && !root.filterText ? "Everything is up to date"
                : "No themes match “" + root.filterText + "”"
              color: root.loadError ? root.urgent : root.foreground
              opacity: 0.85
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }
            Text {
              width: parent.width
              visible: root.loadError !== ""
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              text: root.loadError + "\nCheck your connection and press Ctrl+R to retry."
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }
    }
    // ── fullscreen preview ──
    Item {
      id: previewLayer
      visible: root.previewing
      anchors.fill: parent
      readonly property var t: root.previewing ? root.filtered[root.previewIndex] : null
      readonly property var prevT: root.previewing ? root.filtered[root.previewIndex - 1] : null
      readonly property var nextT: root.previewing ? root.filtered[root.previewIndex + 1] : null

      Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.94) }
      MouseArea { anchors.fill: parent; onClicked: root.closePreview(true) }

      // keep the neighbours warm so stepping with the arrows is instant
      Image { visible: false; asynchronous: true; source: previewLayer.prevT ? previewLayer.prevT.image : "" }
      Image { visible: false; asynchronous: true; source: previewLayer.nextT ? previewLayer.nextT.image : "" }

      Image {
        id: bigImage
        anchors { top: parent.top; left: parent.left; right: parent.right; bottom: caption.top; margins: Style.space(72) }
        anchors.bottomMargin: Style.space(16)
        source: previewLayer.t ? previewLayer.t.image : ""
        asynchronous: true
        fillMode: Image.PreserveAspectFit
        smooth: true
      }

      Spinner {
        visible: bigImage.status === Image.Loading
        anchors.centerIn: bigImage
        size: Style.space(40)
        tint: root.accent
      }
      Text {
        visible: bigImage.status === Image.Error
        anchors.centerIn: bigImage
        text: "no preview available"
        color: "white"; opacity: 0.6
        font.family: root.fontFamily; font.pixelSize: Style.font.title
      }

      Column {
        id: caption
        anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: Style.space(28) }
        spacing: Style.space(6)
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(10)
          Text {
            textFormat: Text.PlainText
            text: previewLayer.t ? previewLayer.t.name : ""
            color: "white"
            font.family: root.fontFamily; font.pixelSize: Style.font.heading; font.bold: true
          }
          Badge { visible: previewLayer.t && previewLayer.t.active; anchors.verticalCenter: parent.verticalCenter; label: "ACTIVE"; fill: root.accent; ink: root.background; family: root.fontFamily }
          Badge { visible: previewLayer.t && previewLayer.t.installed && !previewLayer.t.active; anchors.verticalCenter: parent.verticalCenter; label: "INSTALLED"; fill: "white"; ink: "black"; family: root.fontFamily }
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          text: previewLayer.t ? "by " + previewLayer.t.author + "   ·   " + (root.previewIndex + 1) + " / " + root.filtered.length : ""
          color: "white"; opacity: 0.65
          font.family: root.fontFamily; font.pixelSize: Style.font.body
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: "←  →  navigate     ⏎ or click  select     Esc  cancel"
          color: "white"; opacity: 0.5
          font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
        }
      }

      Repeater {
        model: [-1, 1]
        Item {
          required property int modelData
          readonly property bool available: modelData < 0 ? root.previewIndex > 0 : root.previewIndex < root.filtered.length - 1
          visible: available
          width: Style.space(64)
          anchors { top: parent.top; bottom: parent.bottom }
          x: modelData < 0 ? 0 : parent.width - width
          Text {
            anchors.centerIn: parent
            text: parent.modelData < 0 ? "‹" : "›"
            color: "white"
            opacity: arrowMouse.containsMouse ? 1 : 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading * 3
          }
          MouseArea {
            id: arrowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.stepPreview(parent.modelData)
          }
        }
      }
    }
  }
}
