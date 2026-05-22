# mMouse

Keyboard-driven cursor control for macOS. Goal: drop the physical mouse as much as possible.

## Features

- **Activation sequence**: press `Cmd + J + J` (J twice within 500ms) to toggle mMouse mode
- **Movement**: `h` `j` `k` `l` (vim style) — left / down / up / right
- **Click** *(hardcoded, not configurable)*:
  - `Enter` → left click
  - `Enter × 2` (twice within 400ms) → double click
  - `Shift + Enter` → right click
- **Scroll**: `Shift + movement_key` → scroll up/down/left/right at the aim position
- **Drag (block selection)**: `v` toggle → hold mouseDown at aim, move with arrows to select, press `v` again or `Enter` to commit mouseUp
- **🔒 Full keyboard lockdown** while active: every key that isn't movement / Enter / Shift+movement / `v` / activation combo is consumed — no shortcut leaks to other apps
- **Speed**: single integer 1..10 (1 = slow, 10 = fast)
- **Hot-reload** config when `~/.mMouse.json` changes
- **Multi-monitor**: cursor clamped to the active display
- Menu bar app (no Dock icon)

## Build

```bash
make setup-cert   # RUN ONCE: create a stable signing cert (see section below)
make bundle       # build release + assemble .app
make install      # copy to /Applications/ (quits any running instance)
make run          # build and open the app from .build/
```

Requirements: Xcode Command Line Tools (Swift 5.9+), `openssl` (bundled with macOS), and macOS 13+.

## Standard setup (one time)

```bash
make setup-cert   # create the "mMouse Signing" cert in the login keychain
make install      # build + install to /Applications
open /Applications/mMouse.app
```

First launch:
1. The app shows an alert requesting Accessibility → click **Open System Settings**.
2. Enable the toggle for `mMouse` under **Privacy & Security → Accessibility**.
3. The app **relaunches itself** automatically once the permission is detected → tap is live.

> 🔑 **Why a stable cert?**
>
> macOS TCC (the permissions system) binds a granted permission to the **code identity** of the binary. An ad-hoc signed app (`codesign --sign -`) gets a new identity on every codesign run → the previous grant becomes invalid → you have to grant again on every rebuild.
>
> A stable self-signed cert (`make setup-cert`) gives you a stable identity → grant once, keep it.

## Usage

| Action | Keys |
|---|---|
| **Enable mMouse** | `Cmd + J + J` |
| **Disable mMouse** (manual) | `Cmd + J + J` or `Esc` |
| Up | `k` |
| Down | `j` |
| Left | `h` |
| Right | `l` |
| Left click | `Enter` (mode stays active — keep interacting) |
| Double click | `Enter × 2` (within 400ms) |
| Right click | `Shift + Enter` |
| Scroll up | `Shift + k` (hold for continuous scroll) |
| Scroll down | `Shift + j` |
| Scroll left | `Shift + h` |
| Scroll right | `Shift + l` |
| **Drag start / end (block selection)** | `v` (vim visual mode) |
| End drag (alt) | `Enter` |
| **Panic exit** (escape hatch when stuck) | `Esc` (auto-commits an in-progress drag) |

> 💡 **Sticky active mode**: mMouse does **not** auto-deactivate after a click — the cursor stays where it is and you can keep moving / clicking / scrolling. To exit, use the activation combo again or `Esc`.

> 📜 **Scroll**: hold `Shift + arrow` → posts a scroll wheel event at the aim position. The real cursor warps to the aim before scrolling (so the event lands on the window under the aim). Hold ramp-up: 0.1s → 1×, 0.5s → 3×.

> 🎯 **Drag (block selection)**: press `v` to start drag (mouseDown at the aim). The overlay hides — the **system cursor reappears** so you can see the selection rectangle apps draw. Move with arrows to drag. Press `v` again, `Enter`, or `Esc` to commit the mouseUp. Inside drag mode, `Shift + arrow` is still drag-move (not scroll) — Shift is passed through to the app so things like Shift+drag to extend a selection in a text editor work as expected.

Menu bar:
- `⚪ mM` — inactive (typing works normally)
- `🟢 mM` — active (every other key is locked; only the keys above do anything)

### Why lock down every key?

To **prevent conflicts** with other apps' shortcuts. Example: if you accidentally press `w` while active and we didn't lock keys, Cmd+W (if Cmd happens to be held) would close a tab. Lockdown guarantees active mode is **pure mouse mode** — nothing else leaks through.

Want to type → deactivate first (`Cmd+J+J`).

## Config

File: `~/.mMouse.json` (created on first launch).

```json
{
  "activationCombo": {
    "modifier": "command",
    "key": "j",
    "repeatCount": 2,
    "windowMs": 500
  },
  "keys": {
    "up": "k",
    "down": "j",
    "left": "h",
    "right": "l"
  },
  "speed": 5
}
```

### Parameters

