# P0-01 — Install the toolchain and prove it with a lib-vt build

**Phase:** P0 · **Depends on:** nothing · **Size:** S · **Touches:** no source files

## Goal

Zig 0.16.0 and the MSVC toolset are installed, and the Windows build that
upstream CI already supports (`libghostty-vt`) succeeds on this machine.
This isolates toolchain problems from port problems.

## Read before starting

- `windows/docs/02-environment.md` sections 1 and 2 (install steps).
- `build.zig.zon:6` (`minimum_zig_version`), `src/build/zig.zig` (`requireZig`
  demands 0.16.x exactly).

## Steps

1. Install Zig: `winget install --id zig.zig --exact --version 0.16.0`.
   Open a fresh shell. `zig version` must print `0.16.0`. If the agent's
   shell cannot see it, prepend `%LOCALAPPDATA%\Microsoft\WinGet\Links`
   to PATH for the session and note that in STATUS.md.
2. Install the C++ workload into the existing Build Tools (elevated):
   the `setup.exe modify ... --add Microsoft.VisualStudio.Workload.VCTools
--includeRecommended` command in `02-environment.md`. If the user
   declines the 4 GB install, fall back to `-Dtarget=x86_64-windows-gnu`
   for every build command in this plan and record that decision in
   STATUS.md under "Decisions".
3. Enable Developer Mode and long paths (`02-environment.md`).
4. From the repo root: `zig build -Demit-lib-vt`. First run fetches
   dependencies and compiles simdutf/highway; allow 10 minutes.
5. `zig build test-lib-vt -Dtest-filter="Parser"` (any small filter) to
   prove the test runner works on Windows.
6. `zig build -Dapp-runtime=none` should also succeed today: it emits
   `ghostty-internal.dll`. Run it as a second smoke test; this exercises
   the full core (font, renderer, termio) compile for Windows as a DLL and
   surfaces any regression since upstream dropped their Windows job. If it
   fails inside `src/renderer/` or on `posix_c`, that is expected (see
   `04-current-state.md`) and is P0-02/P0-03 work; just record the first
   error verbatim in STATUS.md.

## Acceptance

- `zig version` → `0.16.0`.
- `zig build -Demit-lib-vt` exits 0 and `zig-out\lib\ghostty-vt.dll` (or
  `.lib`) exists.
- `zig build test-lib-vt -Dtest-filter="Parser"` exits 0.
- STATUS.md records: ABI chosen (msvc or gnu), whether step 6 passed, and
  the first error if it did not.

## Gotchas

- `requireZig` rejects dev builds and 0.15.x; do not install "latest".
- If `zig build` fails while unpacking a dependency with a symlink error,
  Developer Mode is not on.
- `zig build` with the MSVC ABI fails with "unable to find MSVC" or
  "libc headers" if the VCTools workload did not install the Windows SDK;
  re-run the installer with `--includeRecommended`.
- Defender can make the first fetch/compile very slow; see the exclusion
  tip in `02-environment.md`.

## Out of scope

Any source change. If something in the repo must change to build lib-vt,
stop and record it; that is a real upstream regression.

## Wrap-up

Update `windows/docs/STATUS.md`: tick P0-01, add the "Decisions" line
about the ABI, and the outcome of step 6.
