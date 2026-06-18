# mMouse

Keyboard-driven cursor control for macOS. Goal: drop the physical mouse as much as possible.

<img width="1512" height="982" alt="image" src="https://github.com/user-attachments/assets/2faa6d9a-ac08-41b2-aa56-5438343e1d0b" />

A menu-bar app: press a combo to enter **red mode**, then drive the real system cursor with the keyboard — arrows to move, `Enter` to click, `Cmd+arrow` to scroll, `Shift+arrow` to drag-select. On top of that, a **grid layer** paints a labelled matrix over the screen so you can warp the cursor anywhere in two keystrokes, with optional **custom pink labels** for the spots you hit most.

## Quick start

```bash
git clone <repo-url> mMouse && cd mMouse
make install                       # build release + install to /Applications
open /Applications/mMouse.app
```

Grant Accessibility when prompted (see [Install](#install-end-users)), then:

1. Press **`Cmd + ;`** → red follow-dot + a labelled grid appear.
2. Type a cell's two letters (e.g. `BC`) → cursor warps there. Type a **pink** label (e.g. `S1`) for a pinned cell.
3. Arrows fine-tune (step cell-by-cell), **`Enter`** clicks, **`Esc`** backs out.

## Features

- **Activation**: `Cmd + ;` (single press by default; configurable) turns on **red mode + the grid layer together** — the red follow-badge AND a translucent labelled matrix appear at once. You can add more activation combos via config (e.g. both `Cmd + E` and `Cmd + Q`).
- **Grid layer**: while on, type a 2-letter cell code (row letter + column letter, e.g. `BC`) to warp the cursor straight to that cell — coarse-jump anywhere on screen, then fine-tune with arrows (which step cell-by-cell). `Shift` + the second letter also clicks. `Cmd + '` re-opens the layer if you peeled it off.
- **Custom cell labels**: pin easy-to-remember labels (e.g. `S1`, `11`) onto specific cells. They render on a **pink pill** so they stand out, and you type the label to warp there. Fully configurable; ships with a handful of defaults.
- **Layered exit**: `Esc` (or `Enter`) peels the grid layer off first (stays in red mode); then in plain red mode, `Esc` exits, or **`Enter` left-clicks and exits in one go**.
- **Direct cursor control**: arrow keys move the real system cursor — what you see is what gets clicked
- **Click** *(hardcoded)*:
  - `Enter` → left click
  - `Enter × 2` (twice within 400ms) → double click
  - `Shift + Enter` → right click
- **Scroll** *(hardcoded)*: `Cmd + movement_key` → scroll wheel events at the cursor
- **Drag / block selection** *(hardcoded)*: hold `Shift + arrow` → mouseDown, drag while held, release Shift → mouseUp
- **mMouse-priority routing**: the keys mMouse uses are tapped at the **HID level** ahead of the OS, so they win even over system hotkeys (Spotlight, Cmd+Space, Cmd+Tab). Every *other* shortcut — typing, Cmd+C/V/Q/Tab, Cmd+Shift+4, anything — passes straight through to the foreground app as if mMouse weren't running.
- **Speed**: integer 1..10 (default 3); quadratic curve + acceleration on hold
- **Speed boost**: hold `Option` (configurable) while moving → 5× speed
- **Hot-reload** config — edit `~/.mMouse.json`, save, no restart
- **Multi-monitor**: grid opens on the display the cursor is on; cursor clamped to the active display
- Menu bar app (no Dock icon)

## Install (end users)

```bash
git clone <repo-url> mMouse && cd mMouse
make install                # build release + install to /Applications
open /Applications/mMouse.app
```

Requirements: Xcode Command Line Tools (Swift 5.9+) and macOS 13+.

First launch:
1. Alert pops asking for Accessibility → click **Open System Settings**.
2. Toggle on `mMouse` under **Privacy & Security → Accessibility**.
3. App **relaunches itself** once it detects the grant → ready to use.

> The default install signs with an ad-hoc identity. The app works perfectly, but a **rebuild** creates a new code identity and macOS re-prompts for the Accessibility grant. If that bothers you, see [Stable signing cert (developer)](#stable-signing-cert-developer) below.

## Usage

| Action | Keys |
|---|---|
| **Activate (red + grid layer)** | `Cmd + ;` (also `Cmd + E` / `Cmd + Q` if configured) |
| Re-open grid layer (after peeling) | `Cmd + '` |
| **Grid jump** (warp to a cell) | with layer on: type row letter + column letter (e.g. `BC`) |
| Grid jump **+ click** | row letter → `Shift` + column letter |
| **Custom-label jump** (pink cells) | with layer on: type the pinned label (e.g. `S1`, `11`); `Shift` on the last key also clicks |
| **Step hover cell** (layer on) | arrow keys → jump one cell at a time; cursor snaps to the new cell's centre |
| Grid: re-pick row | `Backspace` (clears the buffered first letter) |
| Peel grid layer off (stay in red) | `Esc` or `Enter` (no click) |
| **Red mode `Enter`** (no layer) | left-click **and** exit red mode immediately |
| Exit red mode (no click) | `Esc` |
| Up | `↑` |
| Down | `↓` |
| Left | `←` |
| Right | `→` |
| Left click | `Enter` (mode stays active) |
| Double click | `Enter × 2` (within 400ms) |
| Right click | `Shift + Enter` |
| Scroll up | `Cmd + ↑` (hold for continuous scroll) |
| Scroll down | `Cmd + ↓` |
| Scroll left | `Cmd + ←` |
| Scroll right | `Cmd + →` |
| **Hold-to-drag** (block select / screenshot) | `Shift + arrow` (drag while held, release Shift = mouseUp) |
| Commit drag (alt) | `Enter` |
| Speed boost (5× by default) | hold `Option` while moving (configurable) |
| **Panic exit** | `Esc` (auto-commits drag if in progress) |

Menu bar — an `mM` monogram icon:
- **default tint** — inactive (typing works normally)
- **red tint** — active (mMouse's keys are live; it briefly flashes on each click/drag to confirm the action). The red follow-dot next to the cursor is the on-screen cue for the same state.

### How it works in active mode

- The **real system cursor** is what moves. Arrow keys warp it; the cursor you see is the cursor that will click. No floating overlay, no aim icon.
- `Enter` posts a left click at the cursor's current position.
- `Shift + Enter` opens a context menu where the cursor is.
- After clicking, mMouse stays active — keep moving / clicking / scrolling. Press the activation combo or `Esc` to exit.

### Drag (block selection)

Hold `Shift` then press an arrow → `mouseDown` at the current cursor. Keep `Shift` held while arrows move the cursor — the drag continues (`mouseDragged` posted each tick so apps render the selection rectangle). Release `Shift` → `mouseUp` commits.

- Releasing an arrow without releasing `Shift` keeps the mouse held down (useful when you want to pause mid-drag, reposition, then continue).
- `Enter` also commits the drag (alternative to releasing Shift).
- `Esc` commits any in-progress drag, then deactivates.

Perfect for selecting a screenshot region after `Cmd+Shift+4`, lasso-selecting files in Finder, marquee-selecting in design tools, or any "mouse-down + move + release" gesture.

Apps see the Shift modifier held during the drag, so Shift+drag semantics (e.g. extend a text-editor selection, snap to angle in design tools) work as expected.

### Grid layer / grid jump

The grid layer is an **opt-in on top of red mode**. Press `Cmd + '` (configurable) and a translucent labelled matrix appears over the display the cursor is on — if red mode wasn't on yet, this turns it on too. The screen is split into a grid sized so cells stay roughly square (~150px target, configurable via `grid.targetCellPx`); each cell carries a two-letter code — the **first letter is its row**, the **second its column** (e.g. `BC` = row B, column C).

- Press the **first letter** → every other row dims so only the candidate columns remain bright.
- Press the **second letter** → the cursor warps to that cell's centre. The layer **stays up** so you can immediately jump again or fine-tune with arrows.
- Hold **`Shift`** on the second letter → warp **and** left-click in one shot.
- **Arrow keys step cell-by-cell**: while the layer is on, a bare arrow moves the hover cell one cell over and the cursor snaps to that cell's centre — discrete jumps, not the slow continuous glide. (Cmd+arrow still scrolls, Shift+arrow still drags.)
- `Backspace` re-picks the row; a half-entered row resets itself after ~2s.

The cell the cursor currently sits in is flooded in pale neon yellow and tracks the cursor as you move, so you always know where you are ("I'm in `BC`, I want `FJ`"). The point is coarse-jump first (kill the long travel), then either type the next cell or step with arrows — much faster than crawling the cursor across the whole screen.

#### Custom cell labels (pink pills)

Two-letter codes like `FJ` are easy to *read* but not always easy to *remember* or *type fast* for the spots you hit constantly. You can pin a custom label onto any cell — it renders on a **pink pill** (instead of the default orange) so it stands out, and typing the label warps the cursor there just like a normal code.

Configure them in `grid.customLabels` (see [Config](#config)). Each entry maps a cell — identified by its **default two-letter code** — to the label you'd rather use:

```json
"grid": {
  "customLabels": [
    { "cell": "FA", "label": "S1" },
    { "cell": "HA", "label": "S2" },
    { "cell": "JC", "label": "11" },
    { "cell": "LK", "label": "22" },
    { "cell": "WI", "label": "33" }
  ]
}
```

- **`cell`** is the *original* code of the cell you want to rename (`"FA"` = row F, col A). That's how the cell is located, so it's stable regardless of what label you give it.
- **`label`** is what's shown and what you type. Letters and digits both work — so labels like `S1`, `11`, `22` are fine even though the normal grid is letters-only.
- Typing matches the same way: first key, then second key. `S1` = press `S` then `1`; `11` = press `1` then `1`. `Shift` on the last key also clicks. A digit that *isn't* part of a custom label still passes straight through.
- Out-of-range entries (a cell that doesn't exist on the current display's grid) are silently skipped — the count of labels actually applied is printed when the layer opens.
- This is **just a setting**. The five labels above are the built-in defaults (also written into the config on first launch); override the list to whatever you want, or set `"customLabels": []` to turn them all off.

**Exit is layered.** With the layer on, `Esc` or `Enter` peels it off (no click) and drops you back to plain red mode — badge + arrows, typing works again. Then in plain red mode: `Esc` exits, or **`Enter` left-clicks and exits in one motion** (handy: jump near a button with the layer, peel off, then `Enter` to click it and you're done). While the layer is on, bare letters drive the grid so you can't type them into the foreground app — the moment you peel back to red mode, plain letters pass through again.

### Key routing model

In **red mode** mMouse consumes only the keys it uses (arrows, Enter, Esc, the activation/grid combos); everything else — typing, Cmd+C, Cmd+S, Cmd+Tab, Cmd+Shift+4 — passes through. With the **grid layer** on, it additionally claims **bare/Shift letters** (grid jump), plus **digits that belong to a custom label** (e.g. `1` when an `11` label exists); `Cmd`/`Ctrl`/`Option` shortcuts and unrelated digits still pass through, but plain letters don't (use `Esc` to drop back to red mode and type).

If a third-party shortcut collides with an mMouse key (e.g. an app uses bare arrows or bare Enter), mMouse wins — that's the priority guarantee. Deactivate (`Cmd+;` or `Esc`) when you need the raw key in the foreground app.

## Config

File: `~/.mMouse.json` (created on first launch). The full default config, every field shown:

```json
{
  "activationCombo": {
    "modifier": "command",
    "key": ";",
    "repeatCount": 1,
    "windowMs": 500
  },
  "additionalActivationCombos": [],
  "keys": {
    "up": "up",
    "down": "down",
    "left": "left",
    "right": "right"
  },
  "speed": 3,
  "speedBoost": {
    "modifier": "option",
    "multiplier": 5
  },
  "grid": {
    "combo": { "modifier": "command", "key": "'" },
    "targetCellPx": 150,
    "customLabels": [
      { "cell": "FA", "label": "S1" },
      { "cell": "HA", "label": "S2" },
      { "cell": "JC", "label": "11" },
      { "cell": "LK", "label": "22" },
      { "cell": "WI", "label": "33" }
    ]
  }
}
```

Every field is optional on load — **tolerant decode** means a config written by an older version (missing newer fields) still loads, and the missing fields fall back to their defaults. You only need to include the fields you want to change.

> `grid.targetCellHeightPx` is an optional extra (not in the default file). When omitted, cells are square (height = `targetCellPx`). Set it *smaller* than the width to get wide, short cells — i.e. more rows. Handy on tall displays.

> The legacy `passthrough` whitelist field is no longer used and is silently ignored if present in older configs. mMouse now passes through everything not in its own key set — see the routing model section above.

### Parameters

| Field | Meaning | Value |
|---|---|---|
| `activationCombo.modifier` | Modifier held while entering the combo. Supports **combos** with `+` (e.g. `"command+shift"`) | `command` \| `control` \| `option` \| `shift` \| `none` \| or a combo |
| `activationCombo.key` | The main key | `a-z`, `0-9`, named key (`space`, `tab`, `f1`...`f12`, `escape`, arrow names, `;`, `,`, ...) |
| `activationCombo.repeatCount` | How many times the main key must be pressed | int ≥ 1 (default `1`) |
| `activationCombo.windowMs` | Max ms between presses (only used when `repeatCount > 1`) | int 50..5000 |
| `additionalActivationCombos` | Extra combos that also toggle red mode (single press each; `repeatCount`/`windowMs` ignored). E.g. add `Cmd+Q` alongside `Cmd+E`. | array of `{ modifier, key }` (default `[]`) |
| `keys.up/down/left/right` | Movement keys | key name (e.g. `"up"`, `"k"`) |
| `speed` | Movement speed | **int 1..10** |
| `speedBoost.modifier` | Modifier that boosts movement speed | modifier name |
| `speedBoost.multiplier` | Speed multiplier while boost modifier held | number (default `5`) |
| `grid.combo.modifier` | Modifier for the grid-layer trigger | modifier name (default `command`) |
| `grid.combo.key` | Key that turns the grid layer on | key name (default `'`) |
| `grid.targetCellPx` | Grid layer cell **width**; cols = round(displayWidth / this) | int 60..400 (default `150`) |
| `grid.targetCellHeightPx` | Optional cell **height**; rows = round(displayHeight / this). Omit for square cells | int 30..400 (default: same as width) |
| `grid.customLabels` | Pinned labels: each `{ cell, label }` renames a cell (by its default 2-letter `cell` code) to `label` (pink pill, typed to warp). `[]` disables all | array (default: 5 built-ins) |

> **Hardcoded** (not configurable): `Enter` / `Shift+Enter` (click), `Esc` (panic exit), `Shift + movement` (hold-to-drag), `Cmd + movement` (scroll). The movement keys must NOT collide with `Enter` — mMouse warns and disarms the colliding direction if you try. `speedBoost.modifier` should not include Cmd or be Shift exactly — those would silently lose to scroll / drag and never fire.

### Speed cheat sheet

Per-tick = `0.5 × speed²` px at 60 Hz baseline, modulated by an acceleration curve (tap stays slow, hold ramps to 2.5× after 400ms).

| Speed | Tap (~50ms) | Hold ~1s | Use case |
|---|---|---|---|
| 1 | ~1 px | ~50 px | Pixel-perfect precision |
| 3 (default) | ~4 px | ~400 px | Precise UI |
| 5 | ~10 px | ~1100 px | General use |
| 7 | ~20 px | ~2000 px | Big screens |
| 10 | ~50 px | ~4500 px | Fastest crossing |

**Speed boost** (default `Option`): hold the boost modifier + arrow → speed × 5 (configurable). Use it to cross the screen quickly without changing the base speed. Don't set this to Cmd (collides with scroll) or Shift (collides with drag).

### Example: activate with `Option + Space` (single press)

```json
"activationCombo": {
  "modifier": "option",
  "key": "space",
  "repeatCount": 1,
  "windowMs": 500
}
```

> ⚠️ `repeatCount: 1` means **a single press activates immediately**. If you're worried about clashing with another app's shortcut, use `repeatCount: 2` for a double-tap.

> ⚠️ Avoid combos macOS already uses (e.g. `Cmd+Shift+arrow` = Move to Desktop, `Cmd+Tab` = app switcher). The event tap consumes the combo so you'd lose the system function while mMouse is running.

### Modifier combo syntax

```json
"modifier": "command"           // 1 modifier
"modifier": "command+shift"     // 2 modifiers
"modifier": "ctrl+option+shift" // 3 modifiers
"modifier": "none"              // no modifier required (risky)
```

## Menu bar items

- **Activate / Deactivate** — manual toggle
- **Open Config** — open `~/.mMouse.json` in your default JSON editor
- **Reload Config** — force reload
- **Reveal in Finder** — show the config file in Finder
- **Quit mMouse**

## Trade-offs

- For multi-tap combos (`repeatCount > 1`), the first press is **always suppressed** (we don't know yet if it's the start of a sequence). If the follow-ups don't arrive within `windowMs`, the press is dropped. Single-press combos (`repeatCount: 1`, the default) don't have this trade-off.
- While active, only mMouse's own keys are intercepted: arrows (any modifier — movement / drag / scroll / boost), Enter / Shift+Enter (click / right-click), Esc (deactivate), and the activation combo. Every other key passes through to the foreground app unchanged. No whitelist to maintain.
- Click does not auto-exit the mode — press the activation combo again or `Esc` to leave.
- Because the real cursor moves while you aim, hover effects (tooltips, link previews, button highlights) will fire just like with a physical mouse. This is intentional: you see exactly what the click will hit.
- The activation, movement, and click handlers **cannot share keys**. mMouse warns and disarms the offender at config-load time.

## Stable signing cert (developer)

If you rebuild often, ad-hoc signing means re-granting Accessibility every install. Create a stable self-signed cert once and you never grant again:

```bash
make setup-cert        # one-time: create "mMouse Signing" cert in login keychain
make tcc-reset         # clear stale TCC entries for old ad-hoc identities
make install           # rebuild with the stable cert
open /Applications/mMouse.app
# Grant permission once — persists across all subsequent rebuilds.
```

Recovery one-liner: `make reinstall` (= `tcc-reset` + `install`).

Verify the installed bundle is signed with the stable cert:
```bash
make sign-info
```
Expected: `Authority=mMouse Signing` (not `Signature=adhoc`).

> macOS TCC binds a granted permission to the **code identity** of the binary. Ad-hoc sign produces a new identity per build → grant invalidated → re-prompt. A stable cert keeps the identity constant.

## Troubleshooting

### App prompts for permission every install

You're using ad-hoc signing. Either accept the re-grant, or set up the stable cert (see above).

### Tap disabled by secure input
While typing a sudo password in Terminal, macOS auto-disables all event taps. mMouse re-enables itself once secure input is released (health timer + inline retry).

### Tap dies after sleep/wake
mMouse listens for `NSWorkspace.didWakeNotification` and recreates the tap automatically. If it still doesn't work → menu bar → **Quit** → reopen.

### Stuck in active mode (activated but can't type)
Press `Esc` (or whatever your activation combo is) to deactivate. Or click the menu bar `🟢 mM` → **Deactivate** — the physical mouse still works for this even while active.

### After granting permission the alert keeps appearing
The app self-relaunches when it detects the grant. If it loops:
```bash
make tcc-reset
open /Applications/mMouse.app   # start fresh
```

## Build targets

```bash
make build         # swift build -c release (no bundle)
make bundle        # release build + .app bundle in .build/
make install       # bundle + copy to /Applications/ (quits running instance)
make run           # bundle + open from .build/
make clean         # rm .build, swift package clean
make sign-info     # show signing identity of installed/bundled .app
make setup-cert    # one-time: create stable signing cert
make tcc-reset     # clear TCC Accessibility entry for mMouse
make reinstall     # tcc-reset + install
```

## Architecture

```
AppDelegate (@main)         — wiring, Accessibility permission flow, self-relaunch
  ├── ConfigManager         — load/save/watch ~/.mMouse.json (file-level fswatch), hot-reload
  ├── MouseController       — CGEvent post (move/click/scroll/drag) directly on the real
  │                           cursor, sub-pixel accumulator, multi-monitor clamp, accel curve
  ├── EventTapManager       — CGEventTap + activation state machine + key routing +
  │                           drag/scroll bookkeeping + grid-jump modal
  │     ├── CursorBadge      — small red follow-dot shown while active
  │     └── GridOverlay      — full-screen labelled-matrix layer (grid jump)
  └── MenuBarManager        — NSStatusItem

Support: KeyMapping (key-name/modifier → keycode) · GridLabels (cell-code ↔ index,
         custom-label resolution, shared by the overlay and the event tap)
```

CGEventTap config: `.cghidEventTap` + `.headInsertEventTap` + `.defaultTap` (falls back to `.cgSessionEventTap` if the HID-level tap can't be created). Tapping at the HID level with head-insert puts mMouse *ahead* of the system's own hotkey handling, so the keys it claims win even over OS defaults (Spotlight, Cmd+Space, Cmd+Tab). Not sandboxed (required for `.defaultTap` to consume events). Callback runs on the main RunLoop — all mutable state is touched only on main, no locks.

Cursor movement is direct: each movement tick calls `CGWarpMouseCursorPosition` (which generates a `mouseMoved` event automatically). Clicks / drags / scrolls are dispatched at the current cursor position read via `CGEvent(source:nil)?.location` (with a `NSEvent.mouseLocation` fallback).