| Field | Meaning | Value |
|---|---|---|
| `activationCombo.modifier` | Modifier held while entering the combo. Supports **combo modifiers** with `+` (e.g. `"command+shift"`) | `command` \| `control` \| `option` \| `shift` \| `none` \| or a combo like `"a+b"` |
| `activationCombo.key` | The main key of the combo | `a-z`, `0-9`, or a named key (`space`, `tab`, `f1`...`f12`, `escape`, ...) |
| `activationCombo.repeatCount` | How many times the main key must be pressed (e.g. 2 = double-tap) | int ≥ 1 |
| `activationCombo.windowMs` | Max milliseconds between presses | ms |
| `keys.up/down/left/right` | Movement keys | key name (e.g. `"up"`, `"down"`, `"k"`, `"j"`...) |
| `speed` | Movement speed | **int 1..10** (see table below) |
| `speedBoost.modifier` | Modifier held with a movement key to boost speed | modifier name (e.g. `"command"`, `"option"`, `"command+shift"`) |
| `speedBoost.multiplier` | Speed multiplier while the boost modifier is held | number (default `5`) |

### Speed cheat sheet (quadratic curve + acceleration)

| Speed | Tap (~50ms) | Hold 1s | Use case |
|---|---|---|---|
| 1 | ~1 px | ~80 px | Pixel-perfect precision |
| 3 (default) | ~4 px | ~340 px | Text-cursor-like, precise UI |
| 5 | ~12 px | ~940 px | General use |
| 7 | ~25 px | ~1800 px | Big screens |
| 10 | ~50 px | ~3750 px | Fastest crossing |

**Acceleration**: a quick tap moves only a little (0.3×), holding the key ramps up to 2.5× after 400ms. Feels like a real mouse — tap to fine-tune, hold for long traversals.

**Speed boost** (default Cmd): hold Cmd + arrow → speed × 5 (configurable via `speedBoost.multiplier`). Lets you cross the screen quickly without changing the base speed in config.

**Auto-center on activate**: each time you activate, the **aim overlay** (a small cursorarrow icon) appears at the center of the current display → a consistent starting point.

### Cursor overlay mode

While active, mMouse **does not move the real cursor** (the system cursor stays parked where it was). Instead a **floating icon** (the "aim") moves with the keys.

- Movement keys (arrows) → move the aim icon
- `Enter` / `Shift+Enter` → real cursor **warps to the aim position** and clicks immediately

Benefits:
- The aim does not trigger hover effects (tooltips, highlights) while you're positioning
- Clear visual feedback — you always know where the cursor will land
- "Snap" clicks feel more precise

Edit the file → save → mMouse reloads automatically, no restart needed.

### Example: activate with `Cmd + Shift + →` (single press)

```json
"activationCombo": {
  "modifier": "command+shift",
  "key": "right",
  "repeatCount": 1,
  "windowMs": 500
}
```

> ⚠️ `repeatCount: 1` means **a single press activates immediately**. Safer to use `repeatCount: 2` (double-tap) if your combo overlaps with another app's shortcut.

### Other combo examples

```json
"modifier": "command"           // 1 modifier
"modifier": "command+shift"     // 2 modifiers
"modifier": "ctrl+option+shift" // 3 modifiers
"modifier": "none"              // no modifier required (risky)
```

> Click keys (Enter / Shift+Enter) are **hardcoded** — they are not in the config.

## Menu bar items

- **Activate / Deactivate** — manual toggle
- **Open Config** — open `~/.mMouse.json`
- **Reload Config** — force reload
- **Reveal in Finder** — show the config file in Finder
- **Quit mMouse**

## Trade-offs to be aware of

- The first `Cmd+J` press in the sequence is **always suppressed**. If a second J doesn't follow within 500ms, that first press is dropped (it never reaches the app underneath).
- While active: **every key** is locked except h/j/k/l/Shift+(h/j/k/l)/Enter/Shift+Enter/`v`/activation. Cmd+Tab, Cmd+Q, typing — all consumed.
- Click does not auto-exit the mode — press the activation combo again or `Esc` to leave.

## Troubleshooting

### App prompts for permission every time it launches

This is the ad-hoc TCC problem. Permanent fix:

```bash
make setup-cert        # create a stable cert (run once)
make tcc-reset         # clear stale TCC entries for mMouse
make install           # rebuild + reinstall with the new cert
open /Applications/mMouse.app
# Grant permission again — this time it persists.
```

Recovery one-liner: `make reinstall` (= `tcc-reset` + `install`).

Check the current signing identity:
```bash
make sign-info
```
Expected output: `Authority=mMouse Signing` (not `Signature=adhoc`).

### Tap disabled by secure input
While typing a sudo password in Terminal, macOS auto-disables event taps. mMouse re-enables itself once secure input is released.

### Tap dies after sleep/wake
mMouse listens for `NSWorkspace.didWakeNotification` and recreates the tap. If it still doesn't work → menu bar → **Quit** → reopen.

### Stuck in active mode (activated but can't type)
Press `Cmd+J+J` to deactivate. Or click the menu bar `🟢 mM` → **Deactivate** (the physical mouse still works either way).

### After granting permission, the alert still appears
The app relaunches itself once the permission is detected. If it still loops:
```bash
make tcc-reset
open /Applications/mMouse.app   # start fresh
```

## Architecture

```
AppDelegate (@main)
  ├── ConfigManager       — load/save/watch ~/.mMouse.json
  ├── MouseController     — CGEvent post, sub-pixel accumulator, multi-monitor clamp
  ├── EventTapManager     — CGEventTap + sequence state machine + lockdown
  └── MenuBarManager      — NSStatusItem
```

CGEventTap: `.cgSessionEventTap` + `.headInsertEventTap` + `.defaultTap`. Not sandboxed (required for `.defaultTap` to consume events).
