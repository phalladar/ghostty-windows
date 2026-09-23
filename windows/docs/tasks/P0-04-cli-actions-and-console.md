# P0-04 — CLI actions work from a terminal (console attach, logging)

**Phase:** P0 · **Depends on:** P0-03 · **Size:** S ·
**Touches:** `src/os/windows.zig` (externs), `src/main_ghostty.zig` or
`src/global.zig` (one call site), possibly `src/os/stderr.zig`.

## Goal

`ghostty.exe +version`, `+list-fonts`, `+show-config`, `+list-keybinds`,
`+validate-config` print to the PowerShell window they were launched
from, and `std.log` output is visible in Debug builds. This gives every
later task a way to observe the program.

## Why

`GhosttyExe.zig:44-49` builds a GUI-subsystem exe (no console). Without
attaching to the parent console, every CLI action prints nothing and every
error/log line is lost (`04-current-state.md`, OS layer).

## Read before starting (~200 lines)

- `src/main_ghostty.zig:25-115` (`main`: `global.init`, action dispatch,
  runtime start), `:120-175` (`logFn` writes to stderr via `std.debug.lockStderr`).
- `src/global.zig:60-160` (`init`: how `action` and `GHOSTTY_LOG` are parsed).
- `src/os/stderr.zig` (whole; writes to the PEB stderr handle, which is
  null with no console).
- `src/os/windows.zig:138-200` (`exp.kernel32` extern style).
- `src/cli/version.zig` (what `+version` prints; the smoke check).
- `src/cli/validate_config.zig:40-52` and `src/cli/explain_config.zig:78-90`
  (`Writer.end()` call sites that fail on a console handle).

## Steps

1. Add to `src/os/windows.zig` under `exp.kernel32`: `AttachConsole(DWORD) BOOL`,
   `GetStdHandle(DWORD) HANDLE`, `SetStdHandle(DWORD, HANDLE) BOOL`, plus
   constants `ATTACH_PARENT_PROCESS = 0xFFFFFFFF`, `STD_INPUT_HANDLE`,
   `STD_OUTPUT_HANDLE`, `STD_ERROR_HANDLE`.
2. Add a helper (suggested: `src/os/windows.zig` → `pub fn attachParentConsole() bool`)
   that calls `AttachConsole(ATTACH_PARENT_PROCESS)`; on success, open
   `CONOUT$` (for stdout and stderr) and `CONIN$` with `CreateFileW`
   (`GENERIC_READ|GENERIC_WRITE`, share read/write, `OPEN_EXISTING`) and
   `SetStdHandle` each. Also refresh whatever cached handle
   `src/os/stderr.zig` uses so `stderr.zig` writes go to the console
   (read it to see whether it caches the PEB value or reads it each call).
3. Call it early in `main` (before `global.init` error printing can
   happen, i.e. at the very top of `main` in `main_ghostty.zig`) when
   **either** `builtin.mode == .Debug` **or** argv contains a `+action`
   argument. Detecting the `+` argument before `global.init` can be a
   cheap scan of raw args; do not duplicate the CLI parser.
   Keep it Windows-only with `comptime builtin.os.tag == .windows`.
4. Build and run from PowerShell:
   `.\zig-out\bin\ghostty.exe +version`, `+list-fonts`, `+show-config`,
   `+list-keybinds`, `+validate-config`, `+list-themes` (TUI; note whether
   vaxis works), `+boo`.
5. Run `.\zig-out\bin\ghostty.exe` (no action) in a Debug build: the
   runtime stub should log "win32 runtime stub" and exit 0.

## Acceptance

- Each command in step 4 prints its expected output in the launching
  PowerShell window and exits 0 (`$LASTEXITCODE`). Record any that fail
  in STATUS.md with the error; `+list-themes` and `+ssh-cache` may be
  deferred.
- `zig build -Dapp-runtime=gtk` unaffected (no non-Windows code path changed).

## Gotchas

- GUI-subsystem processes are not waited on by PowerShell/cmd, so output
  appears "after" the prompt returns. That is expected; a separate
  console-subsystem `ghosttyc.exe` is a P5 option if it bothers users.
- `AttachConsole` fails (`ERROR_INVALID_HANDLE`) when launched from
  Explorer; that is fine: return false and carry on silently.
- Windows console defaults to the OEM code page; `+list-fonts` prints
  UTF-8. Call `SetConsoleOutputCP(65001)` after attaching (declare it).
  The manifest fix for UTF-8 process code page is P5-01.
- `std.debug.lockStderr` in Zig 0.16 obtains the handle from the process
  at call time; verify by testing rather than assuming. (Verified: it reads
  the PEB `hStdError` the first time it is locked and then caches it, and
  `SetStdHandle` updates the PEB, so attaching must happen before the first
  log line. `std.Io.File.stdout()` and `src/os/stderr.zig` read the PEB on
  every call.)
- `std.Io.File.Writer.end()` calls `setLength`, which fails on a console
  (`CONOUT$`) handle with `error.FileTooBig`
  (`STATUS_INVALID_PARAMETER`); only `NonResizable` is swallowed. CLI
  actions that call `end()` (`validate_config.zig`, `explain_config.zig`)
  flush instead on Windows. The same error breaks the GTK build's
  `gresource.zig` generator on a Windows host.
- Only std handles that are null/invalid are replaced with `CONIN$`/`CONOUT$`,
  so `ghostty +version > out.txt` and pipes keep the inherited handles.
- `+boo` needs a console of at least 100x41 or it prints "Screen must be at
  least 100w x 41h" and waits for a key.

## Out of scope

The `.none` runtime's stale `std.io.getStdOut()` code, `+edit-config`
(P2-06), IPC actions `+new-window`/`+new-tab` (P4-05).

## Wrap-up

Tick P0-04. Add a line to `02-environment.md` section 4 if the mechanism
differs from what is described there.
