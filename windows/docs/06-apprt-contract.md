# 06 — The apprt contract (what `src/apprt/win32/` must implement)

Derived from `src/apprt/gtk/App.zig`, `src/apprt/gtk/Surface.zig`,
`src/apprt/embedded.zig`, and every `rt_app.*` / `rt_surface.*` call in
`src/App.zig` and `src/Surface.zig` at HEAD `4ae9f1a2d`. When in doubt,
`grep -n "rt_surface\.\|rt_app\." src/Surface.zig src/App.zig`.

## Module exports (`src/apprt/win32.zig`)

| Decl                    | Required                                                   | Used by                                               |
| ----------------------- | ---------------------------------------------------------- | ----------------------------------------------------- |
| `App`                   | yes                                                        | everywhere                                            |
| `Surface`               | yes                                                        | everywhere                                            |
| `resourcesDir`          | yes (`pub const resourcesDir = internal_os.resourcesDir;`) | `src/global.zig:219`                                  |
| `pre_exec`, `post_fork` | no (checked with `@hasDecl`)                               | `src/Command.zig:145,154`, `src/termio/Exec.zig:1051` |
| `App.startQuitTimer`    | no (`@hasDecl`)                                            | `src/main_ghostty.zig:111`                            |

## Places that switch exhaustively on `build_config.app_runtime`

Add a `.win32` prong to each (most are `=> void` / `=> {}`):
`src/apprt.zig:44`, `src/apprt/structs.zig:47,53,216`,
`src/apprt/surface.zig:170`, `src/apprt/action.zig:725`,
`src/datastruct/split_tree.zig:1327`, `src/config/Config.zig:4818,9266,9988`,
`src/font/face.zig:61`, `src/input/Binding.zig:995`,
`src/terminal/mouse.zig:84`, `src/build/SharedDeps.zig:691`.

## `App`

```zig
pub const App = struct {
    core_app: *CoreApp,
    config: Config,            // required by core App.keyEvent (App.zig:359)
    // ... hwnd for wakeups, window list, quit timer state

    pub fn init(self: *App, core_app: *CoreApp, opts: struct {}) !void;
    pub fn run(self: *App) !void;                 // GUI loop; calls core_app.tick(self) after each wakeup
    pub fn terminate(self: *App) void;
    pub fn wakeup(self: *App) void;               // ANY thread; PostMessageW to a message-only HWND
    pub fn performAction(
        self: *App,
        target: apprt.Target,                     // .app or .{ .surface = *CoreSurface }
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool;                                      // true = handled
    pub fn performIpc(                            // STATIC (no self); return false until P3
        alloc: Allocator,
        target: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        value: apprt.ipc.Action.Value(action),
    ) !bool;
};
```

Entry sequence (`src/main_ghostty.zig:100-114`): `App.create` (core) →
`app_runtime.init(core, .{})` → optional `startQuitTimer()` → `run()`;
`terminate()` on exit.

`init` must load the config: see `src/apprt/gtk/App.zig:30-44` and the
GTK `Application.init` for `Config.load(alloc)` + `config.finalize()` +
`core_app.updateConfig(self, &config)`.

## `Surface`

```zig
pub const Surface = struct {
    core_surface: CoreSurface,     // embedded, init'd in place
    app: *App,
    hwnd: HWND,                    // read by the WGL provider on Windows
    size: apprt.SurfaceSize,       // device px; keep current
    content_scale: apprt.ContentScale,
    cursor_pos: apprt.CursorPos,   // last mouse pos, surface-relative px
    title: ?[:0]const u8,

    pub fn core(self: *Surface) *CoreSurface;
    pub fn rtApp(self: *const Surface) *App;
    pub fn close(self: *Surface, process_active: bool) void;   // confirm if process_active, then deleteSurface + deinit
    pub fn getTitle(self: *Surface) ?[:0]const u8;
    pub fn getContentScale(self: *const Surface) !apprt.ContentScale;   // {x,y}: dpi/96
    pub fn getSize(self: *const Surface) !apprt.SurfaceSize;            // {width,height} device px
    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos;         // {x,y} f32
    pub fn supportsClipboard(self: *const Surface, c: apprt.Clipboard) bool; // .standard only
    pub fn clipboardRequest(self: *Surface, c: apprt.Clipboard, req: apprt.ClipboardRequest) !apprt.ClipboardReadResult;
    pub fn setClipboard(self: *Surface, c: apprt.Clipboard, contents: []const apprt.ClipboardContent, confirm: bool) !void;
    pub fn defaultTermioEnv(self: *Surface) !std.process.Environ.Map;  // global.environMap()
};
```

`getSize`/`getContentScale` must be valid **before** `core_surface.init`
(`Surface.zig:501, 529`). Call sites: `getCursorPos` at
`Surface.zig:1200,2775,3634,...`; `clipboardRequest` at `:6143`;
`setClipboard` at `:2218,2335,5103,5839,5933,6010`; `close` at `:842`;
`getTitle` at `:990`; `defaultTermioEnv` at `:638`.

