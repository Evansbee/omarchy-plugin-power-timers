# Power timers

An Omarchy shell bar widget for the idle ladder: how long until the
screensaver, the lock screen, the display going dark, and the machine
sleeping — all four set from one panel in the bar.

```
   ⧗  Idle timers
   screensaver 10m · lock 30m · screen off 2h · never sleeps

   After you stop touching it
     ▣  Screensaver        [−]   10m  [+]   dims to the screensaver
     🔒  Lock              [−]   30m  [+]   asks for your password
     ▭  Screen off         [−]    2h  [+]   blanks the display
     z  Sleep              [−] Never  [+]   never happens

     ☕  Stay awake                  [ ● ]  holds off every stage above
```

Omarchy ships the first two stages and nothing after them: `omarchy.idle`
reads `idle.screensaver` and `idle.lock` out of `shell.json`, and there is no
screen-off or suspend timeout anywhere in the system. This plugin puts a panel
in front of the two that exist and adds the two that don't.

## Interactions

| Gesture | What it does |
|---|---|
| Hover the bar icon | The whole ladder as one line |
| Left click | Open the panel |
| Right click | Toggle Stay Awake |
| `−` / `+`, or `h` / `l` | Step a stage along the preset ladder |
| `j` / `k` | Move between rows |
| `Enter` on the last row | Toggle Stay Awake |
| `Esc` | Close |

Changes save themselves — a step updates the panel immediately, and a debounce
writes the whole set about half a second later.

The bar icon is an hourglass while the timers are armed and Omarchy's own Stay
Awake coffee cup while they are not, so the bar says the same thing the system
menu does.

## Design notes

- **A service, not just a widget.** The bar mounts one widget instance per
  monitor; a suspend timer has to exist once per session. The manifest declares
  both `service` and `bar-widget`, the way `omarchy.media` does, and the timing
  lives in the service.
- **Stay Awake governs all four stages.** Without that, Omarchy's master switch
  would hold off the screensaver and then suspend the machine anyway. The
  plugin reads the same `~/.local/state/omarchy/indicators/stay-awake` flag the
  first-party service does.
- **It is never a second writer of `shell.json`.** Every change goes through
  `omarchy-shell-config`, the helper Omarchy's own `omarchy bar` commands use:
  normalize, run a jq program, write atomically, poke the shell to reload.

## Three things that bite, and what this plugin does about them

These were all found the hard way on Hyprland 0.56 / Quickshell. The first one
is the reason to read this section before writing a similar plugin.

### 1. A second IdleMonitor silently breaks the lock screen

The obvious implementation is an `IdleMonitor` armed at the plugin's earliest
stage. **Do not do this.** Two IdleMonitors in one shell share a single
`ext-idle-notify` registration; the first to register wins and the second is
ignored. With this plugin's own monitor at two hours next to Omarchy's ten
minutes, the first-party service stopped reporting idle *entirely* — no
screensaver, and no auto-lock. Nothing logs an error. Two monitors at the
*same* timeout coexist perfectly, which is what makes it so easy to ship.

So this plugin creates no monitor at all. It reads the first-party service over
the same IPC a person would use (`omarchy-shell idle status`) and times its own
stages from that. A socket poll every 5–15s is a cheap price for not being able
to break the lock screen.

### 2. `idle` is the wrong signal — the screensaver resets it

Launching the screensaver makes the compositor report activity, so the
first-party monitor's `isIdle` drops to false for a moment *every time the
screensaver appears*:

```
11:18:23.228  idle-monitor: idle
11:18:23.228  idle-cycle-start: screensaver=30 lock=1800
11:18:23.309  idle-monitor: active               <-- 80ms later
11:18:23.309  idle-monitor-active: screensaver cycle remains armed
```

Timing from `idle` restarts the clock on every screensaver, pushing a two-hour
stage out by however long the screensaver took to arrive. The first-party
service already solves this for itself and exposes the answer: `inIdleCycle`
stays true across the blip and only clears on real activity. This plugin treats
`idle OR inIdleCycle` as "the seat has been quiet since the cycle began".

### 3. Screensaver and lock changes need a shell restart

`ext-idle-notify` is asked for a timeout once, when the monitor is built.
Changing `idle.screensaver` or `idle.lock` afterwards updates the first-party
service's QML property — `omarchy-shell idle status` will happily report the
new number — but never reaches the compositor. **This is true with or without
this plugin installed**: editing those values in `shell.json` by hand has the
same problem.

So the panel restarts the shell when you close it, and only when one of those
two values actually changed. The footer says so while a restart is owed. This
plugin's own two stages are timed in QML from the observed idle state, so they
take effect immediately and need none of this.

### Consequences worth knowing

- This plugin's stages cannot fire before `min(screensaver, lock)`, because
  nothing reports idle before then. Setting Screen off shorter than the
  screensaver makes it land late, not early; `status` reports those as
  `lateStages`.
- Stage timing is accurate to the poll interval — 5s once idle, 15s before.
  On an hours-long stage that is noise.

## Lock when you come back

Omarchy locks on a timer. Set the screensaver to 10 minutes and the lock to 30
and you get the screensaver for twenty minutes, then a session-lock surface
that covers it — so coming back any later than half an hour, the screensaver is
all you never saw.

`Lock when I come back` swaps the timer for the event. Omarchy's lock timeout
is written as never, and the lock fires off the screensaver being *dismissed*
instead:

```
 10m  screensaver appears
   …  stays up, however long you are gone
   ↓  you touch the mouse
      screensaver closes → lock
```

