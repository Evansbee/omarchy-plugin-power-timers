// Pure logic for the idle-timer panel and its service: the preset ladder, the
// duration formatting, the shell.json reading, and the shell.json writing.
// Deliberately Qt-free so every rule here can be exercised under node without a
// running shell; the QML owns layout, colors, and process spawning.

// ---------------------------------------------------------------- the ladder

// What a stepper walks, in seconds. 30s leads the real values because it makes
// a stage testable without sitting on your hands for ten minutes.
var LADDER = [0, 30, 60, 120, 180, 300, 600, 900, 1200, 1800,
              2700, 3600, 5400, 7200, 10800, 14400, 21600, 28800]

// Omarchy's idle service reads `idle.screensaver` and `idle.lock` through
// `secondsFromConfig`, which treats 0 as "right now" rather than "never" — so
// never cannot be written as 0 for those two. A day is never within any session
// that has a person in front of it, and it keeps the value a plain number that
// the built-in service can still act on.
var NEVER_SECONDS = 86400

// Keys owned by Omarchy, in the order the ladder fires.
var OMARCHY_KEYS = ["screensaver", "lock"]
// Keys owned by this plugin. They live under their own top-level object rather
// than in `idle` precisely because 0 means the opposite there: for Omarchy's
// keys 0 is immediate, for these it is never.
var PLUGIN_KEYS = ["screenOff", "suspend"]
var PLUGIN_CONFIG_KEY = "evansbee.power-timers"

function defaultTimers() {
  // Screensaver and lock mirror Omarchy's own defaults; screen off and suspend
  // default to never, which is what Omarchy does today with no plugin at all.
  return { screensaver: 150, lock: 300, screenOff: 0, suspend: 0 }
}

function seconds(value) {
  var n = Number(value)
  if (!isFinite(n) || n < 0) return 0
  return Math.floor(n)
}

// Never is 0 for this plugin's own stages and the day-long sentinel for
// Omarchy's, so both spellings answer the same question.
function isNever(value) {
  var n = seconds(value)
  return n === 0 || n >= NEVER_SECONDS
}

function nearestLadderIndex(value) {
  var target = seconds(value)
  var best = 0
  var bestGap = Infinity
  for (var i = 0; i < LADDER.length; i++) {
    var gap = Math.abs(LADDER[i] - target)
    if (gap < bestGap) { bestGap = gap; best = i }
  }
  return best
}

// Walk the ladder. A value that is not on it snaps to the nearest rung first,
// so a hand-edited 7 minutes becomes 5 or 10 rather than refusing to move.
function step(value, delta) {
  var index = nearestLadderIndex(isNever(value) ? 0 : value)
  var next = index + (delta > 0 ? 1 : -1)
  if (next < 0) next = 0
  if (next > LADDER.length - 1) next = LADDER.length - 1
  return LADDER[next]
}

// ------------------------------------------------------------- formatting

// Compact enough for a stepper that has to sit between two buttons: "10m",
// "1h 30m", "Never". No decimals, no pluralization to jitter the width.
function formatDuration(value) {
  if (isNever(value)) return "Never"
  var total = seconds(value)
  if (total < 60) return total + "s"

  var hours = Math.floor(total / 3600)
  var minutes = Math.round((total % 3600) / 60)
  if (hours === 0) return minutes + "m"
  if (minutes === 0) return hours + "h"
  return hours + "h " + minutes + "m"
}

// The one-line ladder under the panel title. Reads as a sentence rather than a
// table because it is there to be skimmed, not compared.
function summary(timers) {
  var parts = []
  parts.push(isNever(timers.screensaver)
    ? "no screensaver" : "screensaver " + formatDuration(timers.screensaver))
  parts.push(isNever(timers.lock)
    ? "never locks" : "lock " + formatDuration(timers.lock))
  parts.push(isNever(timers.screenOff)
    ? "screen stays on" : "screen off " + formatDuration(timers.screenOff))
  parts.push(isNever(timers.suspend)
    ? "never sleeps" : "sleep " + formatDuration(timers.suspend))
  return parts.join(" · ")
}

// Stages fire on their own clocks, so a lock set earlier than the screensaver
// simply happens first. That is legal and occasionally deliberate — worth a
// note under the rows, not a correction the panel makes on the user's behalf.
function outOfOrder(timers) {
  var order = ["screensaver", "lock", "screenOff", "suspend"]
  var previous = 0
  for (var i = 0; i < order.length; i++) {
    var value = timers[order[i]]
    if (isNever(value)) continue
    var current = seconds(value)
    if (current < previous) return true
    previous = current
  }
  return false
}

