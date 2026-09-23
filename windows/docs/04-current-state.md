# 04 — Current state: the port after P0–P5

This replaces the pre-port inventory taken 2026-09-22 at HEAD `4ae9f1a2d`
(see git history for that version). It describes what the `win32`
runtime does today, what is known not to work, and where the code lives.
Task files in `tasks/` keep the detailed history and gotchas; `STATUS.md`
tracks what is still open.

User-facing documentation: `dist/windows/README-windows.md` (install,
config, logs, crash reports, known issues), the "Windows" sections of
`README.md` and `HACKING.md`, and the PowerShell/cmd sections of
`src/shell-integration/README.md`.

## Build and packaging

| Item                                                                                                                             | State                                                     | Ref                                                                                                            |
| -------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `win32` runtime; default for Windows targets; MSVC ABI default, GNU ABI works                                                    | done                                                      | `src/apprt/runtime.zig`, `src/apprt.zig`, `src/build/SharedDeps.zig`                                           |
| GUI-subsystem exe, `mainCRTStartup` entry; console attached for Debug builds and `+actions`                                      | done                                                      | `src/build/GhosttyExe.zig`, `src/main_ghostty.zig` `attachConsole`, `src/os/windows.zig` `attachParentConsole` |
| Manifest: PerMonitorV2, comctl32 v6, supportedOS, longPathAware, UTF-8 active code page; VERSIONINFO from the build version      | done (P5-01)                                              | `dist/windows/ghostty.manifest`, `dist/windows/ghostty.rc`                                                     |
| Full unit test suite passes on Windows                                                                                           | done (P0-05)                                              | `zig build test`                                                                                               |
| CI job `build-windows-app` (build + tests)                                                                                       | added, first run pending a push (P5-03)                   | `.github/workflows/test.yml`                                                                                   |
| Release zip (deterministic per PowerShell edition) and Inno Setup per-user installer with AUMID shortcut and "Open Ghostty here" | done (P5-02)                                              | `dist/windows/make-zip.ps1`, `dist/windows/installer/ghostty.iss`                                              |
| Code signing, winget manifest, ARM64                                                                                             | not done                                                  | `dist/windows/README-windows.md`                                                                               |
| Compiled terminfo                                                                                                                | not shipped (source only; `TERM=xterm-256color`)          | `src/build/GhosttyResources.zig`                                                                               |
| `-Dapp-runtime=none` (libghostty embedding) on Windows                                                                           | fails: `OpenGL.zig` needs `rt_surface.hwnd`; out of scope | P2-05 deviation                                                                                                |
| i18n                                                                                                                             | off on Windows (build default)                            | `src/build/Config.zig` `i18n`                                                                                  |

## Application runtime (`src/apprt/win32/`)

