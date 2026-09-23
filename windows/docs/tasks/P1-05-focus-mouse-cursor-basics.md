# P1-05 — Focus, occlusion, mouse basics, cursor shape and visibility

**Phase:** P1 · **Depends on:** P1-02 · **Size:** M ·
**Touches:** `src/apprt/win32/{Surface,Window,App,c}.zig`.

## Goal

Clicking focuses the surface and the blinking cursor follows focus,
mouse position/buttons/wheel reach the core (so scrollback scrolls and
click-to-select works), the mouse pointer shape follows the core's
`mouse_shape` action, and the pointer hides while typing if configured.

## Read before starting (~250 lines)

- `windows/docs/06-apprt-contract.md`: `mouseButtonCallback`,
  `cursorPosCallback`, `scrollCallback`, `focusCallback`,
  `occlusionCallback`, `getCursorPos`, and actions `mouse_shape`,
  `mouse_visibility`, `present_terminal`.
- `src/input/mouse.zig:20-100` (`MouseButton`, `ButtonState`, `ScrollMods`).
- `src/terminal/mouse.zig:1-90` (`MouseShape` enum; the `app_runtime`
  switch at `:84` you already added a prong to).
- `src/apprt/gtk/class/surface.zig:2769-2900` (mouse press/release/motion/
  scroll handlers: what they pass to the core, in particular scroll
  sign and `precision`).
- `src/Surface.zig:3820-3840` (`mouseButtonCallback` signature),
  `:4562-4580` (`cursorPosCallback`), `:3486-3500` (`scrollCallback`),
  `:3368-3380` (`focusCallback`), `:3339-3350` (`occlusionCallback`).
- `src/apprt/embedded.zig:1050-1120` (compact reference for the same).

## Design

- **Focus:** child `WM_SETFOCUS` → `focusCallback(true)` and
  `app.core_app.focusEvent(true)`; `WM_KILLFOCUS` → both `false`.
  Top-level `WM_ACTIVATE` → `SetFocus(surface_hwnd)` on activation so
  clicking the title bar re-focuses the terminal. `WM_LBUTTONDOWN` on the
  child → `SetFocus(self.hwnd)` before forwarding.
- **Mouse position:** `WM_MOUSEMOVE` → store `cursor_pos` (client px as
  f32) → `cursorPosCallback(pos, mods)`; call `TrackMouseEvent(TME_LEAVE)`
  once per enter; `WM_MOUSELEAVE` → `cursorPosCallback(.{-1,-1})`.
- **Buttons:** `WM_LBUTTONDOWN/UP` → button 1, `WM_RBUTTONDOWN/UP` → 2,
  `WM_MBUTTONDOWN/UP` → 3, `WM_XBUTTONDOWN/UP` (`HIWORD(wParam)` 1/2) →
  4/5 or whatever `MouseButton` numbering says for back/forward. Call
  `SetCapture` on any down and `ReleaseCapture` when the last button
  goes up so drags outside the window continue. Mods from `GetKeyState`
  (reuse `key.zig`'s helper).
- **Wheel:** `WM_MOUSEWHEEL` → `yoff = delta / 120.0` (positive = up);
  `WM_MOUSEHWHEEL` → `xoff = delta / 120.0`; `ScrollMods{ .precision = false }`.
  Coordinates in wheel messages are screen-relative; ignore them.
  Precision touchpads deliver small deltas; pass them through as
  fractions (the core accumulates).
- **Cursor shape:** handle `mouse_shape` action by storing an `HCURSOR`
  (`LoadCursorW(null, IDC_ARROW/IDC_IBEAM/IDC_HAND/IDC_SIZEWE/IDC_SIZENS/IDC_CROSS/IDC_NO/IDC_WAIT...)`
  mapped from `MouseShape`; apply it in `WM_SETCURSOR` when `LOWORD(lParam) == HTCLIENT`.
- **Cursor visibility:** `mouse_visibility` → store a flag; in
  `WM_SETCURSOR` set a null cursor when hidden; unhide on `WM_MOUSEMOVE`
  (the core sends `visible` again anyway).
- **`present_terminal`:** `SetForegroundWindow(top)` + `SetFocus(child)`.
- **Occlusion:** already in P1-02 for minimise; also treat
  `WM_SHOWWINDOW` hide as `false`.

## Steps

1. Externs: `SetFocus`, `GetFocus`, `SetCapture`, `ReleaseCapture`,
   `TrackMouseEvent` + `TRACKMOUSEEVENT`, `SetCursor`, `LoadCursorW`,
   `SetForegroundWindow`, `GetSystemMetrics`; messages `WM_MOUSEMOVE`,
   `WM_MOUSELEAVE`, `WM_*BUTTON*`, `WM_MOUSEWHEEL`, `WM_MOUSEHWHEEL`,
   `WM_SETCURSOR`, `WM_ACTIVATE`, `WM_SHOWWINDOW`; `IDC_*` as
   `MAKEINTRESOURCE` integers (e.g. `IDC_ARROW = 32512`).
2. Implement the handlers in the child WndProc; keep them short and
   forward to helper functions on `Surface`.
3. Implement the three actions in `App.performAction`.
4. Manual: click-drag selects text (highlight visible), wheel scrolls
   scrollback after `Get-ChildItem C:\Windows\System32`, shift+wheel or
   in `less` (Git Bash) mouse reporting scrolls the pager, pointer becomes
   an I-beam over the terminal, the pointer hides while typing when
   `mouse-hide-while-typing = true` is passed.

## Acceptance

- All four manual checks pass.
- Alt-tabbing away and back stops and resumes cursor blink (focus events).
- Minimising and restoring does not leave a black window (occlusion).
- Debug log shows no `mouseButtonCallback` errors.

## Gotchas

- `WM_MOUSEWHEEL` `wParam` delta is a signed 16-bit in the high word;
  extract with `@as(i16, @truncate(@as(u32, @truncate(wParam >> 16))))`.
- `WM_XBUTTON*` must return `TRUE` to indicate handling.
- `SetCapture` changes which window gets `WM_MOUSEMOVE`; coordinates
  stay child-relative, possibly negative; the core handles that.
- `WM_SETCURSOR` fires constantly; keep the handler allocation-free.
- Double/triple click detection is done by the core using
  `internal_os.clickInterval` (null on Windows today). P2-02 adds
  `GetDoubleClickTime`; until then multi-click may feel off.
- The core sets `mouse_shape = .default` (arrow) while the program has
  mouse reporting on; an arrow over the terminal is then correct, not a bug.
- Focus is delivered to the core from a posted `WM_APP + 0x50` on the
  child, not inline in `WM_SETFOCUS`/`WM_KILLFOCUS` (same reason GTK uses an
  idle callback: `MessageBox` inside a core callback changes focus).
- A child reading mouse input under ConPTY must enable
  `ENABLE_VIRTUAL_TERMINAL_INPUT` (0x200) with `SetConsoleMode`, or ConPTY
  turns the SGR sequences into `MOUSE_EVENT` records.
- `key.zig` has no public mods helper; mouse mods come from `MK_SHIFT`/
  `MK_CONTROL` in `wParam` plus `GetKeyState(VK_MENU/VK_LWIN/VK_RWIN)`.
- Injected `XBUTTON` events are also seen by global hooks on the machine
  (foreground was lost once after X1); test them sparingly.

## Out of scope

Precision/momentum scrolling tuning, double-click interval, link
hover/open, selection to clipboard (P2-02, P2-03, P2-05).

## Wrap-up

Tick P1-05. This completes phase P1: update the STATUS.md phase summary.