Clipboard types (`src/apprt/structs.zig`): `Clipboard`
`{standard, selection, primary}`; `ClipboardContent{mime, data}`;
`ClipboardRequest` union `{paste, osc_52_read, osc_52_write, kitty_read,
kitty_write, list}`; `ClipboardReadResult` `{started, unavailable,
unsupported}`. After reading, call
`core_surface.completeClipboardRequest(req, .{ .contents, .available,
.confirmed, .remember })` (`Surface.zig:5900`); with `confirmed=false` it
may return `error.UnsafePaste`/`UnauthorizedPaste`, in which case show a
prompt and call again with `confirmed=true`, or `denyClipboardRequest`.

## Inputs the runtime feeds the core (`src/Surface.zig`)

| Function                                                                                 | Line      | Notes                                                             |
| ---------------------------------------------------------------------------------------- | --------- | ----------------------------------------------------------------- |
| `keyCallback(self, input.KeyEvent) !InputEffect`                                         | 2694      | `.ignored/.consumed/.closed`; on `.closed` stop using the surface |
| `keyEventIsBinding(self, input.KeyEvent) ?Binding.Flags`                                 | 2650      | for IME arbitration                                               |
| `textCallback(self, []const u8) !void`                                                   | 3328      | IME commit / paste-like text                                      |
| `preeditCallback(self, ?[]const u8) !void`                                               | 2571      | IME composition; null clears                                      |
| `imePoint(self) apprt.IMEPos`                                                            | 2123      | position for the candidate window                                 |
| `mouseButtonCallback(self, input.MouseButtonState, input.MouseButton, input.Mods) !bool` | 3820      | left=1, right=2, middle=3 (`input/mouse.zig:29-54`)               |
| `cursorPosCallback(self, apprt.CursorPos, ?input.Mods) !void`                            | 4562      | `(-1,-1)` on leave                                                |
| `scrollCallback(self, xoff: f64, yoff: f64, input.ScrollMods) !void`                     | 3486      | positive = up/right; `ScrollMods{precision, momentum}`            |
| `mousePressureCallback(...)`                                                             | 4498      | macOS only in practice                                            |
| `focusCallback(self, bool) !void`                                                        | 3368      | also `App.focusEvent(bool)` (`App.zig:329`)                       |
| `occlusionCallback(self, visible: bool) !void`                                           | 3339      | minimized → false                                                 |
| `sizeCallback(self, apprt.SurfaceSize) !void`                                            | 2502      | device px                                                         |
| `contentScaleCallback(self, apprt.ContentScale) !void`                                   | 3667      | WM_DPICHANGED                                                     |
| `colorSchemeCallback(self, apprt.ColorScheme) !void`                                     | 4755      | app-level: `App.colorSchemeEvent(rt_app, scheme)` (`App.zig:408`) |
| `refreshCallback(self) !void`                                                            | 3456      | queue a render                                                    |
| `draw(self) !void`                                                                       | 883       | synchronous draw (live resize)                                    |
| `displayRealized/displayUnrealized`                                                      | 2486/2492 | GPU availability                                                  |
| `updateConfig(self, *const Config) !void`                                                | 1747      | after reload                                                      |
| `needsConfirmQuit(self) bool`                                                            | 940       | before closing                                                    |

App-level: `App.keyEvent(rt_app, event) bool` (`App.zig:344`, global
keybinds; needs `rt_app.config`), `App.needsConfirmQuit()` (`:256`),
`App.updateConfig(rt_app, *const Config)` (`:164`),
`App.performAllAction` (`:486`).

`input.KeyEvent` (`src/input/key.zig:16-49`): `action` (press/release/
repeat), `key` (physical `input.Key`), `mods`, `consumed_mods`,
`composing`, `utf8`, `unshifted_codepoint`. `Mods` is a packed u16
(`src/input/key_mods.zig:29`): shift, ctrl, alt, super, caps_lock,
num_lock, plus left/right side bits.

## `performAction` variants (`src/apprt/action.zig:81-358`)

Tier: **MVP** = needed for P1/P2; nice = later; ignore = not on Windows.
Return `false` for anything unhandled; some have core fallbacks (noted).

