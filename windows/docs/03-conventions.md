# 03 — Conventions for Windows code in this repo

These are the patterns already used by the Windows code that exists
(`src/os/windows.zig`, `src/pty.zig`, `src/Command.zig`, `src/termio/Exec.zig`).
Copy them. Do not invent a parallel style.

## Where code goes

| Kind                                                                                 | Location                                                                         |
| ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| Win32 GUI runtime (windows, input, clipboard, IME, message loop)                     | `src/apprt/win32/` with root `src/apprt/win32.zig` (mirror `src/apprt/gtk.zig`)  |
| GUI-side externs (user32, gdi32, dwmapi, shell32, imm32, opengl32/wgl)               | `src/apprt/win32/c.zig` (new; a hand-written bridge)                             |
| Kernel-side externs shared by non-GUI code (kernel32, ntdll, shell folders, console) | `src/os/windows.zig` under `exp.kernel32` / `exp.ntdll` / add `exp.shell32` etc. |
| OS helpers with per-OS branches (home dir, xdg, open URL, locale)                    | the existing file in `src/os/`, add a `.windows` prong                           |
| WGL context provider for the renderer                                                | `src/renderer/opengl/wgl.zig` (new), selected from `src/renderer/OpenGL.zig`     |
| Shell integration script for PowerShell                                              | `src/shell-integration/powershell/ghostty.ps1`                                   |
| Windows-only tests                                                                   | next to the code, gated (see below)                                              |

## Compile-time gating

Use the two idioms already in the tree:

```zig
// Whole-type selection (src/pty.zig:20)
pub const Pty = switch (builtin.os.tag) {
    .windows => WindowsPty,
    .ios => NullPty,
    else => PosixPty,
};

// Branch inside a function (src/termio/Exec.zig, many places)
if (comptime builtin.os.tag == .windows) {
    // Windows path
} else {
    // POSIX path
}
```

Rules:

- Never delete or weaken a POSIX/macOS branch to make Windows compile. Add
  a prong.
- Modules that only make sense on POSIX may `@compileError` on Windows the
  way `src/os/passwd.zig:32` does, as long as nothing references them on
  Windows. Zig analyses lazily, so an unreferenced decl is not a problem;
  a referenced one is.
- Exhaustive `switch (build_config.app_runtime)` statements exist in
  several files (list in `06-apprt-contract.md`). Adding `.win32` requires
  a prong in each; the compiler will tell you which ones you missed.

## Declaring Win32 functions

Declare by hand, in the style of `src/os/windows.zig`. Types come from
`std.os.windows` where they exist; otherwise define them locally.

```zig
const windows = @import("../../os/main.zig").windows;   // from src/apprt/win32/
const HWND = windows.HWND;

pub const user32 = struct {
    pub extern "user32" fn CreateWindowExW(
        dwExStyle: windows.DWORD,
        lpClassName: ?windows.LPCWSTR,
        lpWindowName: ?windows.LPCWSTR,
        dwStyle: windows.DWORD,
        X: c_int,
        Y: c_int,
        nWidth: c_int,
        nHeight: c_int,
        hWndParent: ?HWND,
        hMenu: ?windows.HMENU,
        hInstance: ?windows.HINSTANCE,
        lpParam: ?windows.LPVOID,
    ) callconv(.winapi) ?HWND;
};
```

- Always `callconv(.winapi)`.
- Prefer the `W` (UTF-16) variants of every API. Never call `A` variants
  for user-visible strings.
- Constants: `pub const WM_KEYDOWN = 0x0100;` grouped by header, no
  comments; the SDK name is the documentation. Do not paste whole
  headers; declare what you use.
- No inline documentation anywhere in the port (see `windows/CLAUDE.md`).
  A comment is reserved for a quirk that would otherwise get "fixed"
  wrongly; expect to write fewer than ten in the whole port.
- No dependency on zigwin32, and no translate-c of `windows.h`. Upstream
  chose a manual bridge because std's Windows layer is being pared down
  (`src/os/windows.zig:4-9`), and translate-c of `windows.h` is slow and
  fragile under MSVC.
- Libraries must be linked: add `user32`, `gdi32`, `dwmapi`, `shell32`,
  `imm32`, `opengl32`, `shcore` in the `.win32` prong of
  `src/build/SharedDeps.zig` (task P0-02). `kernel32`/`ntdll` are linked by
  Zig automatically.

## Errors

```zig
const h = c.user32.CreateWindowExW(...) orelse
    return windows.unexpectedError(windows.GetLastError());
```

`windows.unexpectedError` logs the code and returns `error.Unexpected`.
Use specific errors (`error.RegisterClassFailed`) where the caller can
react; otherwise `Unexpected` is fine. Never `unreachable` on an API
result that can fail at runtime (a lesson from `Exec.zig:1788-1797`).

## Strings

- Internal strings are UTF-8 (WTF-8 for paths from the OS).
- To Win32: `std.unicode.utf8ToUtf16LeAllocZ(alloc, s)` (used in
  `src/Command.zig:306`) or a stack buffer with `std.unicode.utf8ToUtf16Le`.
- From Win32: `std.unicode.utf16LeToUtf8Alloc` (`src/os/file.zig:76`) or
  `std.unicode.wtf16LeToWtf8` for paths (`src/lib/tinyio/windows.zig:197`).
- String literals for Win32: `std.unicode.utf8ToUtf16LeStringLiteral("Ghostty")`.

## Environment and process

- Read env through `global.environ().getAlloc(alloc, "NAME")` or an
  `Environ.Map` (`src/global.zig:274-290`). `std.posix.getenv` does not
  exist on Windows.
- Spawn children with `Command.zig`'s Windows path; do not call
  `CreateProcessW` from new code.
- Temp files: `internal_os.allocTmpDir` / `TempDir` (already Windows-aware).

## Threads

- The Win32 message loop and all `HWND` calls run on the main thread.
- The renderer thread owns the GL context after `threadEnter`; nothing
  else may make it current.
- The only cross-thread entry into the runtime is `App.wakeup()`, which
  must be safe to call from any thread (use `PostMessageW`).
- Register the surface window class with `CS_OWNDC` so the DC handed to
  the render thread is stable.

## Tests

```zig
test "windows: something" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    // ...
}
```

and the mirror image for POSIX-only tests. Run with
`zig build test -Dtest-filter="windows:"`.

## Logging

`std.log.scoped(.win32)` for runtime code, `.wgl` for the context
provider. Log at `.warn` for recoverable API failures, `.err` before
returning a fatal error, `.debug` for message traffic.

## Formatting and commits

- `zig fmt` every Zig file you touch.
- Keep unrelated formatting changes out of your diff.
- Commit messages follow the repo pattern `area: short description`
  (examples: `apprt/win32: add message loop`, `renderer/opengl: WGL
context provider`). Only commit when the user asks.
