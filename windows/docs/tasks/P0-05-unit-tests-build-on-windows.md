# P0-05 — The unit test binary builds and the Windows-relevant tests pass

**Phase:** P0 · **Depends on:** P0-03 · **Size:** S–M ·
**Touches:** individual test blocks (gating only), possibly `build.zig` test step.

## Goal

`zig build test` compiles `ghostty-test.exe` on Windows, and the tests
that matter for the port (`pty`, `Command`, `windows` font discovery,
`xdg`, `shell_integration`, `wgl`) pass. Tests that are POSIX-only are
skipped with the standard idiom rather than left failing. A list of
remaining failures is recorded so later tasks can pick them off.

## Why

Every later task says "run `zig build test -Dtest-filter=...`". That only
works if the test binary links. Upstream removed the Windows full-suite
CI job in 2026-08, so drift is likely.

## Read before starting (~120 lines)

- `build.zig:376-420` (the `ghostty-test` step: `baselineTarget`,
  `use_llvm`, `deps.add(test_exe)`, patchelf calls).
- `src/os/xdg.zig:160-215` and `src/Command.zig:680-700` for the skip idiom.
- `windows/docs/02-environment.md` section 3.

## Steps

1. `zig build test -Dtest-filter="pty"`. Fix link/compile errors in the
   test target first (they are usually the same class as P0-02 errors but
   in test-only code, or `deps.add` linking something the exe path did not).
2. `zig build test` (full). Let it run to completion; capture output to a
   file: `zig build test 2>&1 | Tee-Object -FilePath windows\test-run.log`
   (do not commit the log).
3. Triage each failure:
   - Test needs a POSIX facility (fork, `/tmp`, signals, `/bin/sh`,
     fontconfig): add `if (builtin.os.tag == .windows) return error.SkipZigTest;`
     at the top of that test.
   - Test exposes a real Windows bug in code the port relies on
     (`pty.zig`, `Command.zig`, `discovery.zig` Windows scanner,
     `Exec.zig` Windows tests at `:2226-2300`): fix if it is small, else
     record it under the task that owns that area (P1-03 for termio,
     P4-01 for fonts).
   - Test crashes the runner (segfault/unreachable): isolate with the
     filter, skip it, and record it in STATUS.md (no comment in the code).
4. Re-run the full suite and record pass/fail/skip counts.

## Acceptance

- `zig build test -Dtest-filter="pty"` passes.
- `zig build test -Dtest-filter="Command"` passes.
- `zig build test -Dtest-filter="windows"` passes (font discovery finds Arial).
- `zig build test` completes without crashing the runner. The remaining
  failures (if any) are listed in STATUS.md under "Known test failures"
  with the owning task.

## Gotchas

- The test target uses `baselineTarget` (baseline CPU, native OS), so
  SIMD dispatch differs from the exe; a SIMD-only failure is worth noting
  but not blocking.
- Some tests write to the temp dir; `GetTempPathW` is used on Windows
  (`src/os/file.zig:68-83`), so they should work. Tests assuming `/tmp`
  literally need skipping.
- Font tests scan `C:\Windows\Fonts` and can take a few seconds each.
- Keep skips narrowly scoped: skip a test, not a file.
- The full run prints `failed command: ...ghostty-test.exe ...` even when
  every test passes. That is the build runner echoing the command because
  `src/benchmark/TerminalFormatter.zig:405` writes to stderr via
  `std.debug.print` (upstream, all platforms). Check the Build Summary line
  and exit code, not that text.
- Use `--summary all` to get pass/skip counts; the default output is silent
  on success.

## Out of scope

Making every test pass. Fixing termio bugs (P1-03).

## Wrap-up

Tick P0-05, fill "Known test failures" in STATUS.md, delete
`windows\test-run.log`.