| Action                                                                                                                                                                                                                                                                                                                              | Payload                                          | Tier   | Win32 note                                                                                        |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ | ------ | ------------------------------------------------------------------------------------------------- |
| `quit`                                                                                                                                                                                                                                                                                                                              | –                                                | MVP    | `PostQuitMessage(0)` after closing windows                                                        |
| `new_window`                                                                                                                                                                                                                                                                                                                        | –                                                | MVP    | create a top-level window; surface target → inherit config/cwd                                    |
| `close_window`                                                                                                                                                                                                                                                                                                                      | –                                                | MVP    | close focused window                                                                              |
| `present_terminal`                                                                                                                                                                                                                                                                                                                  | –                                                | MVP    | `SetForegroundWindow` + focus child                                                               |
| `size_limit`                                                                                                                                                                                                                                                                                                                        | `{min_width,min_height,max_width,max_height}` px | MVP    | enforce in `WM_GETMINMAXINFO`                                                                     |
| `initial_size`                                                                                                                                                                                                                                                                                                                      | `{width,height}` px                              | MVP    | size the client area on first show                                                                |
| `render`                                                                                                                                                                                                                                                                                                                            | –                                                | MVP    | no-op in direct-present mode (P1-02); `InvalidateRect` in fallback mode                           |
| `set_title`                                                                                                                                                                                                                                                                                                                         | `{title}`                                        | MVP    | `SetWindowTextW`                                                                                  |
| `mouse_shape`                                                                                                                                                                                                                                                                                                                       | `terminal.MouseShape`                            | MVP    | map to `IDC_*`, apply in `WM_SETCURSOR`                                                           |
| `mouse_visibility`                                                                                                                                                                                                                                                                                                                  | `visible/hidden`                                 | MVP    | `ShowCursor` or null cursor while typing                                                          |
| `quit_timer`                                                                                                                                                                                                                                                                                                                        | `start/stop`                                     | MVP    | honour `quit-after-last-window-closed` config                                                     |
| `reload_config`                                                                                                                                                                                                                                                                                                                     | `{soft}`                                         | MVP    | reload from disk unless soft; `core_app.updateConfig`                                             |
| `config_change`                                                                                                                                                                                                                                                                                                                     | `{config: *const Config}`                        | MVP    | apply window chrome (title bar theme etc.)                                                        |
| `open_url`                                                                                                                                                                                                                                                                                                                          | `{kind,url}`                                     | nice   | false → core uses `internal_os.open` (`Surface.zig:4471-4486`); fix `open.zig` to `ShellExecuteW` |
| `show_child_exited`                                                                                                                                                                                                                                                                                                                 | `ChildExited`                                    | nice   | false → core prints a message in the terminal                                                     |
| `ring_bell`                                                                                                                                                                                                                                                                                                                         | –                                                | nice   | `MessageBeep`/`FlashWindowEx`                                                                     |
| `desktop_notification`                                                                                                                                                                                                                                                                                                              | `{title,body}`                                   | nice   | `Shell_NotifyIconW` balloon or WinRT toast (later)                                                |
| `progress_report`                                                                                                                                                                                                                                                                                                                   | `ProgressReport`                                 | nice   | `ITaskbarList3::SetProgressValue`                                                                 |
| `new_tab`, `close_tab`, `move_tab`, `goto_tab`, `toggle_tab_overview`, `set_tab_title`, `move_tab_to_new_window`                                                                                                                                                                                                                    |                                                  | P3     | tabs                                                                                              |
| `new_split`, `goto_split`, `resize_split`, `equalize_splits`, `toggle_split_zoom`                                                                                                                                                                                                                                                   |                                                  | P3     | splits                                                                                            |
| `goto_window`, `toggle_maximize`, `toggle_fullscreen`, `toggle_window_decorations`, `set_window_title`, `prompt_title`, `reset_window_size`, `cell_size`, `float_window`, `toggle_visibility`, `close_all_windows`                                                                                                                  |                                                  | nice   | window management                                                                                 |
| `pwd`, `mouse_over_link`, `renderer_health`, `color_change`, `scrollbar`, `secure_input`, `key_sequence`, `key_table`, `selection_changed`, `command_finished`, `readonly`, `copy_title_to_clipboard`, `search_*`, `start_search`/`end_search`, `undo`/`redo`, `inspector`, `render_inspector`, `export_terminal_io`, `open_config` |                                                  | nice   | mostly no-ops at first; `open_config` → open file with default editor                             |
| `show_gtk_inspector`, `check_for_updates`, `toggle_quick_terminal`, `toggle_command_palette`, `show_on_screen_keyboard`, `toggle_background_opacity`                                                                                                                                                                                |                                                  | ignore | return false                                                                                      |

GTK's dispatch (`src/apprt/gtk/class/application.zig:683-834`) is the
reference for which actions it also skips.

## Surface mailbox messages → actions

The runtime never drains these itself; `core_app.tick` does. Listed so
you know which actions arrive asynchronously: `set_title`→`set_title`,
`set_mouse_shape`→`mouse_shape`, `clipboard_read`→`clipboardRequest`,
`clipboard_write`→`setClipboard`, `close`→`rt_surface.close`,
`child_exited`→`show_child_exited`, `present_surface`→`present_terminal`,
`ring_bell`→`ring_bell`, `pwd_change`→`pwd`, `progress_report`,
`desktop_notification`, `renderer_health`, `password_input`→`secure_input`,
`color_change`, `scrollbar`, `search_*`, `start/stop_command`→`command_finished`,
**`redraw`→`render`** (`Surface.zig:1722-1731`).

## The embedded runtime, for comparison

`src/apprt/embedded.zig` keeps `size`, `content_scale`, `cursor_pos`,
`title` on the Surface struct and answers the getters from those fields
(`:447-460`). Copy that pattern. Its `keyEvent` (`:202-230`) and the
keycode lookup (`:115-124`) show how a host feeds keys without GTK.
