import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Model.js" as Model

// The two idle stages Omarchy does not ship: turning the screen off, and
// suspending. Screensaver and lock already have a first-party service behind
// them (omarchy.idle, reading idle.screensaver and idle.lock); this one sits
// after them on the same ladder and is configured by the same panel.
//
// A service rather than something inside the bar widget, because the bar
// mounts one widget instance per monitor and a suspend timer must exist once
// per session, not once per screen.
//
// Structure mirrors omarchy.idle deliberately: ONE IdleMonitor armed at the
// earliest stage, then plain timers for whatever comes after it. A timer
// cannot be reset by the flicker of activity the compositor reports when a
// screensaver or lock surface appears, which a second IdleMonitor would be.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/shell.json"
  readonly property string stayAwakeDir: home + "/.local/state/omarchy/indicators"
  readonly property string stayAwakePath: stayAwakeDir + "/stay-awake"

  property var timers: Model.defaultTimers()
  property bool stayAwake: false
  property bool screenIsOff: false
  property bool inCycle: false

  readonly property int screenOffSeconds: Model.seconds(timers.screenOff)
  readonly property int suspendSeconds: Model.seconds(timers.suspend)
  readonly property int firstStageSeconds: Model.firstStage(screenOffSeconds, suspendSeconds)

  // Stay Awake is Omarchy's master switch for idling, so it has to govern
  // these stages too. Without this, "Stay Awake" would hold off the
  // screensaver and then suspend the machine anyway.
  readonly property bool armed: !stayAwake && firstStageSeconds > 0

  readonly property int screenOffDelay: Model.stageDelay(screenOffSeconds, firstStageSeconds)
  readonly property int suspendDelay: Model.stageDelay(suspendSeconds, firstStageSeconds)

  function log(event, detail) {
    var suffix = detail === undefined || detail === "" ? "" : ": " + String(detail)
    console.log("power-timers " + new Date().toISOString() + " " + event + suffix)
  }

  function run(process, command) {
    process.command = ["bash", "-lc", command]
    process.running = true
  }

  function turnScreenOff() {
    if (root.screenIsOff) return
    root.screenIsOff = true
    log("screen-off", "after " + root.screenOffSeconds + "s idle")
    run(screenOffProcess, Model.dpmsCommand(false))
  }

  // Hyprland wakes the display on key press and mouse move on its own, so this
  // is the belt to that suspenders: it covers a cancel that came from
  // somewhere other than the pointer, and it is harmless when the screen is
  // already on. A separate Process from the one above so a still-running
  // "off" can never swallow the "on" and leave the screen dark.
  function turnScreenOn(reason) {
    if (!root.screenIsOff) return
    root.screenIsOff = false
    log("screen-on", reason)
    run(screenOnProcess, Model.dpmsCommand(true))
  }

  function suspendSystem() {
    log("suspend", "after " + root.suspendSeconds + "s idle")
    run(suspendProcess, Model.suspendCommand())
  }

  function startCycle() {
    if (root.inCycle) return
    root.inCycle = true
    log("cycle-start", "screenOff=" + root.screenOffSeconds + " suspend=" + root.suspendSeconds)

    if (root.screenOffDelay === 0) turnScreenOff()
    else if (root.screenOffDelay > 0) screenOffTimer.restart()

    if (root.suspendDelay === 0) suspendSystem()
    else if (root.suspendDelay > 0) suspendTimer.restart()
  }

  function cancelCycle(reason) {
    screenOffTimer.stop()
    suspendTimer.stop()
    turnScreenOn(reason || "activity")
    if (!root.inCycle) return
    root.inCycle = false
    log("cycle-cancel", reason || "activity")
  }

  onArmedChanged: if (!armed) cancelCycle("disarmed")

  IdleMonitor {
    id: idleMonitor
    enabled: root.armed
    timeout: root.firstStageSeconds
    // A fullscreen video or anything else holding an idle inhibitor keeps the
    // screen on and the machine awake, same as the first-party service.
    respectInhibitors: true
    onIsIdleChanged: {
      if (!root.armed) return
      if (isIdle) root.startCycle()
      else root.cancelCycle("activity")
    }
  }

  Timer {
    id: screenOffTimer
    interval: Math.max(0, root.screenOffDelay) * 1000
    repeat: false
    onTriggered: if (root.armed && root.inCycle) root.turnScreenOff()
  }

  Timer {
    id: suspendTimer
    interval: Math.max(0, root.suspendDelay) * 1000
    repeat: false
    onTriggered: if (root.armed && root.inCycle) root.suspendSystem()
  }

  Process { id: screenOffProcess }
  Process { id: screenOnProcess }
  Process { id: suspendProcess }

  // ---- Configuration. Read straight from shell.json rather than through the
  //      plugin facade: a third-party plugin is only handed the idle subtree
  //      when it is a clone of omarchy.idle, and reading the file keeps this
  //      honest when anything else edits it, including the panel.
  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.timers = Model.readTimers(text())
    onLoadFailed: root.timers = Model.defaultTimers()
    onFileChanged: reload()
  }

  // ---- Stay Awake. The flag is a file's existence, so the directory is what
  //      can be watched; a probe turns that into a boolean. Same shape the
  //      first-party idle service uses, for the same reason.
  Process {
    id: stayAwakeProbe
    command: ["bash", "-c",
      "mkdir -p \"$HOME/.local/state/omarchy/indicators\"; "
      + "if [[ -f $HOME/.local/state/omarchy/indicators/stay-awake ]]; then echo yes; else echo no; fi"]
    stdout: SplitParser {
      onRead: function(line) {
        var next = String(line).trim() === "yes"
        if (next === root.stayAwake) return
        root.stayAwake = next
        root.log("stay-awake", next ? "on" : "off")
      }
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

  function statusJson() {
    return JSON.stringify({
      armed: root.armed,
      stayAwake: root.stayAwake,
      idle: idleMonitor.isIdle,
      inCycle: root.inCycle,
      screenIsOff: root.screenIsOff,
      timers: root.timers,
      monitor: { enabled: idleMonitor.enabled, timeout: idleMonitor.timeout },
      stages: {
        screenOff: root.screenOffSeconds,
        suspend: root.suspendSeconds,
        firstStage: root.firstStageSeconds,
        screenOffDelay: root.screenOffDelay,
        suspendDelay: root.suspendDelay
      },
      pending: { screenOff: screenOffTimer.running, suspend: suspendTimer.running }
    })
  }

  // Mirrors `omarchy-shell idle status`, which is the first thing to reach for
  // when a stage does not fire: it answers whether the monitor is armed, what
  // it is armed at, and which timers are pending, without guessing from logs.
  //
  // Safe as a plain IpcHandler because a service is a session singleton — a
  // bar widget would register one of these per monitor and lose the race.
  IpcHandler {
    target: "power-timers"

    function status(): string { return root.statusJson() }
    function refresh(): void {
      configFile.reload()
      stayAwakeProbeDebounce.restart()
    }

    // Drives the real screen-off path and puts the display back a beat later.
    // Waiting out a two-hour timeout to find out whether the wiring works is
    // not a debugging loop anyone will run, so this is the short version.
    function testScreenOff(): string {
      root.turnScreenOff()
      testRestore.restart()
      return "screen off, back in " + testRestore.interval + "ms"
    }
  }

  Timer {
    id: testRestore
    interval: 1200
    repeat: false
    onTriggered: root.turnScreenOn("self-test")
  }

  Component.onCompleted: {
    log("service-ready")
    stayAwakeProbeDebounce.restart()
  }
}
