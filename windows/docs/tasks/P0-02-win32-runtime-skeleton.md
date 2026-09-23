# P0-02 — Add the `win32` runtime: enum, stub module, build wiring

**Phase:** P0 · **Depends on:** P0-01 · **Size:** M ·
**Touches:** `src/apprt/runtime.zig`, `src/apprt.zig`, new `src/apprt/win32.zig`,
new `src/apprt/win32/{App,Surface,c}.zig`, `src/build/SharedDeps.zig`,
`src/config/Config.zig`, `src/os/desktop.zig`, `src/termio/Exec.zig`,
plus one-line prongs in the files listed below.

## Goal

`zig build -Dapp-runtime=win32` gets through the build graph and semantic
analysis of everything except the renderer. The runtime is a compiling
stub with every required function present; `run()` returns immediately.
Real behaviour comes in P1.

## Why

Two things block any Windows exe today: the `posix_c` translate-c step
includes `pwd.h`/`unistd.h` for all targets, and there is no runtime for
Windows so the build emits a DLL. Getting the skeleton to compile flushes
out every exhaustive switch and every stray POSIX reference outside the
renderer, in one contained task.

## Read before starting (~350 lines)

- `windows/docs/06-apprt-contract.md` (whole file).
- `windows/docs/03-conventions.md` sections "Where code goes",
  "Compile-time gating", "Declaring Win32 functions".
- `src/apprt/runtime.zig` (whole), `src/apprt.zig:40-53`, `src/apprt/gtk.zig`
  (whole; the 17-line module pattern), `src/apprt/none.zig` (whole).
- `src/apprt/gtk/App.zig:1-80` (the thin App wrapper), and
  `src/apprt/gtk/Surface.zig` (grep `pub fn` to see the minimal method set).
- `src/build/SharedDeps.zig:195-232` (translate-c steps, `pty-c` gating
  pattern), `:655-700` (runtime switch and glad linking).
- `src/build/GhosttyExe.zig:43-51`, `build.zig:225-250` (exe install
  keyed on `app_runtime != .none`).
- `src/os/passwd.zig:15-35` (how `posix_c` is already guarded).
- `src/config/Config.zig:60` and the three `switch (build_config.app_runtime)`
  sites at about `:4818, :9266, :9988` (use `grep -n "app_runtime" src/config/Config.zig`).

## Steps

1. **Runtime enum.** In `src/apprt/runtime.zig` add `win32` (match the
   neighbouring one-line style only because the file already has it) and
   make `default()` return `.win32` for `.windows`.
2. **Selection.** In `src/apprt.zig` add `pub const win32 = @import("apprt/win32.zig");`
   and the `.win32 => win32` prong.
3. **Stub module.** Create:
   - `src/apprt/win32.zig`: re-export `App`, `Surface`, `resourcesDir`
     (`pub const resourcesDir = internal_os.resourcesDir;`), same shape as
     `gtk.zig`.
   - `src/apprt/win32/App.zig`: `App` struct with `core_app`, `config`,
     and every function from the contract. `init` loads config exactly
     like GTK does (`Config.load`, `finalize`, `core_app.updateConfig`).
     `run` logs "win32 runtime stub" and returns. `wakeup` is a no-op.
     `performAction` is `switch (action) { else => return false }`.
     `performIpc` returns false.
   - `src/apprt/win32/Surface.zig`: `Surface` struct with the fields from
     the contract (`core_surface`, `app`, `hwnd: ?HWND`, `size`,
     `content_scale`, `cursor_pos`, `title`) and every method returning
     the stored value; `close` calls `deleteSurface`/`deinit`;
     `clipboardRequest` returns `.unsupported`; `setClipboard` is a no-op.
   - `src/apprt/win32/c.zig`: an empty bridge file with the `windows`
     import and a `user32` namespace ready for P1 (a couple of typedefs
     like `HWND` are enough).
     Do **not** make the stub `@compileError` on non-Windows; it is simply
     never selected there.
4. **Exhaustive switches.** Add `.win32` prongs to every site in
   `06-apprt-contract.md` "Places that switch exhaustively". Let the
   compiler find any others.
5. **Build wiring.** In `SharedDeps.zig`:
   - Gate the `posix_c` translate-c step on `target.result.os.tag != .windows`
     (copy the `pty-c` pattern at `:201-214`).
   - In the `switch (self.config.app_runtime)` near `:691`, add
     `.win32 => { ... linkSystemLibrary("user32"/"gdi32"/"shell32"/"ole32"/
"dwmapi"/"shcore"/"imm32"/"opengl32", dynamic_link_opts) }`. On
     Windows these are import libraries resolved from the SDK (or built by
     Zig for the GNU ABI).
6. **posix_c importers.** Make them conditional:
   `const c = if (builtin.os.tag != .windows) @import("posix_c") else struct {};`
   in `src/os/desktop.zig:6` and `src/termio/Exec.zig:584`. Delete the dead
   import at `src/config/Config.zig:60` (verify with `grep -n "\bc\." src/config/Config.zig`
   that nothing uses it; if something does, guard instead of delete).
7. **Config default prong.** `src/config/Config.zig` apprt-specific
   defaults switch (~`:4818`): `.win32` behaves like `.none`/`.gtk` defaults
   for now (no Windows-only options yet).
8. Build: `zig build -Dapp-runtime=win32`. Iterate on compile errors that
   are **outside** `src/renderer/`. Typical ones: missing prongs, a
   `posix.*` use in a shared file. Fix each with a gated prong, never by
   removing POSIX code.

## Acceptance

- `zig build -Dapp-runtime=win32` either succeeds, or every remaining
  error is in `src/renderer/` (paste the list into STATUS.md).
- `zig build -Dapp-runtime=gtk` is untouched: confirm by `git diff --stat`
  that no GTK file changed, and that Linux-only files only gained prongs.
- `zig fmt --check src/apprt src/build src/config src/os src/termio` passes.

## Gotchas

- Zig analyses lazily: a function in the stub that references a missing
  type will only error once something calls it. The core calls all of
  them, so expect errors to appear only after the core compiles.
- `Config.load` signature: copy from GTK's Application init rather than
  guessing; it takes an allocator and returns a `Config` you must
  `finalize()`.
- `linkSystemLibrary` with `dynamic_link_opts` is the established call;
  look at the `egl` line for the exact form.
- Do not add `opengl32` linking to the lib (`step.kind == .lib`) path;
  stay inside the exe-only block.
- The only semantic errors left after this task are the two in
  `src/renderer/Dmabuf.zig:44,55` (`fd_t` is a HANDLE on Windows). With
  those patched out temporarily, analysis completes and the link fails on
  `eglDestroyContext`/`eglGetError`/`eglMakeCurrent` (renderer, P0-03) and
  `WinMain` (`GhosttyExe.zig` sets `subsystem = .Windows` while linking
  libc, so the CRT wants `WinMain`; needs an entry-point fix, not covered
  by any task yet).
- `zig env` reports a `-gnu` native target, but `zig build` in this repo
  compiles `native-native-msvc`.

## Out of scope

Anything in `src/renderer/` (P0-03), running the app (P1), CLI output
(P0-04).

## Wrap-up

Tick P0-02 in STATUS.md, list the renderer errors that remain, and note
any file where you had to add a prong that is not in the contract list
(then add it to `06-apprt-contract.md`).
