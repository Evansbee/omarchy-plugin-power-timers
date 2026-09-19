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