// ------------------------------------------------------------ reading config

function readTimers(raw) {
  var timers = defaultTimers()
  var data
  try {
    data = JSON.parse(String(raw || ""))
  } catch (e) {
    return timers
  }
  if (!data || typeof data !== "object") return timers

  var idle = data.idle && typeof data.idle === "object" ? data.idle : {}
  for (var i = 0; i < OMARCHY_KEYS.length; i++) {
    var omarchyKey = OMARCHY_KEYS[i]
    if (idle[omarchyKey] !== undefined && idle[omarchyKey] !== null)
      timers[omarchyKey] = seconds(idle[omarchyKey])
  }

  var mine = data[PLUGIN_CONFIG_KEY] && typeof data[PLUGIN_CONFIG_KEY] === "object"
    ? data[PLUGIN_CONFIG_KEY] : {}
  for (var j = 0; j < PLUGIN_KEYS.length; j++) {
    var pluginKey = PLUGIN_KEYS[j]
    if (mine[pluginKey] !== undefined && mine[pluginKey] !== null)
      timers[pluginKey] = seconds(mine[pluginKey])
  }

  return timers
}

function sameTimers(a, b) {
  if (!a || !b) return false
  var keys = OMARCHY_KEYS.concat(PLUGIN_KEYS)
  for (var i = 0; i < keys.length; i++) {
    if (seconds(a[keys[i]]) !== seconds(b[keys[i]])) return false
  }
  return true
}

// ------------------------------------------------------------ writing config

// Omarchy ships `omarchy-shell-config`, which owns the read-modify-write of
// shell.json: it normalizes the shape, runs a jq program over it, writes the
// result atomically, and pokes the running shell to reload. Going through it
// means this plugin is never a second, competing writer of that file.
//
// The values are integers this file produced, so they cannot carry anything
// through to the shell; they are still forced through parseInt on the way out.
function writeCommand(timers) {
  var screensaver = writableOmarchySeconds(timers.screensaver)
  var lock = writableOmarchySeconds(timers.lock)
  var screenOff = seconds(timers.screenOff)
  var suspend = seconds(timers.suspend)

  var program = ''
    + '\n| .idle = (.idle | if type == "object" then . else {} end)'
    + '\n| .idle.screensaver = $screensaver'
    + '\n| .idle.lock = $lock'
    + '\n| ."' + PLUGIN_CONFIG_KEY + '" = { screenOff: $screenOff, suspend: $suspend }\n'

  return 'source omarchy-shell-config && commit "$NORMALIZE"' + singleQuote(program)
    + ' --argjson screensaver ' + screensaver
    + ' --argjson lock ' + lock
    + ' --argjson screenOff ' + screenOff
    + ' --argjson suspend ' + suspend
}

// Never, for a key Omarchy owns, has to be a real number of seconds.
function writableOmarchySeconds(value) {
  var n = seconds(value)
  return n === 0 ? NEVER_SECONDS : n
}

function singleQuote(value) {
  return "'" + String(value === undefined || value === null ? "" : value).replace(/'/g, "'\\''") + "'"
}

// ------------------------------------------------- reading the idle service

// This plugin deliberately creates no IdleMonitor of its own. Two of them in
// one shell share a single ext-idle-notify registration, and the one that
// registers first wins: a second monitor asking for a different timeout
// silently pins the whole shell to the wrong one. When this plugin used its
// own monitor set to two hours, Omarchy's screensaver and — far worse — its
// auto-lock stopped firing at all.
//
// So idle is read from the first-party service instead, over the same IPC a
// person would use. It reports whether the seat is idle and the two timeouts
// it is watching; everything this plugin does is timed from there.
// Invoked directly rather than through `bash -lc`: a login shell sources the
// whole user profile on every poll, which is both slow and a way for an
// unrelated shell change to break this. The path comes from the host, which
// injects omarchyPath into every plugin entry point.
function idleStatusArgv(omarchyPath) {
  var base = String(omarchyPath || "/usr/share/omarchy").replace(/\/+$/, "")
  return [base + "/bin/omarchy-shell", "idle", "status"]
}

// `idle` alone is the wrong signal to time from. Launching the screensaver
// makes the compositor report activity, so the first-party monitor's isIdle
// drops back to false for a moment every time the screensaver appears — and
// timing from that restarts this plugin's clock on every screensaver, pushing
// a two-hour stage out by however long the screensaver took to arrive.
//
// The first-party service already solves this for itself and exposes the
// result: `inIdleCycle` stays true across that blip and only clears on real
// activity. Either one being true means the seat has been quiet since the
// cycle began.
function parseIdleStatus(raw) {
  var out = { ok: false, idle: false, rawIdle: false, inCycle: false,
              screensaver: 0, lock: 0, threshold: 0 }
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return out
    out.ok = true
    out.rawIdle = data.idle === true
    out.inCycle = data.inIdleCycle === true
    out.idle = out.rawIdle || out.inCycle
    out.screensaver = seconds(data.screensaver)
    out.lock = seconds(data.lock)
    var candidates = []
    if (out.screensaver > 0) candidates.push(out.screensaver)
    if (out.lock > 0) candidates.push(out.lock)
    out.threshold = candidates.length ? Math.min.apply(null, candidates) : 0
    return out
  } catch (e) {
    return out
  }
}

