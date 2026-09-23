# P4-05 — IPC: `+new-window` / `+new-tab` talk to a running instance

**Phase:** P4 · **Depends on:** P3-02 · **Size:** S–M ·
**Touches:** `src/apprt/win32/App.zig`, new `src/apprt/win32/ipc.zig`, `src/apprt/win32/c.zig`.

## Goal

`ghostty +new-window` and `ghostty +new-tab` (with optional `--working-directory`,
`-e command`) open a window/tab in the already-running Ghostty instead of
starting another process; with no running instance they return false and
the CLI falls back to launching normally.

## Read before starting (~200 lines)

- `src/apprt/ipc.zig` (whole: `Target`, `Action`, payload structs).
- `src/cli/new_window.zig:200-260` and `src/cli/new_tab.zig:220-270`
  (how `performIpc` is called and what a `false` return does).
- `src/apprt/gtk/ipc/DBus.zig:1-80` (the reference shape).
- `src/apprt/win32/App.zig` message-only window from P1-01.
- `src/apprt/gtk/class/Overrides.zig` (which arguments GTK applies) and
  `src/apprt/gtk/class/surface.zig` `applyCommandOverrides`.

## Design

- The running instance's message-only window has class name
  `GhosttyIpc_<user-sid or session id>` (include the session so RDP
  users do not cross-talk) and window text = the `class` config value
  (`Config.@"class"`), so `Target.class` can be matched by
  `FindWindowExW(HWND_MESSAGE, null, class, text)`.
- Message: `WM_COPYDATA` with `dwData = version (1)`, `lpData` = a
  UTF-8 JSON or a simple length-prefixed struct: `{ action: u8, cwd: ?[]u8,
argv: [][]u8, env: ... }`. Keep it versioned and reject unknown versions.
- Receiver (main thread, in the WndProc): parse, then push
  `core_app.mailbox` `new_window` (with parent = focused surface when
  `.new_tab` and a window exists) or call the tab action on the active
  window; return 1 on success.
- Sender (`performIpc`, static): find the window; if none → `false`;
  `SendMessageTimeoutW(hwnd, WM_COPYDATA, 0, &cds, SMTO_BLOCK, 2000, &res)`;
  return `res == 1`. Needs no COM, no pipes.

## Steps

1. Externs: `FindWindowExW`, `SendMessageTimeoutW`, `COPYDATASTRUCT`,
   `WM_COPYDATA`, `AllowSetForegroundWindow` (call it in the receiver so the
   new window can come to front), `ProcessIdToSessionId`.
2. Implement `ipc.zig` (encode/decode with unit tests).
3. Wire `performIpc` and the receiver.
4. Manual: with Ghostty open, run `ghostty +new-tab` from another
   PowerShell: a tab appears in the front window and it is raised.
   Run it with no instance: a new process starts.

## Acceptance

- Both manual checks; `+new-window --working-directory=C:\` opens there.
- Malformed `WM_COPYDATA` from a test sender is ignored without crashing.

## Gotchas

- `WM_COPYDATA` data is read-only and valid only during the call; copy it.
- UIPI blocks messages from lower-integrity senders; both processes run
  as the same user, so fine, but an elevated Ghostty will not receive
  from a non-elevated CLI (document).
- (P4-05 result) `AllowSetForegroundWindow` only works when called by the
  process that holds foreground rights, so the sender (CLI) calls it with
  the receiver's PID from `GetWindowThreadProcessId`; the receiver then
  calls `SetForegroundWindow`. From a background agent process the grant
  fails and the window is not raised; test raising by hand.
- (P4-05 result) The CLI prints "not supported on this platform" when
  `performIpc` returns false, so `ipc.send` itself launches a new
  `ghostty.exe [--class=X] <arguments>` when no instance is found. It
  clears `HANDLE_FLAG_INHERIT` on its std handles first, otherwise the GUI
  child inherits a redirected stderr pipe and `ghostty +new-tab 2>&1 | ...`
  hangs until that Ghostty exits.
- (P4-05 result) The receiver validates and copies the `WM_COPYDATA`
  payload, queues it, returns 1, and creates the window from a posted
  message. Creating the window inline could exceed the sender's 2 s
  timeout on a cold debug start, and a timeout must not trigger a
  second launch.
- (P4-05 result) Overrides (`--working-directory`, `--command`, `-e`,
  `--title`, `--shell-integration`, same set as GTK `Overrides.zig`) reach
  `Surface.create` through `App.ipc.overrides`, set only while the request
  runs; `Surface.create` calls `app.ipc.applyOverrides(&config)` last.
- (P4-05 result) `.detect` matches only window text `com.mitchellh.ghostty`
  (the default when `class` is unset), like GTK's default app id. Tests
  must launch with a unique `--class=...` and pass the same `--class` to
  `+new-tab`/`+new-window` so they never reach another instance.
- (P4-05 result) An elevated Ghostty will not receive from a non-elevated
  CLI (UIPI drops `WM_COPYDATA`); `SendMessageTimeoutW` fails and the CLI
  reports "did not accept the request". Not worked around on purpose:
  `ChangeWindowMessageFilterEx` would let any medium-integrity process
  run commands elevated.

## Out of scope

`toggle_quick_terminal`, a true single-instance lock (a second
`ghostty.exe` launch still opens a second process; that is acceptable).

## Wrap-up

Tick P4-05.
