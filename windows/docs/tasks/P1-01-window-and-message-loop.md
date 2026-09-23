# P1-01 — A real window: classes, message loop, wakeup, surface lifecycle, clean exit

**Phase:** P1 · **Depends on:** P0-03, P0-04 · **Size:** L ·
**Touches:** `src/apprt/win32/{App,Surface,Window,c}.zig`.

## Goal

Launching `ghostty.exe` opens a top-level window containing one child
"surface" window. The core surface is initialised (renderer and termio
threads start and a shell is spawned). Closing the window tears the
surface down and the process exits with code 0. Nothing is drawn yet
(P1-02) and keys are ignored (P1-04).

## Read before starting (~450 lines)

- `windows/docs/05-architecture.md` (whole).
- `windows/docs/06-apprt-contract.md`: "App", "Surface", lifecycle order,
  and the MVP rows of the action table.
- `src/main_ghostty.zig:100-115` (how `run` is entered).
- `src/App.zig:150-165` (`tick`), `:190-246` (`addSurface`/`deleteSurface`
  and the `quit_timer` actions), `:265-298` (mailbox drain incl. `.quit`),
  `:578-595` (Mailbox push → `rt_app.wakeup()`).
- `src/apprt/gtk/class/application.zig:489-606` (the run loop shape:
  iterate, then `core_app.tick`), `:1352-1360` (`wakeup`), and the
  `quit_timer`/`quit` handling inside `performAction` (`grep -n "quit_timer\|\.quit =>" src/apprt/gtk/class/application.zig`).
- `src/apprt/gtk/class/surface.zig:3460-3530` (core surface init order)
  and `:3317-3345` (realize/unrealize → `displayRealized`).
- `src/apprt/embedded.zig:447-520` (Surface fields and `init` ordering),
  `:634-650` (`deinit`).
- `src/Surface.zig:467-540` (what `init` reads from `rt_surface` right away).
- `src/config/Config.zig`: grep `window-width`, `window-height`,
  `quit-after-last-window-closed`, `title` to know the fields you honour.
- `src/App.zig:132-135` (core `App.deinit` calls `rt_surface.deinit()`).
- `src/Surface.zig:1855-1900` (`recomputeInitialSize`: units of `initial_size`).

## Design

Files:

- `c.zig`: externs and constants for this task: `RegisterClassExW`,
  `CreateWindowExW`, `DestroyWindow`, `ShowWindow`, `UpdateWindow`,
  `GetMessageW`, `TranslateMessage`, `DispatchMessageW`, `PostMessageW`,
  `PostQuitMessage`, `DefWindowProcW`, `GetWindowLongPtrW`/`SetWindowLongPtrW`
  (`GWLP_USERDATA`), `SetWindowTextW`, `GetClientRect`, `MoveWindow`/`SetWindowPos`,
  `GetDpiForWindow`, `AdjustWindowRectExForDpi`, `LoadCursorW`, `LoadIconW`,
  `GetModuleHandleW`, `SetTimer`/`KillTimer`, `MessageBoxW`. Structs:
  `WNDCLASSEXW`, `MSG`, `POINT`, `RECT`, `MINMAXINFO`, `CREATESTRUCTW`.
  Messages: `WM_CREATE`, `WM_DESTROY`, `WM_CLOSE`, `WM_SIZE`, `WM_DPICHANGED`,
  `WM_GETMINMAXINFO`, `WM_PAINT`, `WM_ERASEBKGND`, `WM_SETFOCUS`,
  `WM_KILLFOCUS`, `WM_TIMER`, `WM_APP`.
