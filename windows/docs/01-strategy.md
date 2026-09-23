# 01 — Strategy and decision record

Written 2026-09-22 against repo HEAD `4ae9f1a2d` (Ghostty 1.3.2-dev, Zig 0.16.0).

## Goal

A native Windows 11 build of the full Ghostty terminal: `ghostty.exe`, built
with `zig build -Dapp-runtime=win32`, that opens a window, runs a shell
through ConPTY, renders with the existing OpenGL renderer, and grows toward
feature parity (tabs, splits, keybinds, clipboard, IME, shell integration).

## What already exists (summary; details in `04-current-state.md`)

Upstream has been making the _library_ (libghostty-vt) and the core compile
on Windows/MSVC since early 2026. As a result a surprising amount is done:

- ConPTY pseudo console, `CreateProcessW` spawning, a Windows reader thread.
- A `freetype_windows` font backend that scans `C:\Windows\Fonts`.
- Windows scancode column in the key table; `rundll32` URL opening.
- MSVC ABI default, all C/C++ deps build on MSVC, `dist/windows/` has an
  `.rc`, a PerMonitorV2 DPI manifest and an icon, and `GhosttyExe.zig`
  already sets the Windows GUI subsystem.
- A manual Win32 extern bridge in `src/os/windows.zig`.

What does not exist: any GUI runtime for Windows, any way to put a rendered
frame on a Windows screen, and nobody upstream is working on either.

## Decision: a native Win32 application runtime written in Zig

Ghostty selects an "apprt" (application runtime) at compile time. The
runtime owns windows, the event loop, input, and clipboard, and hosts the
shared core (`src/Surface.zig`, `src/App.zig`). We add a third runtime,
`win32`, next to `gtk` (Linux) and `embedded` (macOS Swift host).

Options considered:

| Option                                                  | Verdict    | Why                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Win32 apprt in Zig** (`src/apprt/win32/`)             | **Chosen** | One language, one toolchain, one `zig build`. Mirrors how `gtk` is structured. Uses the repo's existing hand-written extern style. Easiest for an agent to iterate on: edit, build, run, observe.                                                                                 |
| GTK4 on Windows                                         | Rejected   | Needs MSYS2/pkg-config GTK4 + libadwaita + generated gobject bindings + blueprint compiler on Windows; the GTK runtime also leans on D-Bus, portals, systemd, X11/Wayland. Non-native result.                                                                                     |
| C#/WinUI 3 host over libghostty C API (the macOS model) | Deferred   | Nicest UI long term, but the C API is explicitly unsupported on Windows (`src/global.zig:69`), `ghostty.h` has no Windows platform tag, and it adds a second toolchain (.NET, Windows App SDK, MSIX). The frame-export renderer design would suit a DirectComposition host later. |
| Revive the GLFW runtime                                 | Rejected   | Removed upstream July 2025; poor IME, DPI, and native-feature story.                                                                                                                                                                                                              |

## Decision: rendering path

The OpenGL renderer (rewritten Aug/Sep 2026) creates its own EGL context,
renders offscreen, and hands finished frames to the runtime as a Linux
DMABUF or as CPU pixels. Windows has neither EGL nor DMABUF.

Plan, in tiers:

1. **P1: WGL context + direct presentation.** Add a WGL context provider
   next to the EGL one, selected by `builtin.os.tag`. On Windows the render
   thread blits the offscreen target into the window backbuffer and calls
   `SwapBuffers`. No readback, no new graphics API, fast to get right. Each
   surface owns a child HWND with its own context.
2. **Fallback if (1) stalls:** keep the CPU `memory` export path and blit
   it with `StretchDIBits` in `WM_PAINT`. Slower (a `glReadPixels` per
   frame) but touches the renderer least.
3. **P4 (optional): DXGI interop.** Share the GL target with D3D11 via
   `WGL_NV_DX_interop2` and present through a flip-model swapchain or
   DirectComposition. This is the Windows analogue of DMABUF and gives
   flicker-free resize and a path to a WinUI host.

Requirements: OpenGL 4.3 core profile. Fine on any real GPU driver of the
last decade; not available over RDP or on the Microsoft Basic Display
Adapter. Document it; do not work around it in v1.

## Decision: terminal I/O

Keep ConPTY (`src/pty.zig`) and `Command.startWindows`. Fix the known bugs
(shutdown/EOF, handle leaks, inheritance) before building UI on top. Add a
Job Object for process-tree kill later.

## Decision: fonts

Keep `freetype_windows` (FreeType rasterising + HarfBuzz shaping + a
directory scanner). Improve the scanner (style matching, index cache,
locale-aware CJK fallback list). A DirectWrite discovery backend is a later,
separate task; it is not required to ship.

## Decision: defaults on Windows

- Default shell: `pwsh.exe` if on PATH, else `powershell.exe`, else
  `%COMSPEC%` (today the code uses `%COMSPEC%` only).
- Config file: `%APPDATA%\ghostty\config` (see `04-current-state.md` for
  what `src/os/xdg.zig` does today; the config-paths task fixes the rest).
- `TERM=xterm-256color` for ConPTY (ConPTY does not read terminfo; the
  `xterm-ghostty` entry only matters for WSL/SSH sessions).
- Target Windows 11 (build 22000+) only. Do not add Windows 10 fallbacks.
- x86_64 first. aarch64 should work with `-Dtarget=aarch64-windows-msvc`
  but is not tested in this plan.

## Phases and exit criteria

| Phase | Name                | Exit criterion                                                                                                                                                     |
| ----- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| P0    | Compile the world   | `zig build -Dapp-runtime=win32` produces `ghostty.exe`; `ghostty.exe +version` and `+list-fonts` print output; unit tests build.                                   |
| P1    | Hello terminal      | One window, one surface, shell prompt visible, typing works, resize works, close works.                                                                            |
| P2    | Daily-driver basics | Full keyboard (layouts, AltGr, dead keys, kitty protocol), mouse, clipboard, IME, DPI, dark title bar, config paths, PowerShell shell integration, URL open, bell. |
| P3    | Multi-surface       | Multiple windows, tabs, splits, goto/move keybinds, close/quit confirmations, child-exited UI.                                                                     |
| P4    | Depth               | Font discovery quality, DirectWrite fallback, job objects, vsync/DXGI, foreground-process info, desktop notifications, progress in taskbar.                        |
| P5    | Ship                | Manifest/icon/version info, release build, installer or winget zip, CI job, crash reporting decision.                                                              |

Tasks are numbered `P<phase>-<nn>`. Later phases may start before earlier
ones are complete when their prerequisites are met; STATUS.md tracks that.

## Principles for every task

1. Smallest change that passes the task's acceptance check.
2. Windows code never changes Linux/macOS behaviour; gate with comptime.
3. Match repo style so the work is upstreamable. Do not fork conventions.
4. Real acceptance checks: a command that was actually run on this machine.
5. One task per session. Update STATUS.md at the end of every session.

## Non-goals for v1

Quick terminal, global shortcuts, command palette, accessibility (UI
Automation), Mica/acrylic backdrops, MSIX Store packaging, Windows 10,
WSL-specific integration beyond `command = wsl.exe`, custom title-bar
drawing, touch keyboard, updater.