// The first-party monitor only reports idle once it passes min(screensaver,
// lock), so that moment is `threshold` seconds after the seat actually went
// quiet. Idle therefore began `threshold` seconds before it was observed.
function idleStartFrom(observedAtMs, threshold) {
  return Number(observedAtMs) - Math.max(0, seconds(threshold)) * 1000
}

function idleSecondsAt(nowMs, idleStartMs) {
  if (!idleStartMs) return 0
  return Math.max(0, Math.floor((Number(nowMs) - Number(idleStartMs)) / 1000))
}

// Which of this plugin's stages are due for a given idle duration.
function dueStages(idleSeconds, timers) {
  return {
    screenOff: seconds(timers.screenOff) > 0 && idleSeconds >= seconds(timers.screenOff),
    suspend: seconds(timers.suspend) > 0 && idleSeconds >= seconds(timers.suspend)
  }
}

// A stage set earlier than the first-party threshold cannot fire on time,
// because nothing reports idle before then. Worth surfacing rather than
// quietly running late.
function stagesBelowThreshold(timers, threshold) {
  var limit = seconds(threshold)
  var late = []
  if (limit <= 0) return late
  if (seconds(timers.screenOff) > 0 && seconds(timers.screenOff) < limit) late.push("screenOff")
  if (seconds(timers.suspend) > 0 && seconds(timers.suspend) < limit) late.push("suspend")
  return late
}

// ----------------------------------------------------- applying the changes

// Changing `idle.screensaver` or `idle.lock` updates the first-party service's
// QML properties but NOT its Wayland registration — ext-idle-notify is asked
// for a timeout once, when the monitor is built, and a later change to the
// property never reaches the compositor. Omarchy has this behaviour with or
// without this plugin installed; restarting the shell is what actually applies
// a new screensaver or lock timeout.
//
// This plugin's own two stages are timed in QML off the observed idle state,
// so they take effect immediately and need none of this.
function needsShellRestart(before, after) {
  if (!before || !after) return false
  return seconds(before.screensaver) !== seconds(after.screensaver)
    || seconds(before.lock) !== seconds(after.lock)
}

function restartShellCommand() {
  return "omarchy restart shell"
}

// -------------------------------------------------------------- the service

// Hyprland 0.56 takes Lua dispatchers, so the old `hyprctl dispatch dpms off`
// spelling parses as Lua and fails. Waking back up is Hyprland's job:
// misc:key_press_enables_dpms and misc:mouse_move_enables_dpms are both on by
// default, and the service dispatches `on` as well when the cycle cancels.
function dpmsCommand(on) {
  return "hyprctl dispatch 'hl.dsp.dpms(\"" + (on ? "on" : "off") + "\")'"
}

function suspendCommand() {
  return "systemctl suspend"
}

// The earliest armed stage, which is where the idle monitor is set. Later
// stages run off plain timers from there, mirroring Omarchy's own idle service:
// a timer cannot be reset by the blip of activity that starting a screensaver
// or a lock screen can look like to the compositor.
function firstStage(screenOffSeconds, suspendSeconds) {
  var candidates = []
  if (screenOffSeconds > 0) candidates.push(screenOffSeconds)
  if (suspendSeconds > 0) candidates.push(suspendSeconds)
  if (candidates.length === 0) return 0
  return Math.min.apply(null, candidates)
}

// Seconds to wait after the idle monitor fires, or -1 for a stage that is off.
function stageDelay(stageSeconds, firstStageSeconds) {
  if (stageSeconds <= 0) return -1
  return Math.max(0, stageSeconds - firstStageSeconds)
}
