# P1-02 — First pixels: presentation verified, resize, DPI, swap interval

**Phase:** P1 · **Depends on:** P1-01 · **Size:** M ·
**Touches:** `src/apprt/win32/{Surface,Window}.zig`, `src/renderer/opengl/wgl.zig`,
`src/renderer/OpenGL.zig` (small).

## Goal

The shell prompt is visible in the window. Resizing the window reflows
the terminal. Moving the window between monitors with different DPI
rescales the text. `window-vsync` maps to the WGL swap interval.

## Read before starting (~300 lines)

- `windows/docs/05-architecture.md` "Rendering on Windows".
- `src/renderer/OpenGL.zig`: `present` and `setViewport` as changed in P0-03.
- `src/renderer/generic.zig:1681-1720` (`drawFrameLocked` uses
  `api.surfaceSize()`), `:1200-1260` (how `.resize` and `.visible`
  messages reach the renderer; grep `fn resize` / `.resize =>`).
- `src/Surface.zig:2502-2570` (`sizeCallback`: sends renderer `.resize`
  and pty resize), `:3667-3700` (`contentScaleCallback`), `:883-940` (`draw`).
- `src/apprt/gtk/class/surface.zig:3383-3460` (`renderSurfaceResize`:
  the order of `contentScaleCallback` then `sizeCallback`).
- `src/config/Config.zig`: grep `window-vsync`.

## Steps

1. **Verify the present path.** Run the app; if the window stays black:
   - Log `glGetError` after the blit and after `SwapBuffers`.
   - Check the pixel format actually set (`GetPixelFormat`/`DescribePixelFormat`)
     is the one chosen.
   - Check `setViewport` was called with the client size (the core sends
     `.resize` during `Surface.init`; if the render thread starts before
     the first size, it draws 0×0).
   - Confirm `WM_PAINT` only validates and `WM_ERASEBKGND` returns 1 so
     GDI does not paint over GL.
2. **Resize.** Child `WM_SIZE` → update `self.size` → `core_surface.sizeCallback`.
   During live resize Windows runs a modal loop inside `WM_SIZING`/
   `WM_ENTERSIZEMOVE`; the render thread keeps drawing on its own, so
   nothing extra is needed. If the client area shows garbage between
   frames, call `core_surface.draw()` from `WM_SIZE` (this is what the
   `draw` entry point exists for; it blocks until the frame is drawn).
   Do not add timers or throttling unless flicker is observed.
3. **DPI.** On `WM_DPICHANGED` (top-level): read the suggested `RECT*` in
   `lParam`, `SetWindowPos` to it, then for each surface update
   `content_scale = dpi/96` and call `contentScaleCallback` **before**
   `sizeCallback` (GTK order). The manifest already declares
   PerMonitorV2, so child windows get correct client rects.
4. **Swap interval.** In `wgl.Context.init`, after the real context is
   created, call `wglSwapIntervalEXT(1)` if `config.@"window-vsync"` is
   true else `0`. The renderer has access to the config via
   `rendererpkg.Options`; check how `generic.zig` reads config and
   thread it through, or set it once in `threadEnter` (must be current).
5. **Occlusion.** `WM_SIZE` with `SIZE_MINIMIZED` → `occlusionCallback(false)`;
   restored → `occlusionCallback(true)`. This stops rendering when
   minimised (`Surface.zig:3339`).
6. **Cell-size resize hints (optional):** handle `cell_size` action to
   store the cell size and, if cheap, snap the window in `WM_SIZING` to
   whole cells (macOS/GTK do this via resize increments). Skip if it
   costs more than 30 lines.

## Acceptance

- Prompt visible in default font; text is crisp (no bilinear blur), which
  confirms device-pixel sizing.
- Dragging the window corner reflows text; `stty size` in a Git Bash or
  WSL shell (or `$Host.UI.RawUI.WindowSize` in pwsh) reports the new size.
- With two monitors at different scale factors (or by changing display
  scale in Settings), text rescales without distortion.
- `--window-vsync=false` yields a higher frame rate in a tight
  `while ($true) { Get-Date }` loop than `true` (observe with the
  renderer's debug logging or Task Manager GPU utilisation; exact numbers
  are not required).

## Gotchas

- `WM_DPICHANGED` arrives at the top-level window only; propagate to children.
- Zig's `f32` `content_scale` must be `dpi / 96.0` exactly (e.g. 1.25, 1.5).
- `SwapBuffers` with interval 1 blocks the render thread up to one
  vblank; that is intended and matches macOS behaviour.
- If the NVIDIA driver's "threaded optimization" causes stutter in debug,
  ignore; it is a debug-build artefact.
- The present blit needs no Y-flip: FBO row 0 and the window's default
  framebuffer row 0 are both bottom-left, so the image comes out upright.
- Call `contentScaleCallback` in the top-level `WM_DPICHANGED` _before_
  `SetWindowPos(suggested rect)`; the child's `WM_DPICHANGED_AFTERPARENT`
  arrives after the resize, too late for GTK order.
- libxev's IOCP `Async` keeps its waiter inside the struct, so a by-value
  copy (e.g. `Surface.zig` `.renderer_wakeup = render_thread.wakeup`)
  never wakes the loop (renderer redrew only on timers, ~2 fps). Fixed by
  making termio's `renderer_wakeup` a `*xev.Async` pointing at
  `Surface.renderer_thread.wakeup`. Never copy an `xev.Async` by value
  after it may be waited on or notified from another thread.
- To test DPI without a second monitor, change the scale via
  `DisplayConfigSetDeviceInfo` (type -4, relative scale step) and restore
  it; a `WM_DPICHANGED` sent from another process had no effect.
- Screenshot with `PrintWindow(hwnd, hdc, 2)` from a PerMonitorV2-aware
  process, never `CopyFromScreen`.

## Out of scope

DXGI/flip-model presentation (P4-04), background opacity/transparency
(needs DWM blur; P4 optional), custom shaders verification.

## Wrap-up

Tick P1-02. Note whether `draw()` in `WM_SIZE` was needed.
