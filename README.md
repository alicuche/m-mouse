# mMouse

Keyboard-driven cursor control for macOS. Goal: drop the physical mouse as much as possible.

## Features

- **Activation**: `Cmd + ;` toggles mMouse mode (single press by default; configurable)
- **Direct cursor control**: arrow keys move the real system cursor — what you see is what gets clicked
- **Click** *(hardcoded)*:
  - `Enter` → left click
  - `Enter × 2` (twice within 400ms) → double click
  - `Shift + Enter` → right click
- **Scroll** *(hardcoded)*: `Shift + movement_key` → scroll wheel events at the cursor
- **Drag / block selection** *(hardcoded)*: `v` toggles drag mode (mouseDown), arrows drag, `v` / `Enter` commits mouseUp
- **🔒 Full keyboard lockdown** while active: every key not listed above is consumed — no shortcut leaks to other apps
- **Speed**: integer 1..10 (default 3); quadratic curve + acceleration on hold
- **Speed boost**: hold `Cmd` (configurable) while moving → 5× speed
- **Hot-reload** config — edit `~/.mMouse.json`, save, no restart
- **Multi-monitor**: cursor clamped to the active display
- Menu bar app (no Dock icon)

## Install (end users)

```bash
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
| **Enable / disable mMouse** | `Cmd + ;` |
| Up | `↑` |
| Down | `↓` |
| Left | `←` |
| Right | `→` |
| Left click | `Enter` (mode stays active) |
| Double click | `Enter × 2` (within 400ms) |
| Right click | `Shift + Enter` |
| Scroll up | `Shift + ↑` (hold for continuous scroll) |
| Scroll down | `Shift + ↓` |
| Scroll left | `Shift + ←` |
| Scroll right | `Shift + →` |
| **Drag start / end** (toggle) | `v` |
| End drag (alt) | `Enter` |
| **Hold-to-drag** (screenshot-tool style) | `Option + arrow` (drag while held, release Option = mouseUp) |
| Speed boost (5× by default) | hold `Cmd` while moving |
| **Panic exit** | `Esc` (auto-commits drag if in progress) |

Menu bar:
- `⚪ mM` — inactive (typing works normally)
- `🟢 mM` — active (every other key is locked; only the keys above do anything)

### How it works in active mode

- The **real system cursor** is what moves. Arrow keys warp it; the cursor you see is the cursor that will click. No floating overlay, no aim icon.
- `Enter` posts a left click at the cursor's current position.
- `Shift + Enter` opens a context menu where the cursor is.
- After clicking, mMouse stays active — keep moving / clicking / scrolling. Press the activation combo or `Esc` to exit.

### Drag (block selection)

Two ways to drag:

**Toggle drag (`v`)** — vim-style, hands-free for long/precise drags.
- Press `v` to start drag (mouseDown at the current cursor).
- Arrow keys move the cursor and post `mouseDragged` events each tick.
- Press `v` again, `Enter`, or `Esc` to commit the `mouseUp`.

**Hold-to-drag (`Option + arrow`)** — screenshot-tool style, momentary.
- Hold `Option` then press an arrow to start drag (mouseDown).
- Keep `Option` held while arrows move the cursor — the drag continues.
- Release `Option` → mouseUp commits the drag. (Releasing an arrow without releasing Option keeps the mouse held down — useful when you want to pause mid-drag.)
- Perfect for selecting a screenshot region after `Cmd+Shift+4`, lasso-selecting files in Finder, or any "mouse-down + move + release" gesture.

In either mode, `Shift + arrow` is still drag-move (NOT scroll). Shift passes through to the app, so e.g. Shift+drag to extend a text-editor selection still works.

### Why lock down every key?

To **prevent conflicts** with other apps' shortcuts. If we didn't lock keys and you accidentally pressed `w` while Cmd happened to be held, Cmd+W would close a tab. Lockdown guarantees active mode is **pure mouse mode**.

Want to type → deactivate first (`Cmd+;`).

## Config

File: `~/.mMouse.json` (created on first launch).

```json
{
  "activationCombo": {
    "modifier": "command",
    "key": ";",
    "repeatCount": 1,
    "windowMs": 500
  },
  "keys": {
    "up": "up",
    "down": "down",
    "left": "left",
    "right": "right"
  },
  "speed": 3,
  "passthrough": [
    { "modifier": "command", "key": "c" },
    { "modifier": "command", "key": "v" },
    { "modifier": "command", "key": "x" },
    { "modifier": "command", "key": "a" },
    { "modifier": "command", "key": "z" },
    { "modifier": "command", "key": "tab" }
  ]
}
```

> `speedBoost` is also configurable but omitted from the default JSON (defaults to `{ modifier: "command", multiplier: 5 }`). Add it to override.

> `passthrough` is the **whitelist of shortcuts allowed to leak through to the foreground app even while mMouse is active**. The default list covers clipboard, undo, and app switcher (Cmd+C/V/X/A/Z/Tab). Add your own entries — e.g. `{ "modifier": "command", "key": "s" }` to keep Save working in active mode. Set `"passthrough": []` to lock down every non-mMouse key (the original v1 behavior).

### Parameters

| Field | Meaning | Value |
|---|---|---|
| `activationCombo.modifier` | Modifier held while entering the combo. Supports **combos** with `+` (e.g. `"command+shift"`) | `command` \| `control` \| `option` \| `shift` \| `none` \| or a combo |
| `activationCombo.key` | The main key | `a-z`, `0-9`, named key (`space`, `tab`, `f1`...`f12`, `escape`, arrow names, `;`, `,`, ...) |
| `activationCombo.repeatCount` | How many times the main key must be pressed | int ≥ 1 (default `1`) |
| `activationCombo.windowMs` | Max ms between presses (only used when `repeatCount > 1`) | int 50..5000 |
| `keys.up/down/left/right` | Movement keys | key name (e.g. `"up"`, `"k"`) |
| `speed` | Movement speed | **int 1..10** |
| `speedBoost.modifier` | Modifier that boosts movement speed | modifier name |
| `speedBoost.multiplier` | Speed multiplier while boost modifier held | number (default `5`) |
| `passthrough` | Array of `{modifier, key}` combos that pass through to the foreground app in active mode | array (default = Cmd+C/V/X/A/Z); `[]` = lock down everything |

> **Hardcoded** (not configurable): `Enter` / `Shift+Enter` (click), `v` (drag toggle), `Esc` (panic exit), `Shift + movement` (scroll). The movement keys must NOT collide with `v` or `Enter` — mMouse warns and disarms the colliding direction if you try.

### Speed cheat sheet

Per-tick = `0.5 × speed²` px at 60 Hz baseline, modulated by an acceleration curve (tap stays slow, hold ramps to 2.5× after 400ms).

| Speed | Tap (~50ms) | Hold ~1s | Use case |
|---|---|---|---|
| 1 | ~1 px | ~50 px | Pixel-perfect precision |
| 3 (default) | ~4 px | ~400 px | Precise UI |
| 5 | ~10 px | ~1100 px | General use |
| 7 | ~20 px | ~2000 px | Big screens |
| 10 | ~50 px | ~4500 px | Fastest crossing |

**Speed boost** (default `Cmd`): hold the boost modifier + arrow → speed × 5 (configurable). Use it to cross the screen quickly without changing the base speed.

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
- While active: **every key** is locked except movement / Shift+movement / Enter / Shift+Enter / `v` / `Esc` / activation. Cmd+Tab, Cmd+Q, typing — all consumed.
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
AppDelegate (@main)
  ├── ConfigManager       — load/save/watch ~/.mMouse.json (file-level fswatch)
  ├── MouseController     — CGEvent post (move/click/scroll/drag) directly
  │                         on the real cursor, sub-pixel accumulator,
  │                         multi-monitor clamp, acceleration curve
  ├── EventTapManager     — CGEventTap + activation state machine + key
  │                         lockdown + drag mode toggle
  └── MenuBarManager      — NSStatusItem
```

CGEventTap config: `.cgSessionEventTap` + `.headInsertEventTap` + `.defaultTap`. Not sandboxed (required for `.defaultTap` to consume events). Callback runs on the main RunLoop — all mutable state is touched only on main, no locks.

Cursor movement is direct: each movement tick calls `CGWarpMouseCursorPosition` (which generates a `mouseMoved` event automatically). Clicks / drags / scrolls are dispatched at the current cursor position read via `CGEvent(source:nil)?.location` (with a `NSEvent.mouseLocation` fallback).
