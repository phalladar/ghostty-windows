# P3-02 — Tabs: a tab strip per window, multiple surfaces, tab keybinds

**Phase:** P3 · **Depends on:** P3-01 · **Size:** L ·
**Touches:** `src/apprt/win32/{Window,Surface,App,c}.zig`, new `src/apprt/win32/TabBar.zig`.

## Goal

`ctrl+shift+t` opens a new tab in the current window; tabs show titles;
clicking switches; `ctrl+tab`/`ctrl+shift+tab`/`ctrl+<n>` (as bound in
the default config) switch; `move_tab`, `close_tab`, `set_tab_title`
work; the window title follows the active tab; closing the last tab
closes the window.

## Decision

Use a **custom-drawn tab bar** (GDI, one child HWND of the top-level
window) rather than `SysTabControl32`: the common control does not
support dark mode, close buttons, or custom heights, and every terminal
on Windows ends up custom-drawing. Keep it minimal: fixed height
(scaled by DPI), equal-width tabs with ellipsised titles, a close glyph,
a "+" button, active/inactive colours derived from the config background
(same luminance logic as P2-05). Hidden when only one tab is open if
`window-show-tab-bar = auto` (check the option name in `Config.zig`).

## Read before starting (~300 lines)

- `src/apprt/gtk/class/window.zig`: grep `new_tab`, `close_tab`,
  `goto_tab`, `move_tab`, `selected_page`, `tab_bar` for the semantics and
  edge cases (closing the active tab selects which neighbour;
  `window-new-tab-position`).
- `src/apprt/gtk/class/tab.zig:1-120` (what a tab owns; title fallback rules).
- `src/apprt/action.zig`: `GotoTab`, `MoveTab`, `CloseTabMode`, `SetTitle`
  (grep the names).
- `src/config/Config.zig`: grep `window-show-tab-bar`, `window-new-tab-position`,
  `keybind` defaults for `ctrl+shift+t`, `ctrl+tab`, `goto_tab` (search
  `goto_tab` in the default keybinds block).
- `src/apprt/surface.zig:160-240` (`NewSurfaceContext` with `.tab`).
- P3-01's `Window.zig`.
- `src/config/Config.zig` ~6790-6860 and ~7015-7080 (default tab binds:
  `alt+N` goto_tab, `ctrl+shift+w` close_tab, pgup/pgdn move_tab).
- `src/Surface.zig` `closingAction` (grep): `close_tab` makes `keyCallback`
  return `.closed`.

## Steps

1. `Window` owns `tabs: ArrayList(*Surface)` and `active: usize`. Layout in
   `WM_SIZE`: tab bar (if visible) on top, the active surface fills the
   rest; inactive surfaces are `ShowWindow(SW_HIDE)` (their renderer
   threads keep running but the core pauses on `occlusionCallback(false)`;
   send that).
2. `TabBar.zig`: child HWND, `WM_PAINT` with double-buffered GDI
   (`CreateCompatibleDC`, `BitBlt`), `WM_LBUTTONDOWN` hit-test → activate
   or close, `WM_MOUSEMOVE` hover state, `WM_MBUTTONUP` closes, `WM_DPICHANGED`
   propagation. Font: `CreateFontW` from `SystemParametersInfoW(SPI_GETNONCLIENTMETRICS)`
   caption font scaled to DPI.
3. Actions: `new_tab` (parent context `.tab`), `close_tab` (`this`/`other`
   modes), `goto_tab` (`previous`/`next`/`last`/`n`), `move_tab`, `set_tab_title`
   (override), `toggle_tab_overview` → false.
4. Window title = active tab title (or `set_window_title` override).
5. Focus: activating a tab `SetFocus`es its surface and calls
   `focusCallback(true)` on it and `false` on the previous one.
6. Drag-to-reorder: optional; skip unless under 60 lines.

## Acceptance

- Open five tabs, cycle with `ctrl+tab`, jump with `ctrl+3`, close with
  `ctrl+shift+w` and middle-click; the active tab after closing follows
  GTK's rule.