- `App.zig`: `init` registers two classes (`GhosttyWindow`, `GhosttySurface`
  with `CS_OWNDC`), creates a **message-only window** (`HWND_MESSAGE`
  parent) for wakeups, loads config, applies `core_app.updateConfig`,
  creates the first `Window`. `run` is the `GetMessageW` loop; on
  `WM_APP + 1` (`WM_GHOSTTY_TICK`) it calls `core_app.tick(self)`. `wakeup`
  posts that message (thread-safe). `terminate` destroys windows and
  unregisters classes. `performAction` handles: `quit` (destroy all
  windows, `PostQuitMessage(0)`), `new_window` (create a `Window`),
  `close_window`, `quit_timer` (start/stop a `SetTimer` on the
  message-only window if `quit-after-last-window-closed` is set; on fire,
  `quit`), `set_title` (forward to the surface's window), `size_limit`,
  `initial_size`, `present_terminal`, `reload_config`/`config_change`
  (reload + `core_app.updateConfig`). Everything else returns `false`.
- `Window.zig`: top-level HWND, `WndProc` (store `*Window` in
  `GWLP_USERDATA` from `WM_CREATE`'s `CREATESTRUCTW.lpCreateParams`),
  owns one `*Surface` for now, lays it out to the full client rect in
  `WM_SIZE`, enforces `min_size` in `WM_GETMINMAXINFO`, on `WM_CLOSE`
  asks `surface.core().needsConfirmQuit()` → `MessageBoxW` yes/no, then
  `surface.close(false)`; `WM_DESTROY` frees. Title from `set_title`.
- `Surface.zig`: child HWND (`WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS`),
  fills `size` from `GetClientRect` and `content_scale` from
  `GetDpiForWindow / 96` **before** `core_surface.init`. Then
  `addSurface`, `newConfig`, `core_surface.init`, then
  `core_surface.displayRealized()` is not required for OpenGL but call
  the callbacks the GTK path calls after realize if any are needed
  (check `generic.zig:227` `display_realized` default). `WM_SIZE` on the
  child → `core_surface.sizeCallback`. `WM_PAINT` → `ValidateRect`;
  `WM_ERASEBKGND` → return 1. `close()` = `deleteSurface` +
  `core_surface.deinit()` + `DestroyWindow`. `getSize`/`getContentScale`/
  `getCursorPos`/`getTitle`/`defaultTermioEnv` per contract.

Quit semantics: when the last window is destroyed and no quit timer is
configured, post `WM_QUIT`. The core also sends `.quit` via
`performAction`; both paths must be idempotent.

## Steps

1. Externs and structs in `c.zig` (only what this task uses).
2. `App.init`/`run`/`terminate`/`wakeup` with the message-only window.
3. `Window` with class registration and WndProc; `Surface` child window.
4. Surface lifecycle exactly in the contract order; log each step at
   `.debug` so a hang is easy to place.
5. Wire the MVP actions listed above; return `false` for the rest.
6. Run `zig build run -Dapp-runtime=win32` from PowerShell. Expect a blank
   window (black or white). Close it via the title bar.
7. Confirm the process exits (`$LASTEXITCODE` from running the exe
   directly) and that no `conhost.exe`/`OpenConsole.exe` or shell process
   is left behind (`Get-Process pwsh,cmd,conhost | Where-Object StartTime -gt (Get-Date).AddMinutes(-2)`).
   If the shell lingers, that is P1-03 territory: record it, do not fix it here.

## Acceptance

- Window opens with the config `title` (default "Ghostty") and the
  `window-width`/`window-height` client size in cells is honoured via
  `initial_size` (approximate is fine until fonts are measured).
- Debug log shows the renderer thread's `threadEnter` succeeding (GL
  version line from P0-03) and termio spawning the shell.
- Closing the window exits the process with 0 and no leaked windows.
- `wakeup` from the termio thread reaches `tick` (log a debug line in the
  tick handler and see it fire when the shell prints its prompt).
- Minimum window size is enforced (`size_limit`).

## Gotchas

- `GetMessageW` returns -1 on error; loop on `> 0`.
- `WM_APP` messages posted to a message-only window are delivered to its
  WndProc via `DispatchMessageW`, so handle the tick there, not in the loop.
- Do not call `core_app.tick` re-entrantly from inside another core
  callback; if a WndProc needs a tick, post the message.
- `PostQuitMessage` must be called on the main thread; `quit` arrives
  via `tick`, which is on the main thread.
- `SetWindowLongPtrW` is `SetWindowLongW` on 32-bit; we are 64-bit only.
- Use `AdjustWindowRectExForDpi` so `initial_size` (client px) turns into
  the right outer size at the monitor's DPI.
- `Surface.close` may be called from `tick` while the WndProc is on the
  stack; destroy the HWND with `DestroyWindow` after `core_surface.deinit`
  and never touch `self` after freeing.

- `initial_size` is in unscaled units (the core divides by content scale);
  multiply by `content_scale` to get client px. `size_limit` is already in
  device px.
- Core `App.deinit` calls `rt_surface.deinit()` on any surface still
  registered, so `Surface` must expose `deinit` (core teardown only, no free).
- `main_ghostty.zig` checks `@hasDecl(apprt.App, "startQuitTimer")`; do not
  name a private helper `startQuitTimer`.
- `quit-after-last-window-closed` defaults to false off Linux. With no tray
  icon the app quits when the last window is destroyed; only
  `quit-after-last-window-closed = true` plus a delay keeps it alive until
  the timer fires.
- `MAKEINTRESOURCE` values are odd-aligned; declare `LoadIconW`/`LoadCursorW`
  names as `[*:0]align(1) const u16`.
- Store the `*Window`/`*Surface` in `GWLP_USERDATA` from `WM_NCCREATE`, not
  `WM_CREATE`: `WM_GETMINMAXINFO` arrives first.

## Out of scope

Rendering (P1-02), keyboard (P1-04), mouse/focus (P1-05), tabs/splits (P3),
IME, clipboard, dark title bar (P2-05).

## Wrap-up

Tick P1-01. Record any action you had to implement beyond the list, and
note the process-lingering result for P1-03.
