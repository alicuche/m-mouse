# mMouse — project guide for Claude

Keyboard-driven cursor control for macOS (menu-bar app, Swift/AppKit, CGEventTap).

## ALWAYS build + install after writing code (so the user can test immediately)

When you finish a code change, do **not** stop at `swift build`. Always rebuild the
real app bundle and reinstall it so the running instance reflects the change right away:

```bash
make install
```

`make install` builds release, bundles `mMouse.app`, quits the running instance, copies
to `/Applications`, and relaunches it. After it finishes, tell the user it's live and
ready to test.

- Use `make reinstall` (= `tcc-reset` + `install`) if the user reports the new build is
  asking for Accessibility again or behaving as if the old code is still running — it
  resets the TCC grant for a clean re-grant.
- Ad-hoc signing means each rebuild is a new code identity → macOS may re-prompt for
  Accessibility. If that becomes annoying during iteration, see the stable signing cert
  section in `README.md`.
- This applies even for "one-line" changes — a build alone does not update the app the
  user is testing.

## Where code lives

This is a git worktree (`Personal-mMouse-epic`). Make all code changes here, never in any
production checkout. Build/test here, then merge to `main`.

## Architecture (quick map)

- `EventTapManager.swift` — the CGEventTap callback (runs on main RunLoop); activation
  state machine, active-mode key routing, grid-jump modal, drag/scroll bookkeeping.
- `MouseController.swift` — warps the real system cursor; click/scroll/drag/`warp(to:)`.
- `CursorBadge.swift` — small follow-dot shown while active (NS/CG coord conversion lives here).
- `GridOverlay.swift` — full-screen labelled-matrix layer (grid jump). Opt-in on top of
  red mode via Cmd+'; while it's on, bare letters warp the cursor to a cell. Esc peels the
  layer off first, then red mode (`gridShown` vs `isActive` in EventTapManager).
- `Config.swift` — `~/.mMouse.json`, tolerant decode (`decodeIfPresent`), hot-reload.
- `KeyMapping.swift` — key-name / modifier-name → keycode.
- `AppDelegate.swift` — wiring, Accessibility permission flow, self-relaunch.

## Conventions

- The event-tap callback assumes the **main thread**; mutable state is touched only from
  main (no locks). UI calls from the callback use `MainActor.assumeIsolated { ... }`.
- New config fields must decode with `decodeIfPresent ?? .default` so older configs keep
  loading. Clamp ranges in `ConfigManager.loadConfig`.
- Coordinate spaces: CG = top-left origin (cursor/warp/CGEvent); NS = bottom-left origin
  (NSPanel/drawing). Flip Y via the primary display height — follow the pattern in
  `CursorBadge.panelOriginForCursor` / `GridOverlay.nsFrame`.
</content>
