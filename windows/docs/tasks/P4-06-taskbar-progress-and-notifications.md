# P4-06 — Taskbar progress, desktop notifications, remaining "nice" actions

**Phase:** P4 · **Depends on:** P2-05 · **Size:** S–M ·
**Touches:** `src/apprt/win32/{App,Window,c}.zig`, new `src/apprt/win32/taskbar.zig`.

## Goal

OSC 9;4 progress (`progress_report`) shows on the taskbar button;
`desktop_notification` shows a Windows notification; `command_finished`
flashes the taskbar for long commands when unfocused; `float_window`
(always on top) and `toggle_visibility` work; `color_change` and
`renderer_health` are logged.

## Read before starting (~150 lines)

- `src/apprt/action.zig`: `ProgressReport` (states: remove/set/error/
  indeterminate/pause), `DesktopNotification`, `FloatWindow`,
  `CommandFinished` payloads.
- `src/apprt/gtk/class/application.zig`: grep `desktop_notification`,
  `progress_report` for reference semantics.
- `src/config/Config.zig`: grep `desktop-notifications`, `command-finished`? (check for a notification-on-finish option).

## Steps

1. **Taskbar progress:** `CoCreateInstance(CLSID_TaskbarList, IID_ITaskbarList3)`
   (COM vtable declared by hand: `HrInit`, `SetProgressState`, `SetProgressValue`
   are the slots you need; keep the slot order from `shobjidl_core.h`).
   Map states: `remove` → `TBPF_NOPROGRESS`, `set` → `TBPF_NORMAL` +
   value/100, `error` → `TBPF_ERROR`, `indeterminate` → `TBPF_INDETERMINATE`,
   `pause` → `TBPF_PAUSED`.
2. **Notifications:** simplest robust path is `Shell_NotifyIconW` with
   `NIF_INFO` balloon (shows as a Windows 11 toast). Requires a tray icon
   while the balloon is shown; add it on demand and remove it after 10 s
   via a timer. Honour `desktop-notifications` config. WinRT toasts
   (`ToastNotificationManager`) need an AppUserModelID with a Start Menu
   shortcut; defer to P5-02 packaging and note it.
3. **`command_finished`:** if the surface's window is not foreground and
   duration exceeds a threshold (check whether a config option exists;
   else 10 s hard-coded), `FlashWindowEx`.
4. **`float_window`:** `SetWindowPos(HWND_TOPMOST/HWND_NOTOPMOST)`.
   **`toggle_visibility`:** hide/show all windows (`SW_HIDE`/`SW_SHOW`);
   keep a tray icon while hidden so the user can get back (reuse step 2).
5. `color_change`, `renderer_health`, `pwd`, `mouse_over_link`,
   `selection_changed`, `readonly`, `key_sequence`, `key_table`,
   `secure_input`: return true with a debug log (no UI).

## Acceptance

- In pwsh: `[Console]::Write("`e]9;4;1;50`a")` shows 50% on the taskbar;
  `...9;4;0`a` clears it.
- `printf '\e]777;notify;Title;Body\a'` (or the OSC 99 form the core
  supports; check `desktop_notification` sources) shows a notification.
- A 15 s `Start-Sleep` finishing while another window is focused flashes
  the taskbar button.
- `float_window` keybind toggles always-on-top.

## Gotchas

- COM must be initialised on the main thread (P2-05 does it).
- Balloon notifications are suppressed when Focus Assist is on; that is
  system behaviour.
- All COM/tray externs live in `taskbar.zig` (not `c.zig`). The import is
  `taskbarpkg` in `App.zig` because the `App.taskbar` field name clashes.
- The tray icon's `NIM_DELETE` must run before the message window is
  destroyed in `App.terminate`, or a ghost icon stays in the tray.
- Progress uses a 15 s `SetTimer` with a `TIMERPROC` on the top-level HWND
  (same stall timeout as GTK), so `Window.wndProc` needs no `WM_TIMER` case.
- `notify-on-command-finish` exists (default `never`); `command_finished`
  follows GTK: `bell` action -> `Window.ringBell` (flashes via
  `bell-features=attention`), `notify` action -> tray balloon.
- Windows 11 conhost passes OSC 9;4, 777 and 133 through ConPTY; test by
  writing them from a `pwsh -File` child (`133;C` ... `133;D;0` for
  `command_finished` without shell integration).
- To test `toggle_visibility`/tray click, find the app's message window with
  `FindWindowEx(HWND_MESSAGE, prev, "GhosttyMessage")` filtered by PID and
  post `WM_APP+0x40` with `lParam=WM_LBUTTONUP`.

## Out of scope

Jump lists, live tiles, WinRT toasts with actions.

## Wrap-up

Tick P4-06. This completes P4; update the STATUS.md phase summary.
