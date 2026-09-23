# P1-03 — ConPTY correctness: EOF, shutdown order, handle hygiene

**Phase:** P1 · **Depends on:** P0-05 (tests build); can run in parallel with P1-01 ·
**Size:** M · **Touches:** `src/termio/Exec.zig`, `src/pty.zig`, `src/Command.zig`,
`src/os/windows.zig` (externs).

## Goal

The Windows termio path is correct: the reader thread sees EOF when the
shell exits, the surface closes without hanging, no handles or processes
leak, and the app can open and close surfaces hundreds of times.

## Why

`04-current-state.md` (Terminal I/O) lists four bugs found by reading:
POSIX `close`/`write` used on HANDLEs, no EOF handling in the reader,
ConPTY-side pipe ends never closed (so the out pipe never reports EOF),
and leaked `hProcess`/`hThread` plus `bInheritHandles = TRUE`. Any one of
these makes closing a tab unreliable.

## Read before starting (~450 lines)

- `src/pty.zig:326-491` (`WindowsPty` whole).
- `src/termio/Exec.zig:100-235` (`init`/`threadEnter`/`threadExit`:
  pipes, xev stream, process watcher, read-thread quit),
  `:290-335` (`processExit`), `:530-560` (`ThreadData`),
  `:880-935` (`Subprocess.start` Windows branch, pty side closing),
  `:1015-1090` (Windows spawn: `pseudo_console`, returned fds),
  `:1150-1170` (`killCommand`), `:1773-1821` (`threadMainWindows`),
  `:1407-1440` (POSIX `threadMainPosix` for the structure to mirror).
- `src/Command.zig:305-440` (`startWindows`), `:487-506` (`wait`),
  `:581-651` (env block, command line).
- `src/os/windows.zig` (`exp.kernel32`: `CloseHandle`, `ReadFile`,
  `CancelIoEx`, `PeekNamedPipe`, `WaitForSingleObject`, `TerminateProcess`).
- Microsoft's ConPTY sequence (from memory of the docs; verify against
  learn.microsoft.com "Creating a Pseudoconsole session" if online):
  create pipes → `CreatePseudoConsole` → close the pty-side pipe ends →
  spawn with the attribute → on child exit `ClosePseudoConsole` → close
  remaining handles.

## Steps

1. **Handles, not fds.** In `Exec.zig` replace `posix.system.close(x)` on
   Windows handles (`:126-127`, `:550`, `:1775`) with `CloseHandle`, and the
   quit-pipe `posix.system.write` (`:206`) with `WriteFile`. Type the
   `ThreadData` read/quit fields as `Pty.Fd` (`:537-538`) so the
   compiler enforces it.
2. **Close the pty-side ends after CreatePseudoConsole.** In
   `Subprocess.start` Windows branch (`:913-929`) close
   `pty.in_pipe_pty` and `pty.out_pipe_pty` once the child is spawned
   (or immediately after `CreatePseudoConsole` in `pty.open`; pick the
   place that keeps `WindowsPty.deinit` from double-closing, and set the
   fields to `INVALID_HANDLE_VALUE`). Keep `in_pipe`/`out_pipe`.
3. **Reader EOF.** In `threadMainWindows`: use a 64 KiB buffer; on
   `ReadFile == FALSE`, switch on `GetLastError()`:
   `ERROR_BROKEN_PIPE` / `ERROR_NO_DATA` / `ERROR_INVALID_HANDLE` → exit
   the loop cleanly (log at `.info`); `ERROR_OPERATION_ABORTED` → check
   the quit pipe as today; anything else → log `.warn` and exit. A
   successful 0-byte read → treat as EOF. No `unreachable`.
4. **Shutdown order** in `threadExit`/`Subprocess.deinit` (Windows):
   write the quit byte, `CancelIoEx(read_handle, null)` (ignore
   `ERROR_NOT_FOUND`), then `ClosePseudoConsole` **before** joining the
   reader if the child is still alive (this unblocks the read with
   `ERROR_BROKEN_PIPE`), join, then `CloseHandle` the four pipe ends.
   Make sure `WindowsPty.deinit` and `Subprocess.deinit` agree on who
   closes what; record the ownership split under "Decisions" in STATUS.md.