The screensaver is an ordinary window (class `org.omarchy.screensaver`) and
Hyprland emits `closewindow` for it the instant it goes. The first-party
service already watches that exact event — it just reads it the other way
round, as "the user came back, cancel the pending lock". This is the same
event, inverted.

**The tradeoff, stated plainly:** this is not an atomic lock. The screensaver
window has to close before anything can know to lock it, so the desktop is
briefly visible underneath — on the order of a tenth of a second, since
`omarchy-system-lock` is an IPC into the same shell and the locker is
`keepLoaded`. Someone standing at the keyboard would see that flash. If your
threat model cares, use the timed lock instead.

It needs a screensaver to hang off: with the screensaver set to Never there is
no window to dismiss, and the panel says so rather than pretending.

## Where the settings live

Two of the four keys are Omarchy's and two are this plugin's, and they mean
opposite things at zero — which is exactly why they do not share an object.

```json
{
  "idle": { "screensaver": 600, "lock": 1800 },
  "evansbee.power-timers": { "screenOff": 7200, "suspend": 0 }
}
```

| Key | Owner | Units | Zero means |
|---|---|---|---|
| `idle.screensaver` | Omarchy (`omarchy.idle`) | seconds | **immediately** |
| `idle.lock` | Omarchy (`omarchy.idle`) | seconds | **immediately** |
| `evansbee.power-timers.screenOff` | this plugin | seconds | never |
| `evansbee.power-timers.suspend` | this plugin | seconds | never |
| `evansbee.power-timers.lockOnWake` | this plugin | 0 / 1 | off |

With `lockOnWake` on, `idle.lock` is written as `86400` — the timed lock is
deliberately out of the way, and the lock comes from the screensaver closing.

Because 0 cannot mean "never" for Omarchy's two keys, picking **Never** for the
screensaver or the lock writes `86400` — a day, which is never inside any
session with a person in front of it. Never for screen off and sleep is a
literal 0, and the stage is simply not armed.

Stages run on their own clocks from the same idle start, so they fire in time
order rather than list order. Setting the lock shorter than the screensaver is
legal; the panel says so rather than quietly rewriting it.

## How the two new stages work

Screen off dispatches Hyprland's DPMS dispatcher. Hyprland 0.56 takes Lua
dispatchers, so the old spelling parses as Lua and fails — the working form is:

```bash
hyprctl dispatch 'hl.dsp.dpms("off")'
```

Waking up is Hyprland's job: `misc:key_press_enables_dpms` and
`misc:mouse_move_enables_dpms` are both on by default in Omarchy, and the
service dispatches `on` as well when the idle cycle cancels.

Sleep runs `systemctl suspend`.

## Debugging

The service answers over IPC, the same way `omarchy-shell idle status` does:

```bash
omarchy-shell power-timers status          # armed? idle for how long? what is pending?
omarchy-shell power-timers refresh         # re-read shell.json and the stay-awake flag
omarchy-shell power-timers testScreenOff   # blank the display for 1.2s, then restore
```

`status` reports what it can see of the first-party service, which is the first
thing to check when a stage does not fire:

```json
{
  "armed": true,
  "builtin": { "reachable": true, "idle": false, "rawIdle": false,
               "inCycle": false, "threshold": 600 },
  "idleSeconds": 0,
  "screenIsOff": false,
  "lateStages": []
}
```

`testScreenOff` exists because waiting out a two-hour timeout is not a
debugging loop anyone will run. It drives the real code path.

To watch a full cycle, set Screen off to `30s`, leave the machine alone, and:

```bash
watch -n2 'omarchy-shell power-timers status | jq "{idleSeconds, screenIsOff, builtin}"'
```

`builtin.reachable: false` means this service cannot see `omarchy.idle` — check
that it is enabled, since every stage here is timed from it.

## Layout

| File | What it is |
|---|---|
| `manifest.json` | Plugin manifest — `service` + `bar-widget` |
| `Service.qml` | The idle monitor, the stage timers, the IPC |
| `BarWidget.qml` | Bar icon, config reading, the write call |
| `Panel.qml` | The settings panel |
| `Model.js` | Ladder, formatting, config parsing, command building — Qt-free |

`Model.js` touches no Qt API, so the rules can be exercised under `node`:

```bash
node -e '
var fs = require("fs"), M = {}
new Function("module", fs.readFileSync("Model.js", "utf8")
  + "\nmodule.exports = { LADDER: LADDER, formatDuration: formatDuration, writeCommand: writeCommand }")(M)
console.log(M.exports.LADDER.map(M.exports.formatDuration).join(" "))
console.log(M.exports.writeCommand({ screensaver: 600, lock: 1800, screenOff: 7200, suspend: 0 }))'
```

## Install

```bash
omarchy plugin add https://github.com/evansbee/omarchy-plugin-power-timers.git
omarchy plugin enable evansbee.power-timers
```

Enabling mounts the service and drops the widget into the right-hand section of
the bar. Both survive reboots and `omarchy update`, because the enabled state
and the bar entry live in `shell.json`.

### Hacking on it

Clone anywhere and link the checkout in instead:

```bash
ln -sfn "$PWD" ~/.config/omarchy/plugins/evansbee.power-timers
omarchy-shell shell rescanPlugins
omarchy plugin enable evansbee.power-timers
```

The shell watches `~/.config/omarchy/plugins` with `inotifywait -r`, which does
not follow symlinks, so saving a file does **not** hot-reload. Run
`omarchy restart shell` after an edit.

## Requirements

Omarchy with the Quickshell-based `omarchy-shell`, Hyprland 0.56 or newer for
the Lua DPMS dispatcher, a Nerd Font for the Material Design glyphs, and `jq`,
which `omarchy-shell-config` already depends on.

## License

MIT