| Item                                                                                                                                       | State                                                             | Ref                           |
| ------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------- | ----------------------------- |
| Message loop, wakeup, message-only window, quit timer, clean exit                                                                          | done (P1-01)                                                      | `App.zig`                     |
| Windows: default 80x24 cells + cascade, multiple windows, `goto_window`, quit/close-all confirmation                                       | done (P3-01)                                                      | `Window.zig`, `App.zig`       |
| Tabs: GDI tab bar, goto/move/close, titles, hidden tabs stop rendering, new tab inherits cwd                                               | done (P3-02)                                                      | `TabBar.zig`, `Window.zig`    |
| Splits: `SplitTree(*Surface)`, gap/divider drawing, drag resize, zoom, equalize                                                            | in progress (P3-03)                                               | `SplitView.zig`, `Window.zig` |
| Unfocused-split dimming (`unfocused-split-opacity`/`-fill`)                                                                                | not done (needs a layered overlay per leaf)                       | P3-03 Gotchas                 |
| DPI (PerMonitorV2, `WM_DPICHANGED` reflow), live resize, minimise pauses rendering                                                         | done (P1-02)                                                      | `Window.zig`, `Surface.zig`   |
| Keyboard: layouts, AltGr, dead keys, kitty protocol, `VK_PACKET`/surrogates                                                                | done (P1-04, P2-01)                                               | `key.zig`, `Surface.zig`      |
| win32-input-mode (`CSI ? 9001 h`)                                                                                                          | not supported; VT input only                                      | P2-01, P4-03 Gotchas          |
| Global keybinds (`RegisterHotKey`)                                                                                                         | not done                                                          | P1-04, P2-01 deviations       |
| IME: preedit, commit through the key path, candidate window at the cursor                                                                  | code done, in-process tests only; live JA/ZH/KO check pending     | `ime.zig`, P2-04              |
| Mouse: SGR reports, double-click time, precision wheel, capture loss, drag autoscroll, cursor shapes, hide while typing                    | done (P1-05, P2-02); real touchpad not tested                     | `Surface.zig`                 |
| Clipboard: CF_UNICODETEXT, CRLF→LF, unsafe-paste and OSC 52 prompts                                                                        | done (P2-03)                                                      | `clipboard.zig`               |
| OSC 52 read                                                                                                                                | unreachable: ConPTY swallows the query                            | P2-03 Gotchas                 |
| `copy-on-select=primary`                                                                                                                   | no-op (no selection clipboard)                                    | P2-03 deviation               |
| Title bar colours (dark/light/ghostty), icon, bell (attention, title, system beep), fullscreen, maximise, config reload                    | done (P2-05)                                                      | `Window.zig`, `App.zig`       |
| `bell-features=border`, `background-opacity`/`background-blur`                                                                             | not done                                                          |                               |
| Dialogs: TaskDialog confirmations, config errors at start and reload, `prompt_title`, `open_config`                                        | done (P3-04)                                                      | `dialogs.zig`                 |
| IPC: `+new-window`/`+new-tab` via `WM_COPYDATA`, fallback launches a new instance                                                          | done (P4-05); elevated ↔ non-elevated blocked by UIPI (by design) | `ipc.zig`                     |
| Taskbar progress (OSC 9;4), notifications as tray balloons, `command_finished`, `float_window`, `toggle_visibility`                        | done (P4-06)                                                      | `taskbar.zig`                 |
| WinRT toast notifications                                                                                                                  | not done (tray balloons used)                                     | P4-06                         |
| Quick terminal, inspector, command palette, search overlay, tab overview, `toggle_window_decorations`, `move_tab_to_new_window`, undo/redo | not implemented (`performAction` returns false)                   | `App.zig` `performAction`     |

## Terminal I/O (ConPTY)

| Item                                                                                                                 | State                                     | Ref                                                                                       |
| -------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- | ----------------------------------------------------------------------------------------- |
| ConPTY open/resize/close; reader EOF and shutdown order; no handle leaks over 100 spawns                             | done (P1-03)                              | `src/pty.zig`, `src/termio/Exec.zig`, `src/Command.zig`                                   |
| Job object with `BREAKAWAY_OK` (no kill-on-close); close = `ClosePseudoConsole`, then `TerminateJobObject` after 1 s | done (P4-03)                              | `src/Command.zig`, `src/termio/Exec.zig`                                                  |
| `foreground_pid` (newest process in the job), OSC 7 Windows paths                                                    | done (P4-03)                              | `src/Command.zig` `windowsForegroundPid`, `src/termio/stream_handler.zig`                 |
| Default shell pwsh → Windows PowerShell → cmd; `TERM=xterm-256color`; `LANG` from the user locale                    | done (P2-06)                              | `src/config/Config.zig` `windowsDefaultShell`, `src/termio/Exec.zig`, `src/os/locale.zig` |
| Shell integration: PowerShell 7/5.1 (OSC 133 A/B/C/D, OSC 7, title), cmd `PROMPT` marks                              | done (P2-07)                              | `src/termio/shell_integration.zig`, `src/shell-integration/powershell/`                   |
| Ctrl+C when Ghostty's own parent ignores it                                                                          | inherited by the shell; not worked around | P1-04 deviation                                                                           |
| Bundled OpenConsole.exe/conpty.dll                                                                                   | not done (inbox conhost used)             | P4-03 Gotchas                                                                             |

## Renderer

