import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar icon for the idle ladder, and the host for the settings panel.
//
// An hourglass while the timers are armed, Omarchy's own Stay Awake coffee cup
// while they are not — the same glyph the system menu uses for that state, so
// the bar is saying the thing the rest of the desktop already says.
//
// The panel writes; this file only reads. Both read shell.json directly rather
// than through the plugin facade, which hands a third-party plugin the idle
// subtree only when it is a clone of omarchy.idle.
BarWidget {
  id: root
  moduleName: "evansbee.power-timers"

  readonly property string timerIcon: "󰔟"   // nf-md-timer-sand
  readonly property string awakeIcon: "󰅶"   // nf-md-coffee, as the Omarchy menu uses for Stay Awake

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/shell.json"
  readonly property string stayAwakeDir: home + "/.local/state/omarchy/indicators"

  property var timers: Model.defaultTimers()
  property bool stayAwake: false

  readonly property string summaryText: Model.summary(timers)

  // True once a write has changed one of Omarchy's own two timeouts and the
  // shell has not been restarted to pick it up yet.
  property bool restartPending: false

  // ---- Writing. Everything funnels through omarchy-shell-config, Omarchy's
  //      own read-modify-write of shell.json, so this plugin never becomes a
  //      second writer racing the shell for that file.
  function writeTimers(next) {
    if (!bar) return
    if (Model.needsShellRestart(root.timers, next)) root.restartPending = true
    bar.run(Model.writeCommand(next))
  }

  // Omarchy's idle service asks ext-idle-notify for its timeout once, when its
  // monitor is built; changing idle.screensaver or idle.lock afterwards updates
  // the QML property but never reaches the compositor. That is true with or
  // without this plugin — a shell restart is what actually applies a new
  // screensaver or lock timeout.
  //
  // Doing it when the panel closes rather than on every step keeps the panel
  // usable while several stages are being set, and the restart is chained to a
  // rewrite of the same values so it can never overtake the write it applies.
  // This plugin's own two stages are timed in QML and need none of this.
  function applyPending(latest) {
    if (!root.restartPending || !bar) return
    root.restartPending = false
    bar.run(Model.writeCommand(latest || root.timers) + " && " + Model.restartShellCommand())
  }

  function toggleStayAwake() {
    if (!bar) return
    bar.run("omarchy-toggle-idle")
  }

  function reloadConfig() {
    configFile.reload()
    stayAwakeProbeDebounce.restart()
  }

  // ---- Popup plumbing. Shape contract for shell.summon/hide/toggle routing:
  //      Bar.findPanelWidget requires open/close/opened on the widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    reloadConfig()
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (!panelLoader.item) return
    if (!panelLoader.item.opened) reloadConfig()
    panelLoader.item.toggle()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.timers = Model.readTimers(text())
    onLoadFailed: root.timers = Model.defaultTimers()
    onFileChanged: reload()
  }

  Process {
    id: stayAwakeProbe
    command: ["bash", "-c",
      "mkdir -p \"$HOME/.local/state/omarchy/indicators\"; "
      + "if [[ -f $HOME/.local/state/omarchy/indicators/stay-awake ]]; then echo yes; else echo no; fi"]
    stdout: SplitParser {
      onRead: function(line) { root.stayAwake = String(line).trim() === "yes" }
    }
  }

  Timer {
    id: stayAwakeProbeDebounce
    interval: 120
    repeat: false
    onTriggered: if (!stayAwakeProbe.running) stayAwakeProbe.running = true
  }

  FileView {
    path: root.stayAwakeDir
    watchChanges: true
    printErrors: false
    onFileChanged: stayAwakeProbeDebounce.restart()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.stayAwake ? root.awakeIcon : root.timerIcon
    // Stay Awake is a state worth seeing from across the room: the machine is
    // not going to do any of the things this widget configures.
    active: root.stayAwake
    tooltipText: root.stayAwake
      ? "Stay awake — every timer paused\n" + root.summaryText
      : root.summaryText

    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleStayAwake()
      else root.togglePanel()
    }
  }

  Component.onCompleted: stayAwakeProbeDebounce.restart()
}
