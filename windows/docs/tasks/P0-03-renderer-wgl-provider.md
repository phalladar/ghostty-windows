# P0-03 — Make the OpenGL renderer build on Windows: WGL context provider and direct present

**Phase:** P0 · **Depends on:** P0-02 · **Size:** L ·
**Touches:** `src/renderer/OpenGL.zig`, new `src/renderer/opengl/wgl.zig`,
`src/renderer/opengl/Frame.zig`, `src/renderer/opengl/Target.zig` (small),
`src/renderer/Dmabuf.zig` or its import site, `src/renderer/generic.zig` (small),
`src/apprt/win32/Surface.zig` (`hwnd` field only).

## Goal

`zig build -Dapp-runtime=win32` links `zig-out\bin\ghostty.exe`. On
Windows the renderer creates an OpenGL 4.3 core context with WGL against
the surface's HWND, renders to the existing offscreen `Target`, and
presents by blitting into the window backbuffer and calling
`SwapBuffers`. Linux/macOS behaviour is unchanged.

## Why

The renderer is EGL-only and exports frames as Linux DMABUFs
(`04-current-state.md`, Renderer). Nothing else in the port can be tested
until this compiles. The design decision (direct present rather than CPU
readback) is in `01-strategy.md`.

## Read before starting (~500 lines)

- `windows/docs/05-architecture.md`, section "Rendering on Windows".
- `src/renderer/OpenGL.zig` whole file (457 lines): fields `egl_display`/
  `egl_context` (`:44-47`), `init` (`:49-103`), `prepareContext` (`:185-212`),
  `threadEnter`/`threadExit` (`:218-231`), `setViewport` (`:248-253`),
  `present` + `ExportedFrame` (`:294-332`).
- `src/renderer/opengl/Frame.zig:50-90` (`complete`: present → pushFrame → `.redraw`).
- `src/renderer/opengl/Target.zig` (grep `exportDmabuf`, `readPixelsAlloc`,
  `fbo`, `width`, `height`; note the Y-flip and `GL_FRAMEBUFFER_SRGB` handling
  in `exportDmabuf`).
- `src/renderer/Dmabuf.zig:1-60` (uses `std.posix.fd_t`, `posix.system.close`).
- `src/renderer/generic.zig:983-1033` (`LatestFrame`, `pushFrame`, `takeFrame`)
  and `:870-968` (which optional API hooks exist: `threadEnter`, `threadExit`,
  `loopEnter`, `displayRealized`, `present`, ...).
- `pkg/opengl/glad.zig:1-40` (`load(getProcAddress)` accepts a function or `null`).
- `vendor/glad/src/gl.c:895-935` (built-in Win32 loader: `opengl32.dll` +
  `wglGetProcAddress`, so `glad.load(null)` works on Windows).
- `src/build/GhosttyExe.zig` (Windows `subsystem`/`entry` block).
- `pkg/opengl/Framebuffer.zig:1-40` (`bind` returns a `Binding`; no default-FBO constant, use `.{ .id = 0 }`).
- `src/renderer/Options.zig` (what `init` receives: `rt_surface`, `surface_mailbox`, config).

## Design

`src/renderer/opengl/wgl.zig` exposes:

```zig
pub const Context = struct {
    hwnd: HWND, hdc: HDC, hglrc: HGLRC,
    pub fn init(hwnd: HWND) !Context;      // main thread
    pub fn deinit(self: *Context) void;    // main thread, after threadExit
    pub fn makeCurrent(self: *const Context) !void;   // render thread
    pub fn releaseCurrent() void;                      // wglMakeCurrent(null, null)
    pub fn swapBuffers(self: *const Context) !void;
    pub fn setSwapInterval(self: *const Context, interval: c_int) void; // wglSwapIntervalEXT if present
};
pub fn getProcAddress(name: [*:0]const u8) ?*const anyopaque; // wglGetProcAddress, fallback GetProcAddress(opengl32)
```

`init(hwnd)`:

1. Register a tiny dummy window class + window (`CS_OWNDC`), `GetDC`,
   `ChoosePixelFormat`/`SetPixelFormat` with a basic `PIXELFORMATDESCRIPTOR`
   (`PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER`, 32-bit
   color, 8 alpha, 0 depth/stencil), `wglCreateContext`, `wglMakeCurrent`.
2. Load `wglGetExtensionsStringARB`, `wglChoosePixelFormatARB`,
   `wglCreateContextAttribsARB`, `wglSwapIntervalEXT` via `wglGetProcAddress`.
   Require `WGL_ARB_create_context_profile` and `WGL_ARB_pixel_format`;
   `WGL_EXT_swap_control` and `WGL_ARB_framebuffer_sRGB` are optional.
3. Destroy the dummy context/window.
4. On the real `hwnd`: `GetDC` (the window class must be `CS_OWNDC`),
   `wglChoosePixelFormatARB` with `WGL_DRAW_TO_WINDOW_ARB=1`,
   `WGL_SUPPORT_OPENGL_ARB=1`, `WGL_DOUBLE_BUFFER_ARB=1`,
   `WGL_PIXEL_TYPE_ARB=WGL_TYPE_RGBA_ARB`, `WGL_COLOR_BITS_ARB=32`,
   `WGL_ALPHA_BITS_ARB=8`, `WGL_DEPTH_BITS_ARB=0`, `WGL_STENCIL_BITS_ARB=0`,
   optionally `WGL_FRAMEBUFFER_SRGB_CAPABLE_ARB=1`. `SetPixelFormat` once.
