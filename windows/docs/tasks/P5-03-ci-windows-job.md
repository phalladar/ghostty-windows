# P5-03 — CI: a Windows job that builds the app and runs the tests

**Phase:** P5 · **Depends on:** P0-05 · **Size:** S ·
**Touches:** `.github/workflows/test.yml` (add a job; do not modify existing jobs).

## Goal

Every push builds `ghostty.exe` with `-Dapp-runtime=win32` on a Windows
runner and runs the Zig unit tests, so Windows regressions are caught
the way they were before upstream removed the job in 2026-08.

## Read before starting (~100 lines)

- `.github/workflows/test.yml:936-955` (`build-libghostty-vt-windows`:
  the runner label `namespace-profile-ghostty-windows`, the
  `mlugg/setup-zig` step, and the `required` aggregation job pattern).
- `git show 380778e3c --stat` (what the removed jobs looked like; use
  `git show 380778e3c -- .github/workflows/test.yml | head -120` to copy
  the old `test-windows` job body).

## Steps

1. Add `build-windows-app`: `runs-on: namespace-profile-ghostty-windows`
   (or `windows-2022` if the namespace runner is unavailable to this
   fork; note that GitHub's hosted `windows-2022` image has MSVC + SDK
   preinstalled), steps: checkout, setup-zig (version from `build.zig.zon`),
   `zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast`,
   `zig build test -Dapp-runtime=win32` (or without the runtime flag if
   tests do not need it), upload `zig-out\bin\ghostty.exe` as an artifact.
2. Add the job to the `required` needs-list only if the user wants it
   blocking; default: not required (advisory) until the suite is green.
3. Keep the `posix_c`/renderer gating honest: the job must run without
   `continue-on-error`.

## Acceptance

- The workflow file passes `actionlint` (if available) or at least YAML
  validation, and the job succeeds on the next push to the fork.

## Gotchas

- GL tests (`wgl`) will fail on hosted runners (no GPU / Basic Display
  Adapter): they must `SkipZigTest` when context creation fails with the
  version check, as P0-03 specified.
- Runner disk/time: the cold build of C++ deps takes several minutes;
  add Zig's global cache to `actions/cache` keyed on `build.zig.zon` hash.
  (Done via `mlugg/setup-zig`'s built-in cache with
  `cache-key: build-windows-app-${{ hashFiles('build.zig.zon') }}`; no
  pinned `actions/cache` SHA exists in the repo, and pinact checks pins.)
- The `skip` job is gated on `github.repository == 'ghostty-org/ghostty'`,
  so on a fork every job that `needs` it is skipped. `build-windows-app`
  uses `if: !failure() && !cancelled() && needs.skip.outputs.skip != 'true'`
  so it still runs when `skip` is skipped, and picks `windows-2022` via a
  `runs-on` expression when not on the upstream repo.
- `ghostty.exe` is uploaded before the test step, so the artifact exists
  even if tests fail. ReleaseFast uses `-mcpu=native` of the runner.
- Local actionlint (1.7.12) needs a config listing the
  `namespace-profile-*` labels as self-hosted, else it only reports
  unknown-label errors for every existing job.

## Out of scope

Release automation, signing.

## Wrap-up

Tick P5-03.
