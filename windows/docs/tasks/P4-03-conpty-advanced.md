# P4-03 — ConPTY, advanced: job objects, cursor inheritance, process info, OSC 7

**Phase:** P4 · **Depends on:** P1-03 · **Size:** M ·
**Touches:** `src/Command.zig`, `src/pty.zig`, `src/termio/Exec.zig`,
`src/termio/stream_handler.zig`, `src/os/windows.zig`.

## Goal

Closing a surface kills the whole process tree (not just the shell);
`ClosePseudoConsole`-driven `CTRL_CLOSE_EVENT` gives console apps a
chance to exit cleanly first; the surface knows the foreground process
for `confirm-close-surface` heuristics; OSC 7 with Windows paths updates
the surface pwd; ConPTY quirks are configured for the best fidelity on
Windows 11.

## Read before starting (~250 lines)

- `src/termio/Exec.zig` Windows spawn/kill paths (post P1-03).
- `src/pty.zig` `WindowsPty` (post P1-03), `getProcessInfo` (`:488`).
- `src/termio/stream_handler.zig:1470-1500` (`reportPwd` Windows stub)
  and how `pwd_change` is consumed (`src/Surface.zig`, grep `pwd_change`).
- `src/Surface.zig`: grep `foreground_pid`, `tty_name`, `needsConfirmQuit`
  to see what process info is used for.
- `src/os/uri.zig` (file URI parsing) for `file://host/C:/path`.
- `src/os/hostname.zig` (`isLocal`, Windows `GetComputerNameExW`).
- `src/termio/Termio.zig:496-534` (`resize`: pty first, then terminal).
- `src/apprt/surface.zig:200-245` (`newConfig`: inherits the focused
  surface pwd for new windows/tabs).
- libxev `src/watcher/process.zig:240-300` (xev.Process also assigns the
  child to its own job; nested under ours).

## Steps

1. **Job object.** In `Command.startWindows`: `CreateJobObjectW`, set
   `JOBOBJECT_EXTENDED_LIMIT_INFORMATION.BasicLimitInformation.LimitFlags =
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK`,
   create the process with `CREATE_SUSPENDED`, `AssignProcessToJobObject`,
   `ResumeThread`. Keep the job handle in `Command`; `kill` closes the
   job (kills the tree). Without breakaway-ok, `start`-ed GUI apps from
   the shell would die with the tab; test both and pick what Windows
   Terminal does (it uses breakaway to let `code .` outlive the tab).
2. **Graceful close.** In `killCommand`: `ClosePseudoConsole` first
   (delivers `CTRL_CLOSE_EVENT` to the console tree), wait up to ~1 s on
   `hProcess`, then close the job.
3. **`PSEUDOCONSOLE_INHERIT_CURSOR` (0x1)**: pass it to
   `CreatePseudoConsole`; the pty then queries the cursor position from us
   via `ESC[6n` on startup; the core answers DSR already. Verify no
   stray `^[[?25h`-style garbage appears.
4. **Foreground process (`getProcessInfo(.foreground_pid)`):**
   `QueryInformationJobObject(JobObjectBasicProcessIdList)` gives all PIDs
   in the tree; pick the most recently created one (via
   `GetProcessTimes` creation time) as the "foreground" approximation.
   This feeds `needsConfirmQuit`-style checks; document it as a heuristic.
   `.tty_name` stays null.
5. **OSC 7 on Windows:** in `stream_handler.reportPwd`, accept
   `file://<host>/C:/Users/x` (and `file:///C:/...`), convert to
   `C:\Users\x`, compare the host with the local hostname (P2-06's
   `GetComputerNameExW`), and push `pwd_change`. Add unit tests.
6. **Resize:** ConPTY repaints the whole screen on resize; confirm with
   `Exec.zig`'s resize path that we do not double-resize (pty then
   terminal) in a way that causes a flash; nothing to change if fine.
