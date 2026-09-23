# P5-04 — Crash reporting on Windows: decide and implement the minimum

**Phase:** P5 · **Depends on:** P5-01 · **Size:** S (minidump) or M (Sentry) ·
**Touches:** `src/crash/*`, `src/build/Config.zig` (`sentry` default), `pkg/sentry/build.zig` (only if enabling Sentry).

## Goal

A crash leaves something actionable on disk. Either Sentry's native SDK
runs on Windows (it supports it; the repo just disables it), or a
lightweight `MiniDumpWriteDump` handler writes `.dmp` files into the
crash directory that `+crash-report` already lists.

## Read before starting (~200 lines)

- `src/crash/sentry.zig:50-80` (Windows early return) and `:200-230`.
- `src/crash/dir.zig` (`xdg.state`-based crash dir), `src/cli/crash_report.zig`.
- `src/build/Config.zig:224-235` (`sentry` default), `pkg/sentry/build.zig:41-107`
  (Windows sources already listed: dbghelp unwinder, `sentry_*_windows.c`,
  breakpad backend).
- `src/global.zig:180-195` (crash init site), `src/main.zig` (root `panic`),
  `src/main_ghostty.zig:214` (`std_options`), zig `lib/std/debug.zig`
  `defaultPanic`/`handleSegfaultWindows`.

## Decision guidance

- **Minidump (recommended for now):** `SetUnhandledExceptionFilter` →
  `MiniDumpWriteDump(MiniDumpWithIndirectlyReferencedMemory | MiniDumpWithThreadInfo)`
  to `<crash dir>\<timestamp>.dmp`; ~80 lines, no new deps, works with
  WinDbg and the PDB from P0-01. Also install `std.debug`'s panic
  handler output to a `.txt` next to it. Users can attach the dump to
  bug reports. Privacy: opt-in prompt not required since nothing is
  uploaded.
- **Sentry:** flip the Windows default, build `pkg/sentry` with the
  breakpad backend for MSVC, verify it links (it needs `dbghelp`,
  `shlwapi`, `version`), and keep the existing consent flow. Only worth
  it once there is a public Windows release.

## Steps (minidump path)

1. Externs: `SetUnhandledExceptionFilter`, `MiniDumpWriteDump` (dbghelp;
   link `dbghelp`), `EXCEPTION_POINTERS`, `MINIDUMP_EXCEPTION_INFORMATION`.
2. In `src/crash/` add a Windows-gated `installMinidumpHandler()` called
   from `global.init` where `sentry.init` is called today.
3. Write the dump; then let the process die (return
   `EXCEPTION_EXECUTE_HANDLER`).
4. Test with a hidden `+crash` action or an env-gated `@panic` (do not
   ship the trigger; use a debug-only build flag), then open the dump in
   WinDbg and confirm symbols resolve.

## Acceptance

- Forced crash produces `%LOCALAPPDATA%\ghostty\crash\<ts>.dmp` and
  `ghostty +crash-report` lists it.
- WinDbg `!analyze -v` shows a Zig stack with function names.

## Gotchas

- Zig's own panic handler catches Zig panics before SEH; ensure the
  minidump is written for both (call the dumper from a `panic` override
  in `std_options` on Windows, then fall through to the default).
- `MiniDumpWriteDump` must not allocate on the crashing heap
  excessively; prepare the file path at startup.
- In Zig 0.16 the panic override is a root `pub const panic` namespace
  (`std.debug.FullPanic(fn)`), not a `std_options` field. `src/main.zig`
  forwards `entrypoint.panic`; `src/main_ghostty.zig` picks
  `crash.minidump.panic` on Windows.
- std.debug's segfault handler (Debug/ReleaseSafe) is a _vectored_
  handler that aborts, so `SetUnhandledExceptionFilter` never sees AVs in
  those builds. `minidump.zig` adds its own first vectored handler for the
  same four codes only when `std.options.enable_segfault_handler` is on,
  then returns CONTINUE_SEARCH so Zig still prints its trace. In
  ReleaseFast only the unhandled filter runs.
- `MINIDUMP_EXCEPTION_INFORMATION` is `#pragma pack(4)` (16 bytes; pointer
  at offset 4). A unit test pins the layout.
- Debug-only trigger: `GHOSTTY_DEBUG_CRASH=panic|segfault|breakpoint`
  crashes inside `global.init` (compiled out unless `-Doptimize=Debug`).
  `ghostty +version` is enough to exercise it; set `XDG_STATE_HOME` to a
  scratch dir to keep dumps out of `%LOCALAPPDATA%`.
- No WinDbg/cdb on the dev box. Verified symbols with a dbghelp
  `StackWalk64` script (parses the dump, maps images with
  `LOAD_LIBRARY_AS_IMAGE_RESOURCE`, own `.pdata` lookup because
  `SymFunctionTableAccess64` returns nothing for a fake process handle).
- Stack overflow: the dump is written on the overflowing thread; it may
  fail. A watchdog thread writer would fix it (not done).
- `+crash-report` prints `( ago)` for reports younger than ~1 s
  (pre-existing duration formatting, not Windows-specific).

## Wrap-up

Tick P5-04 with the decision recorded.