- Tab titles update from the shell (OSC 2) and from `set_tab_title`.
- Hidden tabs do not burn CPU (renderer paused; check Task Manager GPU/CPU).
- DPI change re-lays out the tab bar and surfaces.

## Gotchas

- Hidden child windows still receive `WM_SIZE` when the parent resizes
  only if you resize them; keep all surfaces sized to the content rect
  so switching is instant.
- `SetFocus` on a hidden window fails; activate before focusing.
- Painting text with GDI on a dark background: `SetBkMode(TRANSPARENT)`.
- Keep colour math in one helper shared with P2-05.
- (P3-02 result) Default binds on Windows/Linux: `goto_tab:N` is `alt+N`
  (not `ctrl+N`), `alt+9` is `last_tab`; `ctrl+shift+w` is `close_tab:this`
  (it overrides `close_surface`); `ctrl+shift+pgup/pgdn` is `move_tab`.
  `goto_tab` values are 1-based like GTK. Return false from `goto_tab`/
  `move_tab` when nothing changes so performable binds pass the key through.
- (P3-02 result) After closing the active tab the right neighbour becomes
  active, or the left one if it was the last (libadwaita
  `select_next_page` then `select_previous_page`).
- (P3-02 result) `new_tab` passes the target core surface as parent;
  `Surface.create` overrides `working-directory` from `parent.pwd()` itself
  because `apprt.surface.newConfig` only uses `focusedSurface()`, which is
  null when the window never had focus (agent-launched tests).
- (P3-02 result) Tab switching calls `SetFocus` only if the old surface
  had focus or the window is foreground; otherwise `WM_ACTIVATE` focuses the
  active surface later. Focus reaches the core via the existing posted
  `WM_KILLFOCUS`/`WM_SETFOCUS` path.
- (P3-02 result) Posted `WM_MOUSEMOVE` to the tab bar does not show hover in
  tests: `TrackMouseEvent` posts `WM_MOUSELEAVE` at once because the real
  cursor is elsewhere.
- (P3-02 result) Hidden-tab CPU: 5 tabs each printing at 50 Hz, one
  visible: 369 ms CPU/s; the same load in 5 visible windows: 1408 ms/s;
  1 tab: 168 ms/s. The renderer skips drawing while occluded.
- (P3-02 result) The DPI acceptance check was not run live: the only
  working method (P1-02, `DisplayConfigSetDeviceInfo`) changes the user's
  display scale, which is off-limits while the desktop is in use.
  `WM_DPICHANGED` updates every tab's surface and calls `layout()`; the bar
  height comes from `GetDpiForWindow` and it rebuilds its font on
  `WM_DPICHANGED_AFTERPARENT`.
- (Drag-reorder follow-up) The tab bar reorders live through
  `Window.moveTab` as the pointer crosses half a tab; cancel moves the tab
  back to its origin index. The bar takes keyboard focus while dragging
  (only if the thread already had focus) so it receives Esc, then gives
  focus back to the active surface. Our own `ReleaseCapture` sends
  `WM_CAPTURECHANGED` synchronously, so clear the drag state before
  releasing or the commit turns into a cancel.
- (Tear-off follow-up) Tabs move between windows by `SetParent` on each
  surface HWND plus `surface.window = target`; the GL context survives
  (CS_OWNDC) and shells keep running. A release counts as "outside" when
  the point is outside the window, more than two bar heights from the bar,
  or `WindowFromPoint` hits another top-level window; dropping on another
  Ghostty window's tab bar (or its caption when the bar is hidden) inserts
  there. `SetFocus` on the tab bar activates an inactive top-level, so in
  posted-message tests the source window jumps to the top of the z-order
  and can cover the drop target.

## Out of scope

Tab overview, tab drag between windows (`move_tab_to_new_window` → false),
tab bar theming options.

## Wrap-up

Tick P3-02.