7. **Investigate only (write findings, no code):** newer ConPTY flags on
   Windows 11 24H2+ (`PSEUDOCONSOLE_RESIZE_QUIRK`, passthrough mode) and
   whether bundling `OpenConsole.exe` (as Windows Terminal does) is
   worth it. Record in STATUS.md "Decisions".

## Acceptance

- `Start-Process notepad` then close the tab: with breakaway-ok notepad
  survives; without, it dies (pick and document).
- `ping -t` in cmd, close tab → no orphan `PING.EXE` (Task Manager).
- `cd C:\Windows` in pwsh with integration → new tab opens in `C:\Windows`.
- No garbage on startup with `INHERIT_CURSOR`.

## Gotchas

- A process already in a job (e.g. when Ghostty is launched from a
  job-constrained parent) cannot be assigned unless nested jobs are
  allowed (Windows 8+ allows nesting; fine on 11).
- `CREATE_SUSPENDED` + attribute list + pseudo console: order is
  create-suspended, assign to job, resume.
- Closing the job handle kills the tree immediately; keep it until the
  surface is gone.

- (P4-03 result) Breakaway decision: the job is created with
  `JOB_OBJECT_LIMIT_BREAKAWAY_OK` only, **not** `KILL_ON_JOB_CLOSE`.
  Measured with kill-on-close: `code .` (via `code.cmd`) from cmd or Windows
  PowerShell died with the tab, with or without BREAKAWAY_OK (neither
  ShellExecute nor libuv asks for `CREATE_BREAKAWAY_FROM_JOB`). Without
  kill-on-close it matches Windows Terminal: `ClosePseudoConsole` sends
  `CTRL_CLOSE_EVENT` and ends everything attached to the console (`ping -t`
  gone, surface closes in ~150 ms). Detached GUI apps (`code`, `winver`,
  `notepad`, `charmap`) and processes with their own console survive. If
  the shell has not exited 1 s after `ClosePseudoConsole` (e.g. a GUI app run
  as `command`), `killCommand` calls `TerminateJobObject` and kills the whole
  tree (measured 1154 ms close). Closing the job handle kills nothing.
- (P4-03 result) With the MSIX-packaged pwsh (`WindowsApps\pwsh.exe`) GUI
  children started with `Start-Process` are never in our job, whatever the
  flags are: the package activation puts them elsewhere. Test job behaviour
  with `cmd.exe` or `powershell.exe` as the shell.
- (P4-03 result) `PSEUDOCONSOLE_INHERIT_CURSOR` makes conhost send `ESC[6n`
  and block all output until the cursor report arrives. Anything that spawns
  into a ConPTY without the core answering DSR hangs forever; the Exec
  Windows tests answer it in `WindowsTestReader.reportCursor`.
- (P4-03 result) conhost asks for `CSI ? 9001 h` (win32-input-mode) on
  startup; the log shows `unimplemented mode: 9001`. P1-04 should decide
  whether to support it.
- (P4-03 result) `foreground_pid` is a heuristic: the newest living process
  (by `GetProcessTimes` creation time) in the job's
  `JobObjectBasicProcessIdList`. `Command.windowsForegroundPid`; wired in
  `Subprocess.getProcessInfo`. `tty_name` stays null.
- (P4-03 result) OSC 7: `file:///C:/x` (empty or missing host is local on
  Windows), `file://<host>/C:/x` (host compared case-insensitively with
  `GetComputerNameExW(DnsHostname)`), `file://localhost/...`, and
  `kitty-shell-cwd://`. The path must be `/<drive>:` or `/<drive>:/...`;
  anything else is rejected with a warning. Percent-decoding happens first.
  `stackFallback(...).get()` may only be called once per instance.
