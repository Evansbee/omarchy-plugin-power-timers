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
  both `service` and `bar-widget`, the way `omarchy.media` does, and the idle
  timers live in the service.
- **One idle monitor, then plain timers.** This mirrors `omarchy.idle`
  exactly. A second `IdleMonitor` armed at a later stage would be reset by the
  flicker of activity the compositor reports when a screensaver or lock surface
  appears; a `Timer` started from the first stage cannot be.
- **Stay Awake governs all four stages.** Without that, Omarchy's master switch
  would hold off the screensaver and then suspend the machine anyway. The
  plugin reads the same `~/.local/state/omarchy/indicators/stay-awake` flag the
  first-party service does.
- **Idle inhibitors are respected**, so a fullscreen video keeps the screen on
  and the machine awake.
- **It is never a second writer of `shell.json`.** Every change goes through
  `omarchy-shell-config`, the helper Omarchy's own `omarchy bar` commands use:
  normalize, run a jq program, write atomically, poke the shell to reload.

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
omarchy-shell power-timers status      # armed? timeout? which timers pending?
omarchy-shell power-timers refresh     # re-read shell.json and the stay-awake flag
omarchy-shell power-timers testScreenOff   # blank the display for 1.2s, then restore
```

`testScreenOff` exists because waiting out a two-hour timeout is not a
debugging loop anyone will run. It drives the real code path.

To check the idle trigger itself, set Screen off to `30s`, leave the machine
alone, and watch:

```bash
watch -n2 'omarchy-shell power-timers status | jq "{idle, inCycle, screenIsOff}"'
```

`idle` stays `false` for as long as the seat sees input, which includes you
nudging the mouse to read the terminal.

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
