# 05 — Architecture: how the pieces talk

Read this once before P1. It explains the threads, the mailboxes, and the
seams a Win32 runtime plugs into. `06-apprt-contract.md` has the exact
function list.

## Layers

```
main_ghostty.zig
  └─ App.create()                 core app (src/App.zig): surface list, mailbox
  └─ apprt.App.init(core_app)     runtime app (src/apprt/win32/App.zig): windows, loop, config
  └─ apprt.App.run()              the GUI event loop; must call core_app.tick(rt_app)

apprt.Surface (src/apprt/win32/Surface.zig)     one per terminal view; owns an HWND
  └─ core Surface (src/Surface.zig)             terminal state, input handling, config
       ├─ renderer.Thread  → GenericRenderer(OpenGL)   draws frames on its own thread
       ├─ termio.Thread    → termio.Exec               ConPTY reader/writer, child process
       └─ mailboxes                                    cross-thread messages
```

Selection is compile-time: `src/apprt.zig` picks the runtime module from
`build_config.app_runtime`. Every runtime exports `App`, `Surface`, and
`resourcesDir`.

## Threads

| Thread                     | Owner                     | Does                                                                                                     |
| -------------------------- | ------------------------- | -------------------------------------------------------------------------------------------------------- |
| main                       | runtime                   | `GetMessageW` loop, WndProcs, all HWND/clipboard/IME calls, `core_app.tick`                              |
| renderer (one per surface) | `src/renderer/Thread.zig` | xev loop; `threadEnter` makes the GL context current; draws on timer/wakeup; `present`                   |
| termio (one per surface)   | `src/termio/Thread.zig`   | xev loop; writes to the pty; on Windows a separate blocking `ReadFile` thread feeds it (`Exec.zig:1773`) |
| xev process watcher        | libxev                    | child exit                                                                                               |

## Mailboxes and wakeups

- Any thread may push to `App.Mailbox` (`src/App.zig:578-595`). The push
  calls `rt_app.wakeup()`. The runtime must then, on the main thread,
  call `core_app.tick(rt_app)`, which drains the mailbox
  (`App.zig:265-298`). Win32: `wakeup` posts `WM_APP+n` to a message-only
  window; the handler calls `tick`.
- Surface-level messages (`src/apprt/surface.zig:14-157`) also arrive via
  the app mailbox as `surface_message` and end up as `performAction`
  calls on the runtime (table in `06-apprt-contract.md`).
- The renderer thread is woken by the core with
  `renderer_thread.wakeup.notify()`; the runtime never touches it.
- `quit`: the core sends `.quit` action; the runtime calls
  `PostQuitMessage`. `quit_timer` start/stop actions tell the runtime
  when the surface count hits/leaves zero (`App.zig:203, 237`).

## Surface lifecycle (order matters)

Model: `src/apprt/embedded.zig:504-632` and
`src/apprt/gtk/class/surface.zig:3460-3530`.

1. Runtime creates its `Surface` struct, creates the child HWND, and fills
   `size` (device pixels) and `content_scale` (dpi/96) **before** anything
   else, because `core.Surface.init` calls `getSize`/`getContentScale`.
2. `core_app.addSurface(rt_surface)`.
3. `cfg = apprt.surface.newConfig(core_app, &app_config, .window)`.
4. `core_surface.init(alloc, &cfg, core_app, rt_app, rt_surface)`. This
   synchronously performs `cell_size`, `size_limit`, maybe `set_title` and
   `initial_size`, then starts the renderer and termio threads.
5. Events flow: runtime → `core_surface.*Callback(...)`.
6. Teardown: `core_app.deleteSurface(rt_surface)`, `core_surface.deinit()`,
   destroy HWND, free.

## Rendering on Windows (decision from `01-strategy.md`)

Today (`src/renderer/OpenGL.zig`): `init` creates an EGL context on the
main thread; `threadEnter` makes it current on the render thread; each
frame renders to an FBO (`Target`) and `present` exports it (DMABUF or CPU
pixels); `Frame.complete` pushes it into a latest-wins slot and posts
`.redraw`, which reaches the runtime as the `render` action; GTK's widget
then pulls with `takeFrame()`.

Windows path (P1-02):

```
OpenGL.init (main thread)     → wgl.Context.init(hwnd)   // pixel format + wglCreateContextAttribsARB 4.3 core
OpenGL.threadEnter (render)   → wgl.makeCurrent(); glad.load(wglGetProcAddress w/ opengl32 fallback)
OpenGL.present (render)       → glBlitFramebuffer(Target FBO → 0), SwapBuffers(hdc); return null
Frame.complete                → if present returned null: skip pushFrame/.redraw
OpenGL.threadExit (render)    → wglMakeCurrent(null,null); glad.unload()
```

The runtime supplies the HWND through its `Surface` struct (a `hwnd`
field read by `OpenGL.init` under `comptime builtin.os.tag == .windows`).
The surface's window class uses `CS_OWNDC`; the runtime never draws into
that HWND (WM_PAINT validates, WM_ERASEBKGND returns 1). One context per
surface; no sharing needed.

`Dmabuf` and the EGL fields must not be analysed on Windows: select the
provider type at comptime and keep `ExportedFrame` compiling (a stub
`Dmabuf` type on Windows is acceptable).

## Input on Windows (P1-04, P2-01)

`WM_KEYDOWN/WM_SYSKEYDOWN/WM_KEYUP/WM_SYSKEYUP` → build `input.KeyEvent`:

- `key`: scancode `((lParam >> 16) & 0xFF) | (extended ? 0xE000 : 0)`,
  looked up in `input.keycodes.entries` by `.native` (linear scan like
  `embedded.zig:115-124`).
- `mods`: `GetKeyState` for shift/ctrl/alt/win, caps/num lock toggles;
  left/right sides from `VK_L*`/`VK_R*`.
- `utf8`: `ToUnicodeEx(vk, sc, keystate, buf, len, 0x4, hkl)`; flag `0x4`
  avoids mutating dead-key state (Windows 10 1607+). Result `-1` = dead
  key → `composing = true`. AltGr = LCtrl+RAlt: if the layout yields a
  character with ctrl+alt held, report it and put ctrl+alt into
  `consumed_mods`.
- `unshifted_codepoint`: same call with shift/caps cleared.
- Core call: `core_surface.keyCallback(event)`; if it returns `.closed`,
  stop touching the surface.

Mouse: `WM_*BUTTONDOWN/UP`, `WM_MOUSEMOVE`, `WM_MOUSEWHEEL` (delta/120),
`WM_MOUSEHWHEEL`, `TrackMouseEvent` for leave, `SetCapture` while a
button is down. Store the last position for `getCursorPos`.

## Process I/O on Windows

`Command.startWindows` + `WindowsPty` already spawn the shell under a
pseudo console. The runtime's `defaultTermioEnv` returns the base env
(`global.environMap()`); `Exec.zig` adds `TERM`, `COLORTERM`,
`TERM_PROGRAM`, `GHOSTTY_RESOURCES_DIR`, shell-integration vars.

## IPC (later)

`+new-window`/`+new-tab` call the static `App.performIpc`. Win32 plan:
find the running instance's message-only window by class name
(`FindWindowW`) and send `WM_COPYDATA` with a small versioned struct.
Returning `false` (no instance) makes the CLI start a new process.
