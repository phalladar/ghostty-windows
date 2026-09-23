# P5-05 — Documentation: README section, Windows notes, known issues

**Phase:** P5 · **Depends on:** P5-02 · **Size:** S ·
**Touches:** `README.md` (a Windows section), new `dist/windows/README-windows.md`,
`windows/docs/*` (final refresh), `src/shell-integration/README.md` (PowerShell).

## Goal

A first-time Windows user can install, configure, and troubleshoot
Ghostty from the docs; a contributor can build it from `HACKING.md`.

## Steps

1. `README.md`: short "Windows (experimental)" section: requirements
   (Windows 11, GPU with OpenGL 4.3), download/install, config location
   (`%APPDATA%\ghostty\config`), default shell, known limitations.
2. `HACKING.md`: a "Building on Windows" subsection pointing to
   `windows/docs/02-environment.md` and the `-Dapp-runtime=win32` flag.
3. `dist/windows/README-windows.md`: what ships in the zip, how to run
   portable, how to add "Open Ghostty here", how to report crashes
   (`+crash-report`, dump location), how to get logs (`GHOSTTY_LOG`).
4. `src/shell-integration/README.md`: add the PowerShell section
   (injection method, features, cmd `PROMPT` marks).
5. `windows/docs/04-current-state.md`: rewrite as "state after the port"
   (what is implemented, what is not), and prune `STATUS.md` to a short
   "remaining work" list. Keep the task files as history.
6. Known issues list (in README-windows.md): RDP/virtual GPU (no GL 4.3),
   `+ssh` ControlMaster, no i18n on Windows, no global keybinds, no
   quick terminal, elevated/non-elevated IPC.

## Acceptance

- A reviewer can follow README-windows.md on a clean VM to a working
  terminal without consulting the task files.
- `prettier --check` passes on the Markdown you touched (if prettier is
  installed; otherwise ensure lines wrap sensibly and tables render).

## Wrap-up

Tick P5-05. Phase P5 complete: the port is at "v1" per `01-strategy.md`.

## Gotchas

- (P5-05 result) `win32` is already the default runtime for Windows
  targets (`src/apprt/runtime.zig`); docs show `-Dapp-runtime=win32` only
  for clarity.
- (P5-05 result) Notifications are tray balloons and work without the
  installer's AUMID shortcut; only WinRT toasts would need it.
- (P5-05 result) `shift+insert` defaults to `paste_from_selection`, which
  has no Windows equivalent; it is left out of the keybinding table.
- (P5-05 result) Release builds log `info`+ to stderr but attach no
  console; `Start-Process ghostty.exe -RedirectStandardError <file>` was
  verified to capture the log.
- (P5-05 result) Step 5's "prune STATUS.md" is left to the orchestrator
  (workers must not edit STATUS.md). `prettier@3 --check` passes on every
  Markdown file touched; the other `windows/docs` files were not checked.