| Item                                                                                                         | State                 | Ref                                                      |
| ------------------------------------------------------------------------------------------------------------ | --------------------- | -------------------------------------------------------- |
| OpenGL 4.3 core through WGL, drawn to an FBO and blitted to the window with `SwapBuffers` (no Y-flip needed) | done (P0-03, P1-02)   | `src/renderer/opengl/wgl.zig`, `src/renderer/OpenGL.zig` |
| Vsync on/off via swap interval                                                                               | done (P1-02)          | `src/renderer/opengl/wgl.zig`                            |
| Renderer wakeup holds `*xev.Async` (never copy an `xev.Async`)                                               | fixed (P1-02)         | `src/termio/Options.zig`, `src/Surface.zig`              |
| Presentation policy upgrade / optional DXGI                                                                  | not started (P4-04)   | `tasks/P4-04-*`                                          |
| No GL 4.3 (RDP with Basic Render Driver, VMs without GPU)                                                    | renderer cannot start |                                                          |

## Fonts

| Item                                                                                                                    | State                                                            | Ref                                      |
| ----------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- | ---------------------------------------- |
| FreeType + HarfBuzz with a process-global font index (system + per-user fonts, registry, TTC faces, variable instances) | done (P4-01)                                                     | `src/font/discovery.zig` `Windows.Index` |
| Scoring and per-script codepoint fallback (CJK by user locale, Hangul, Indic, ...)                                      | done (P4-01)                                                     | `src/font/discovery.zig`                 |
| DirectWrite fallback                                                                                                    | skipped (P4-02; P4-01 matches `MapCharacters` on the tested set) |                                          |
| COLR color fonts (Segoe UI Emoji)                                                                                       | render grayscale; bundled Noto Color Emoji stays first           | `src/font/face/freetype.zig`             |
| `.fon` bitmap fonts                                                                                                     | not indexed                                                      |                                          |
| FreeType `Face.name()` returns platform-0 UTF-16BE names raw                                                            | cosmetic, shared code                                            | P4-02 deviation                          |

## OS layer, config, CLI

| Item                                                                                                                                           | State                                                           | Ref                                                              |
| ---------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- | ---------------------------------------------------------------- |
| Config `%APPDATA%\ghostty\config.ghostty` (template on first run); `%LOCALAPPDATA%` legacy read-only fallback; state/cache in `%LOCALAPPDATA%` | done (P2-06)                                                    | `src/os/xdg.zig`, `src/config/file_load.zig`                     |
| Home dir, hostname, locale, temp dir                                                                                                           | done (P2-06)                                                    | `src/os/homedir.zig`, `src/os/hostname.zig`, `src/os/locale.zig` |
| URL/file opening via `ShellExecuteW` on a worker thread; OSC 8 limited to http(s)/mailto/local `file:`                                         | done (P2-05)                                                    | `src/os/open.zig`                                                |
| `+edit-config`, `+list-fonts`, `+list-themes`, `+list-keybinds`, `+show-config`, `+validate-config`, `+version`, `+crash-report`               | work from a console                                             | `src/cli/`                                                       |
| `+ssh` terminfo install                                                                                                                        | broken: needs ssh ControlMaster, unsupported by Windows OpenSSH | `src/cli/ssh.zig`                                                |
| `+ssh-cache`                                                                                                                                   | no file locking on Windows (std)                                | `src/cli/ssh-cache/DiskCache.zig`                                |
| Crash reporting: local `MiniDumpWriteDump` (+ `.txt` on panic) in `%LOCALAPPDATA%\ghostty\crash`, listed by `+crash-report`; Sentry off        | done (P5-04); stack overflow dumps may fail                     | `src/crash/minidump.zig`                                         |

## Not verified on this machine

These paths are implemented but their acceptance checks could not be run
live (user desktop, missing hardware or input methods):

- IME with a real Japanese/Chinese/Korean IME and the Win+. emoji panel (P2-04).
- Tab bar relayout on a live DPI change (P3-02); split DPI change and drag flicker (P3-03).
- Live OS light/dark theme flip (P2-05; the message path is tested).
- Real touchpad scrolling (P2-02; simulated with non-120 wheel deltas).
- Foreground raise after `+new-window` (P4-05).
- First real CI run of `build-windows-app` (P5-03).