5. `wglCreateContextAttribsARB(hdc, null, attribs)` with major 4, minor 3,
   `WGL_CONTEXT_PROFILE_MASK_ARB = WGL_CONTEXT_CORE_PROFILE_BIT_ARB`, and
   `WGL_CONTEXT_DEBUG_BIT_ARB` in Debug builds. Then `wglMakeCurrent(null, null)`
   so the render thread can take it.

`OpenGL.zig` changes (all under `comptime builtin.os.tag == .windows`
selection so other OSes are byte-for-byte unaffected):

- Replace the two EGL fields with a comptime-selected provider:
  `const Provider = if (windows) wgl.Context else EglState;` and store
  `provider: Provider`. Keep the EGL code path exactly as is for others.
- `init`: on Windows, `opts.rt_surface.hwnd.?` → `wgl.Context.init`.
- `threadEnter`: on Windows, `makeCurrent()` then
  `prepareContext(&wgl.getProcAddress)` (or `gl.glad.load(null)` if the
  glad `load` signature makes that simpler; both are valid).
- `threadExit`: `releaseCurrent()`; `glad.unload()`.
- `present`: change the return type to `!?ExportedFrame`. On Windows:
  bind `Target` FBO as read, FBO 0 as draw, disable `GL_FRAMEBUFFER_SRGB`
  the same way `Target.exportDmabuf` does, `glBlitFramebuffer` with the
  Y-flip, `swapBuffers()`, return `null`. On other OSes return the frame
  as today.
- `ExportedFrame.dmabuf`: make the `Dmabuf` type a comptime stub on
  Windows (`if (windows) struct { pub fn deinit(_: @This()) void {} } else @import("../Dmabuf.zig")`),
  and make sure `Target.exportDmabuf` is not referenced on Windows.
- `Frame.complete` (`Frame.zig:64-83`): handle the optional; only
  `pushFrame` + `.redraw` when a frame came back.
- `setViewport`, `surfaceSize`: unchanged; the viewport comes from the
  core's `.resize` message in device pixels.

Also add `hwnd: ?HWND` to the win32 `Surface` struct if P0-02 did not.

## Steps

1. Write `wgl.zig` with hand-declared externs for `opengl32` (`wglCreateContext`,
   `wglDeleteContext`, `wglMakeCurrent`, `wglGetProcAddress`, `wglGetCurrentContext`),
   `gdi32` (`ChoosePixelFormat`, `SetPixelFormat`, `DescribePixelFormat`,
   `SwapBuffers`), `user32` (`RegisterClassExW`, `CreateWindowExW`,
   `DestroyWindow`, `GetDC`, `ReleaseDC`, `DefWindowProcW`, `UnregisterClassW`),
   `kernel32` (`GetModuleHandleW`, `LoadLibraryW`, `GetProcAddress`).
   Declare only the WGL_ARB constants you use, named exactly as in the extension specs.
2. Make the `OpenGL.zig` edits above.
3. Build until `ghostty.exe` links. Renderer-adjacent compile errors in
   `generic.zig`/`Thread.zig` that are Windows-specific (e.g. a Darwin-only
   field) get the same gating treatment.
4. No runtime test is possible yet (the runtime is a stub). Add a
   Windows-gated unit test in `wgl.zig` that creates a context on a
   hidden window and checks `glGetString(GL_VERSION)` starts with "4."
   (guard with `SkipZigTest` if no GL 4.3 is available, e.g. under RDP).

## Acceptance

- `zig build -Dapp-runtime=win32` exits 0; `zig-out\bin\ghostty.exe` exists.
- `zig build test -Dtest-filter="wgl"` passes on this machine (RTX 4090).
- `git diff src/renderer` shows every Windows change behind a comptime
  condition; the EGL/DMABUF paths are textually intact.

## Gotchas

- `wglGetProcAddress` returns 0, 1, 2, 3, or -1 for failure and returns
  NULL for GL 1.1 core entry points; always fall back to
  `GetProcAddress(GetModuleHandleW(L"opengl32.dll"), name)`.
- A pixel format can be set once per HWND. Never call `SetPixelFormat`
  on the dummy and the real window with the same DC.
- The context may be current on only one thread. `init` runs on the main
  thread and must release it before the render thread calls `threadEnter`.
- `GL_FRAMEBUFFER_SRGB` must be off during the blit or colours double-convert.
  `Target.exportDmabuf` shows the established handling.
- glad's MX context is `threadlocal`; `prepareContext` must run on the
  render thread after `makeCurrent`, exactly as the EGL path does.
- `OpenGL.zig:115` notes a calling-convention workaround for the debug
  callback on 32-bit Windows; leave it alone.
- The 4.3 requirement rules out RDP sessions. Do not lower it.
- No Y-flip when blitting `Target` into the window backbuffer: both are
  GL bottom-up. The flip in `exportDmabuf` exists only because apprts
  expect top-down images. Verify visually once P1-02 lands.
- The MSVC CRT with `/SUBSYSTEM:WINDOWS` looks for `WinMain`. Zig's
  `main` is used by setting `exe.entry = .{ .symbol_name = "mainCRTStartup" }`
  in `src/build/GhosttyExe.zig` (msvc ABI only).
- `wgl.getProcAddress` must be `callconv(.c)`; glad calls it as a C
  function pointer through `@ptrCast`.
- Tests in `wgl.zig` are only collected because `OpenGL.zig` has a
  Windows-gated `test { _ = wgl; }` block.

## Out of scope

Vsync policy, resize smoothness, DXGI interop (P4-04). Actually seeing
pixels requires the runtime (P1-01/P1-02).

## Wrap-up

Tick P0-03. Record the GL vendor/version string the test printed. If you
had to touch `generic.zig` or `Thread.zig`, list the lines in STATUS.md.
