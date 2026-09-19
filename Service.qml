import QtQuick
import Quickshell
import Quickshell.Io
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
// ---------------------------------------------------------------------------
// Why there is no IdleMonitor here
//
// The obvious implementation is a second IdleMonitor armed at this plugin's
// earliest stage. It does not work, and it fails silently and dangerously.
//
// Two IdleMonitors in one shell share a single ext-idle-notify registration.
// The first one to register sets the timeout and the second is ignored, so a
// monitor asking for two hours alongside Omarchy's ten minutes pins the whole
// shell to one of them. Measured on Hyprland 0.56 / Quickshell: with this
// plugin's own monitor at 7200s, the first-party service never reported idle
// at all — no screensaver, and no auto-lock. Two monitors at the *same*
// timeout coexist fine, which is what makes the failure so easy to miss.
//
// So this service creates no monitor. It asks the first-party service what it
// already knows, over the same IPC a person would use, and times its own two
// stages from that. Polling a socket every few seconds is a very cheap price
// for not being able to break the lock screen.
// ---------------------------------------------------------------------------
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null
  property var manifest: null
  property string omarchyPath: "/usr/share/omarchy"

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/shell.json"
  readonly property string stayAwakeDir: home + "/.local/state/omarchy/indicators"

  property var timers: Model.defaultTimers()
  property bool stayAwake: false
  property bool screenIsOff: false

  // What the first-party service last told us.
  property bool builtinIdle: false
  property bool builtinRawIdle: false
  property bool builtinInCycle: false
  property int builtinThreshold: 0
  property bool builtinReachable: false

  // Epoch ms when the seat went quiet, inferred from the first-party threshold.
  // Zero means "not idle".
  property double idleStart: 0
  property bool suspendFired: false

  readonly property int screenOffSeconds: Model.seconds(timers.screenOff)
  readonly property int suspendSeconds: Model.seconds(timers.suspend)

  // Stay Awake is Omarchy's master switch for idling, so it has to govern
  // these stages too. Without this, "Stay Awake" would hold off the
  // screensaver and then suspend the machine anyway.
  readonly property bool armed: !stayAwake && (screenOffSeconds > 0 || suspendSeconds > 0)

  // Recomputed on every poll, never bound. A binding containing Date.now() has
  // no reactive dependency on the clock, so it freezes at whatever it was when
  // idleStart changed — which silently pinned this at the threshold value and
  // meant no stage after it was ever due.
  property int idleSeconds: 0

  // Stages earlier than the first-party threshold cannot fire on time, because
  // nothing reports idle before then.
  readonly property var lateStages: Model.stagesBelowThreshold(timers, builtinThreshold)

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
    log("screen-off", "idle " + root.idleSeconds + "s of " + root.screenOffSeconds + "s")
    run(screenOffProcess, Model.dpmsCommand(false))
  }

  // Hyprland wakes the display on key press and mouse move on its own, so this
  // is the belt to that suspenders: it covers a wake that came from somewhere
  // other than the pointer, and it is harmless when the screen is already on.
  // A separate Process from the one above so a still-running "off" can never
  // swallow the "on" and leave the screen dark.
  function turnScreenOn(reason) {
    if (!root.screenIsOff) return
    root.screenIsOff = false
    log("screen-on", reason)
    run(screenOnProcess, Model.dpmsCommand(true))
  }

  function suspendSystem() {
    if (root.suspendFired) return
    root.suspendFired = true
    log("suspend", "idle " + root.idleSeconds + "s of " + root.suspendSeconds + "s")
    run(suspendProcess, Model.suspendCommand())
  }

  function endIdle(reason) {
    if (root.idleStart === 0 && !root.screenIsOff) return
    root.idleStart = 0
    root.idleSeconds = 0
    root.suspendFired = false
    turnScreenOn(reason || "activity")
    log("idle-end", reason || "activity")
  }

  function applyIdleStatus(raw) {
    var status = Model.parseIdleStatus(raw)
    root.builtinReachable = status.ok
    if (!status.ok) return

    root.builtinIdle = status.idle
    root.builtinRawIdle = status.rawIdle
    root.builtinInCycle = status.inCycle
    root.builtinThreshold = status.threshold

    if (!status.idle) {
      endIdle("activity")
      return
    }

    if (root.idleStart === 0) {
      root.idleStart = Model.idleStartFrom(Date.now(), status.threshold)
      log("idle-start", "threshold " + status.threshold + "s"
        + " screenOff=" + root.screenOffSeconds + " suspend=" + root.suspendSeconds)
    }

    root.idleSeconds = Model.idleSecondsAt(Date.now(), root.idleStart)
    if (!root.armed) return

    var due = Model.dueStages(root.idleSeconds, root.timers)
    if (due.screenOff) turnScreenOff()
    if (due.suspend) suspendSystem()
  }

  // Idle is hours away most of the time, so the quiet cadence is slow; once the
  // seat is actually idle the poll tightens so a stage lands close to its mark
  // and so activity cancels promptly.
  readonly property int pollInterval: root.builtinIdle ? 5000 : 15000

  onArmedChanged: if (!armed) endIdle("disarmed")

  Timer {
    id: pollTimer
    interval: root.pollInterval
    repeat: true
    // Kept running even while disarmed so the screen is put back if a stage
    // fired and then the timers were switched off underneath it.
    running: true
    triggeredOnStart: true
    onTriggered: if (!idleProbe.running) idleProbe.running = true
  }

  Process {
    id: idleProbe
    running: false
    command: Model.idleStatusArgv(root.omarchyPath)
    // Parsed from onStreamFinished, not onExited: the process can report exit
    // before the collector has the last of stdout, and a reading dropped that
    // way is a poll silently skipped.
    stdout: StdioCollector {
      id: idleProbeOut
      waitForEnd: true
      onStreamFinished: root.applyIdleStatus(text)
    }
    onRunningChanged: if (running) probeWatchdog.restart()
    onExited: function(exitCode) {
      probeWatchdog.stop()
      if (exitCode !== 0) root.builtinReachable = false
    }
  }

  Timer {
    // Every poll is skipped while the previous one is still running, so a probe
    // that never exits would stop this service dead and it would stay stopped.
    // Reap it well inside the poll interval so the next tick starts clean.
    id: probeWatchdog
    interval: 4000
    repeat: false
    onTriggered: if (idleProbe.running) idleProbe.running = false
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
      timers: root.timers,
      builtin: {
        reachable: root.builtinReachable,
        idle: root.builtinIdle,
        rawIdle: root.builtinRawIdle,
        inCycle: root.builtinInCycle,
        threshold: root.builtinThreshold
      },
      idleSeconds: root.idleSeconds,
      screenIsOff: root.screenIsOff,
      suspendFired: root.suspendFired,
      pollInterval: root.pollInterval,
      // Stages set shorter than the first-party threshold: they will run late,
      // because nothing reports idle before that point.
      lateStages: root.lateStages
    })
  }

  // Mirrors `omarchy-shell idle status`, which is the first thing to reach for
  // when a stage does not fire: it answers whether this service can see the
  // first-party one, how long the seat has been idle, and what is pending.
  //
  // Safe as a plain IpcHandler because a service is a session singleton — a
  // bar widget would register one of these per monitor and lose the race.
  IpcHandler {
    target: "power-timers"

    function status(): string { return root.statusJson() }
    function refresh(): void {
      configFile.reload()
      stayAwakeProbeDebounce.restart()
      if (!idleProbe.running) idleProbe.running = true
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
    log("service-ready", "no IdleMonitor by design; reading omarchy.idle over IPC")
    stayAwakeProbeDebounce.restart()
  }
}