- (P4-03 result) For P2-07: the pwsh integration should emit, from its
  prompt function, `ESC ] 7 ; file://<hostname>/<path with / separators> BEL`
  where `<path>` is `$PWD.ProviderPath` with `\` replaced by `/` and percent-
  encoded (spaces as `%20`), only when `$PWD.Provider.Name -eq 'FileSystem'`
  and the path has a drive letter (skip UNC for now). Example:
  `"`e]7;file://$([Net.Dns]::GetHostName())/C:/Program%20Files`a"`.
- (P4-03 result) Resize: `Termio.resize` resizes the pty once, then the
  terminal once, under the coalescing resize timer; no double resize. `setSize`
  now skips `ResizePseudoConsole` when only the pixel size changed, to avoid a
  needless full ConPTY repaint.
- (P4-03 investigation, no code) Newer ConPTY flags: `PSEUDOCONSOLE_RESIZE_QUIRK`
  (0x2), `PSEUDOCONSOLE_WIN32_INPUT_MODE` (0x4) and passthrough mode (0x8) are
  private flags consumed by the OpenConsole.exe/conpty.dll that Windows
  Terminal ships; inbox conhost does not document them and passthrough is
  experimental even in WT. Bundling OpenConsole.exe + conpty.dll (MIT, from
  microsoft/terminal, about 1.5 MB per arch) would give newer ConPTY fixes and
  those flags, at the cost of shipping and updating per-arch binaries.
  Recommendation: not now. Revisit after P1-04; the cheap path is to load
  `conpty.dll` from next to ghostty.exe when present and fall back to the
  kernel32 exports.
- (Resize fix, 2026-09-23; supersedes the recommendation above) User bug:
  pwsh + oh-my-posh two-line prompt, `ls`, resize → garbage. Three causes:
  1. Inbox conhost (kernel32 `CreatePseudoConsole`) repaints the whole
     viewport (`ESC[H` + every row with hard CRLFs) after every
     `ResizePseudoConsole` from its own scrollback-less buffer, overwriting
     our reflow. `PSEUDOCONSOLE_RESIZE_QUIRK` (0x2) is ignored by it and no
     longer exists in current ConPTY (0x8/0x10/0x18 are now
     `PSEUDOCONSOLE_GLYPH_WIDTH_*`, 0x20 `AMBIGUOUS_IS_WIDE`). Fix:
     `WindowsPty.Conpty.load` (`src/pty.zig`) loads `conpty.dll` from the exe
     directory (it starts `OpenConsole.exe` from its own directory) and
     falls back to kernel32. Flags: `INHERIT_CURSOR` only.
  2. ConPTY 1.24 and older (and WezTerm's bundled build) keep their own
     reflowed buffer after a resize; theirs drops rows at the top and does
     not pull rows back when widening, so their cursor row disagrees with
     ours and PSReadLine's absolute CUPs land mid-screen. ConPTY 1.25
     (microsoft/terminal GH#18725) marks the cursor dirty after a resize
     and sends `ESC[6n` before the next console-API cursor query, adopting
     our position. Verified: 1.24.260710001 never sends the DSR;
     1.25.260710002-preview does, and the result matches macOS.
  3. Our core clears the prompt on resize (OSC 133 `redraw` defaults to
     true) expecting the shell to redraw; PSReadLine never redraws on
     resize, so the prompt vanished. `ghostty.ps1` now emits
     `OSC 133;A;redraw=0` (flag is sticky; oh-my-posh's own `133;A` has no
     option and leaves it alone). No `src/terminal` change.
     Distribution: `dist/windows/make-zip.ps1` (default; `-NoConpty` skips it) downloads the pinned
     NuGet package `Microsoft.Windows.Console.ConPTY` 1.25.260710002-preview
     (SHA-256 pinned) and stages `conpty.dll` + `OpenConsole.exe` into `bin\`;
     `-ConptyVersion`, `-ConptyDir` override. The installer ships `bin\*` and
     deletes stale copies on upgrade. Package layout: `runtimes\win-<arch>\
native\conpty.dll`, `build\native\runtimes\<arch>\OpenConsole.exe`.
     Byte-dump technique: add `log.warn("PTYRAW {x}", .{data});` in
     `threadMainWindows` `.data =>` (`src/termio/Exec.zig`), build to a scratch
     prefix, restore the file.

## Out of scope

Password-input detection (no termios on Windows), `+ssh` ControlMaster.

## Wrap-up

Tick P4-03; record the breakaway decision and the investigation notes.
