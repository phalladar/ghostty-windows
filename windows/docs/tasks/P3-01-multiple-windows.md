# P3-01 — Multiple windows, window focus tracking, quit semantics

**Phase:** P3 · **Depends on:** P1-05, P2-03 · **Size:** M ·
**Touches:** `src/apprt/win32/{App,Window}.zig`.

## Goal

`ctrl+shift+n` opens a second window that inherits the focused
surface's cwd and config; each window closes independently; the app
quits when the last window closes (or after the configured quit timer);
`goto_window` cycles windows; `close_all_windows` and quit confirmation
work when processes are running.

## Read before starting (~250 lines)

- `src/App.zig:300-330` (`closeSurface`, `focusSurface`, `newWindow`
  with `Message.NewWindow.parent`), `:256-262` (`needsConfirmQuit`),
  `:436-470` (`performAction` app-level dispatch).
- `src/apprt/surface.zig:160-240` (`NewSurfaceContext`, `newConfig`:
  how the parent surface's pwd/font size are inherited).
- `src/apprt/gtk/class/application.zig`: grep `new_window`, `goto_window`,
  `close_all_windows`, `quit_timer`, `confirm_quit` for the reference
  behaviour and dialog text.
- `src/config/Config.zig`: grep `quit-after-last-window-closed`,
  `confirm-close-surface`, `window-inherit-working-directory`,
  `window-inherit-font-size`, `window-new-tab-position` (not used yet).
- `src/apprt/win32/App.zig` and `Window.zig` as they stand.
- `src/Surface.zig:1855-1895` (`recomputeInitialSize`: only fires when
  `window-width`/`window-height` are set).

## Steps

1. Keep a `std.ArrayList(*Window)` in `App` with insertion order; track
   the last-active window from `WM_ACTIVATE`.
2. `new_window` action: for a `.surface` target, build the new surface
   via `newConfig(core_app, &config, .{ .parent = target_surface })`;
   for `.app`, no parent. Place the new window offset from the last
   active one (`CW_USEDEFAULT` is acceptable in v1).
3. `close_window`: close every surface in the target window (one for
   now), then destroy the window.
4. Quit: when the window list becomes empty, if
   `quit-after-last-window-closed` is false, `PostQuitMessage`; else the
   `quit_timer` action logic from P1-01 takes over. The `quit` action:
   if `core_app.needsConfirmQuit()`, show a Yes/No `MessageBoxW`
   ("Quit Ghostty? … processes still running"), then close all windows.
5. `goto_window`: `.previous`/`.next`/`.last`/index → `SetForegroundWindow`.
   `close_all_windows`: confirm if needed, then close each.
6. `present_terminal` for a surface in a non-active window brings that
   window forward.
7. Alt+F4 vs `ctrl+shift+w` (`close_surface`) both go through the same
   confirm path (`confirm-close-surface`).

## Acceptance

- Two windows, each with its own shell; closing one leaves the other
  responsive; closing the last exits the process (exit code 0).
- With `--quit-after-last-window-closed=true --quit-after-last-window-closed-delay=5s`
  (check the exact option names), the process lingers 5 s then exits;
  opening a window within that time cancels the exit.
- Quit while `ping -t` runs prompts for confirmation; No keeps it open.
- Handle count and thread count return to baseline after closing
  windows (Task Manager or `Get-Process ghostty | Select Handles,Threads`).

## Gotchas

- `MessageBoxW` re-enters the message loop; state can change while it is
  up (a surface may exit). Re-check the window still exists after it
  returns before touching it.
- `WM_ACTIVATE` fires for the message-only window? No, but it fires for
  every top-level; use `LOWORD(wParam) != WA_INACTIVE`.
- Do not `PostQuitMessage` from inside `tick` while windows still have
  pending `WM_DESTROY`; destroy first, then post on the next tick.
- The `quit` and `close_all_windows` actions can arrive inside `core_app.tick`
  or a key handler; the confirmation `MessageBoxW` runs from a message posted
  to the message-only window so the dialog never nests inside `tick`.
- The core only fires `initial_size` when `window-width`/`window-height` are
  set. Otherwise `Window.place` sizes the window to 80x24 cells from
  `core_surface.size.cell` plus the configured padding, capped to the work
  area, and cascades 32 px (DPI-scaled) from the last active window.
- `SetForegroundWindow` (goto_window) only works while Ghostty is the
  foreground app; when another app is foreground Windows refuses it (focus
  stealing prevention), so live tests must check the foreground first.
- Opening a window during the quit-after-last-window-closed delay needs an
  external trigger (IPC, P4-05); the timer stop path is `addSurface`.
- Posted `WM_KEYDOWN VK_PACKET` did not produce text in live tests; to set
  a cwd for inheritance tests, run a `--command` script that emits OSC 7.

## Out of scope

Tabs (P3-02), splits (P3-03), remembering window positions.

## Wrap-up

Tick P3-01.