5. **Process handles.** `Command.startWindows`: `CloseHandle(hThread)`
   right after `CreateProcessW`; keep `hProcess` as `pid` and close it in
   `wait`/`deinit` (find where the POSIX path reaps and mirror). Set
   `bInheritHandles = FALSE` when a pseudo console is used (all pipe
   ends are already non-inheritable; the attribute list carries the
   console). Sort the environment block case-insensitively by name
   (`CreateProcessW` docs require it; PowerShell tolerates unsorted, cmd
   sometimes does not).
6. **`processExit`** (`:302`): replace `catch unreachable` with a logged
   error that still marks the process as exited.
7. **Tests.** Add Windows-gated tests in `Exec.zig` or `pty.zig`:
   spawn `cmd.exe /c exit 3`, read until EOF, assert the exit code is 3
   and that the reader returns; run it 50 times in a loop to catch
   handle leaks (compare `GetProcessHandleCount` before/after, allow a
   small delta).
8. Manual: from the running app (once P1-01/P1-04 work), type `exit`;
   the surface must close within a second, and `Get-Process conhost`
   must not grow.

## Acceptance

- `zig build test -Dtest-filter="windows"` passes including the new
  spawn/EOF test.
- Opening and closing 100 surfaces (script it once P3 exists, or loop the
  unit test) leaves the process handle count within ±20 of the start.
- Typing `exit` in the shell closes the surface; killing the shell from
  Task Manager also closes it.
- No `posix.system.close`/`write` remains on a Windows handle path
  (`grep -n "posix.system" src/termio/Exec.zig`).

## Gotchas

- `ClosePseudoConsole` can block until the output pipe is drained; never
  call it on the reader thread, and never after you have closed
  `out_pipe`.
- `CancelIoEx` before `ReadFile` has started is a no-op; the quit byte +
  `PeekNamedPipe` check covers that race. Keep both.
- `xev.Process` on Windows: if child-exit notifications turn out not to
  fire, fall back to `RegisterWaitForSingleObject(hProcess)` posting to
  the surface mailbox. Record what you observed.
- `TerminateProcess` kills only the direct child; a Job Object is P4-03.
- Do not change the POSIX code paths; every edit here sits in a Windows
  branch.
- (P1-03 result) Ownership split: `WindowsPty.open` closes the ConPTY-side
  pipe ends itself right after `CreatePseudoConsole` (they are locals, not
  fields). `WindowsPty` owns `in_pipe`, `out_pipe` and the HPCON
  (`pseudo_console: ?HPCON`; `closePseudoConsole()` is idempotent and
  `deinit` calls it before closing the pipes). `ThreadData` owns the quit
  pipe write end; the reader thread owns the read end. `Command.deinit`
  closes `hProcess` (called from `Subprocess.stop`/`externalExit` on
  Windows); `xev.Process` duplicates its own copy.
- (P1-03 result) Shutdown order deviates from step 4: `threadExit` calls
  `closePseudoConsole` _before_ writing the quit byte / `CancelIoEx`, so the
  reader is still draining `out_pipe` when conhost flushes its last frame;
  the reader then exits on `ERROR_BROKEN_PIPE`. Quit byte + `CancelIoEx`
  stay as a backstop.
- (P1-03 result) With ConPTY the out pipe does not report EOF when the
  child exits; it only does once `ClosePseudoConsole` runs (conhost holds
  the write end). Surface close is driven by `xev.Process` (job object
  notification), not by reader EOF.
- Manual testing: PowerShell `Start-Process -ArgumentList` joins array
  items with spaces without quoting, so `'--command=cmd.exe /c ping ...'`
  arrives as `--command=cmd.exe` plus stray args, and an interactive cmd
  never exits. Quote it: `'"--command=cmd.exe /c ping -n 3 127.0.0.1"'`.
  The log line `starting command command=...` shows the real argv.
- A child that exits non-zero faster than `abnormal-command-exit-runtime`
  (default 250 ms, e.g. `pwsh -Command exit 3`) keeps the surface open with
  the abnormal-exit message; that is upstream behaviour, not a hang.
- (P1-03 result) Tests in `src/termio/Exec.zig` ("Exec windows: ...") use
  `Pty` + `Command` + `ReadThread.readWindows` directly; 100 spawn/EOF
  cycles showed handle count 80 → 80.

## Out of scope

Job objects, `PSEUDOCONSOLE_INHERIT_CURSOR`, foreground process info,
OSC 7 (P4-03). Default shell selection (P2-06).

## Wrap-up

Tick P1-03. Update `04-current-state.md` rows that are now fixed.
