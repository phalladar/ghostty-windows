# P4-04 — Presentation upgrade: vsync policy, flicker-free resize, optional DXGI interop

**Phase:** P4 · **Depends on:** P1-02, P3-03 · **Size:** M (vsync/resize) + L (DXGI, optional) ·
**Touches:** `src/renderer/opengl/wgl.zig`, `src/renderer/OpenGL.zig`,
`src/apprt/win32/Surface.zig`, optionally new `src/renderer/opengl/dxinterop.zig`.

## Goal

Rendering is smooth under DWM: no tearing, no stale-frame stretch during
resize, pacing tied to the display refresh, and (optionally) a DXGI
flip-model presentation that composes correctly with tabs/splits and
removes the classic Win32 GL resize flicker.

## Part A — vsync and resize polish (do this)

Read: `src/renderer/Thread.zig:120-170` (draw timer), `src/renderer/generic.zig`
vsync/`DisplayLink` gating (`:36-43`, grep `vsync`), `wgl.zig`.

1. Replace the P1-02 `wglSwapIntervalEXT` toggle with policy: interval 1
   when `window-vsync` is on; when off, use `DwmFlush()` after
   `SwapBuffers` to avoid tearing under composition without blocking on
   vblank. Measure frame time in debug logs.
2. Resize: on `WM_ENTERSIZEMOVE` set a flag; in `WM_SIZE` call
   `core_surface.draw()` synchronously (as P1-02 may already do) and
   `DwmFlush`; on `WM_EXITSIZEMOVE` clear. If black bars still appear,
   set the window class background brush to the terminal background
   colour (`WM_ERASEBKGND` paints it only while the resize flag is set).
3. Occluded/minimised: confirm `occlusionCallback(false)` stops the draw
   timer (Task Manager GPU usage ~0 when minimised).

Acceptance: no tearing in a scrolling `Get-ChildItem -Recurse C:\Windows\System32`
with vsync on; resize shows no black garbage; minimised uses no GPU.

## Part B — DXGI interop (optional; only if Part A leaves visible flicker or a WinUI host is planned)

Approach: `WGL_NV_DX_interop2` (supported by NVIDIA, AMD, Intel drivers):

1. Create a D3D11 device + `IDXGISwapChain1` (flip model,
   `DXGI_SWAP_EFFECT_FLIP_DISCARD`, `DXGI_FORMAT_B8G8R8A8_UNORM`, 2 buffers)
   for the surface HWND (`CreateSwapChainForHwnd`) or, for composition,
   `CreateSwapChainForComposition` + DirectComposition visual on the HWND.
2. `wglDXOpenDeviceNV(d3d_device)`; per back buffer, `wglDXRegisterObjectNV`
   as a GL renderbuffer/texture; per frame `wglDXLockObjectsNV`, blit the
   `Target` into it, `wglDXUnlockObjectsNV`, `Present(1, 0)`.
3. Resize: `ResizeBuffers` after unregistering the objects.
4. This replaces `SwapBuffers`; keep the plain WGL path as fallback when
   the extension is missing (log it).

Acceptance: identical output to Part A, but window resize is flicker-free
and `PresentMon` shows flip-model presentation.

## Gotchas

- `WGL_NV_DX_interop2` is missing on the Microsoft Basic Display Adapter
  and some virtual GPUs; always keep the fallback.
- COM lifetime: release swapchain buffers before `ResizeBuffers`.
- Do not mix `SwapBuffers` and DXGI present on the same HWND.
- (P4-04 result) A synchronous `core_surface.draw()` from the main thread is
  not possible with WGL: the context is current on the render thread and a
  context can be current on only one thread. Instead `Window` `WM_SIZE`
  waits (max 50 ms per leaf, stops after the first timeout) until each
  visible leaf of the active tab has presented a frame at its new client
  size (`wgl.Context.waitPresented`, signalled from `swapBuffers`), then
  calls `DwmFlush` while inside `WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE`.
- (P4-04 result) `window-vsync = false` now means interval 0 + `DwmFlush`
  after `SwapBuffers`, so it is paced by the compositor (240 fps on the
  240 Hz display) instead of 2000-3000 fps. The policy is read at context
  creation only; a config reload of `window-vsync` does not change it.
- (P4-04 result) With the monitor idle-off, interval 1 does not pace at all
  (about 3000 presents/s in ReleaseFast) while `DwmFlush` still paces at
  240/s. Only trust vsync numbers when `GetLastInputInfo` idle < 300 s.
- (P4-04 result) Debug builds render a scrolling `Get-ChildItem` at about
  30 fps, so the 50 ms resize wait times out there; ReleaseFast never did.
- Frame timing: `debug(wgl): present mode=... frames= avg_ms= max_ms=` once
  per second while presenting (Debug builds only).

## Wrap-up

Tick P4-04 (note whether Part B was done or skipped).
