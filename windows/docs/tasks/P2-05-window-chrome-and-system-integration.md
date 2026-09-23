# P2-05 — Window chrome and system integration: dark title bar, theme detection, icon, bell, URLs, fullscreen, config reload

**Phase:** P2 · **Depends on:** P1-05 · **Size:** M ·
**Touches:** `src/apprt/win32/{Window,App,c}.zig`, `src/os/open.zig`,
`src/os/windows.zig`.

## Goal

The window looks and behaves like a native Windows 11 app: title bar
follows the terminal's light/dark background, the app icon shows in the
title bar and taskbar, `ring_bell` gives audible/visual feedback, links
open in the browser safely, `toggle_fullscreen`/`toggle_maximize` work,
`window-theme = auto` follows the system theme, and `reload_config`
works from its keybind.

## Read before starting (~250 lines)

- `windows/docs/06-apprt-contract.md`: `config_change`, `reload_config`,
  `ring_bell`, `open_url`, `toggle_fullscreen`, `toggle_maximize`,
  `set_title`, `color_change`, `colorSchemeCallback`.
- `src/os/open.zig` (whole; the rundll32 branch at `:32` and the macOS
  `osc8` fail-closed logic at `:26-28`).
- `src/apprt/gtk/class/application.zig`: grep `reload_config` and
  `color_scheme` to see how GTK reloads and how it maps system theme to
  `apprt.ColorScheme`.
- `src/apprt/gtk/class/window.zig`: grep `fullscreen`, `maximize`,
  `set_title` for expected semantics (toggle vs set).
- `src/config/Config.zig`: grep `window-theme`, `background`, `title`,
  `window-decoration`, `bell-features`.
- `src/App.zig:408-435` (`colorSchemeEvent`), `:164-190` (`updateConfig`).
- `src/Surface.zig`: `colorSchemeCallback` (~4755), `updateConfig` (~1747,
  emits `config_change` with a surface target), `openUrl` (~4466).
- `src/config/Config.zig:4700-4712` (`window-theme` auto -> system rewrite).

## Steps

1. **Dark title bar.** On window create and on `config_change`: compute
   luminance of `config.background`; call
   `DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE /* 20 */, &BOOL, 4)`.
   If `window-theme` is `light`/`dark`, use that instead of luminance;
   `auto` → system setting (step 2). Optionally set
   `DWMWA_CAPTION_COLOR` (35) to the background colour and
   `DWMWA_TEXT_COLOR` (36) to the foreground for a seamless look, behind
   `window-theme = ghostty`.
2. **System theme detection.** Read
   `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme`
   (`RegGetValueW`), map 0 → `.dark`, 1 → `.light`. On
   `WM_SETTINGCHANGE` with `lParam` string `ImmersiveColorSet`, re-read
   and call `core_app.colorSchemeEvent(self, scheme)` plus each
   surface's `colorSchemeCallback`. Set the initial scheme before the
   first surface is created (GTK does this in `Application.init`).
3. **Icon.** `LoadIconW(GetModuleHandleW(null), MAKEINTRESOURCE(1))`
   (`ID_ICON_GHOSTTY` in `dist/windows/ghostty.rc`) and set `hIcon`/`hIconSm`
   in the class, or `WM_SETICON` per window. Set an AppUserModelID
   (`SetCurrentProcessExplicitAppUserModelID(L"com.mitchellh.ghostty")`)
   at startup so taskbar grouping is stable.
4. **Bell.** `ring_bell`: `MessageBeep(MB_OK)` if `bell-features` has
   audio; `FlashWindowEx(FLASHW_TRAY, 3, 0)` when not focused; and make
   sure the core's visual `bell-features` (border/title) still work.
5. **URLs.** Rewrite `src/os/open.zig` Windows branch to `ShellExecuteW(null, L"open", url, null, null, SW_SHOWNORMAL)`
   (extern in `src/os/windows.zig`, new `exp.shell32` namespace). For
   `.osc8` kind with a `file:` scheme, refuse unless the target is a
   directory or has a non-executable extension (mirror macOS's
   fail-closed rule; `.exe/.bat/.cmd/.com/.lnk/.ps1/.vbs/.js/.msi/.scr`
   are executable). Add a Windows-gated unit test for the scheme check.
   Then the core's fallback path (`open_url` returns false) is safe; no
   apprt handling needed.
6. **Fullscreen / maximize.** `toggle_maximize`: `ShowWindow(SW_MAXIMIZE/SW_RESTORE)`.
   `toggle_fullscreen`: save style/rect, set `WS_POPUP` style, size to
   the monitor (`MonitorFromWindow` + `GetMonitorInfoW`), restore on
   toggle. Honour `fullscreen = true` config on first window.
7. **Config reload.** `reload_config`: unless `soft`, `Config.load` again,
   `finalize`, replace `app.config` (deinit old), then
   `core_app.updateConfig(self, &config)`; log config errors via
   `MessageBoxW` listing `config.diagnostics` (the GTK "config errors"
   dialog content) only when there are errors.
8. **`set_title`/`set_window_title`:** `SetWindowTextW`; `prompt_title`
   returns false (P3-04).

## Acceptance

- Title bar is dark with the default theme and light with
  `--background=#ffffff`; `--window-theme=ghostty` colours the caption.
- Toggling Windows light/dark in Settings switches
  `colorSchemeCallback` (verify with a theme pair `theme = light:...,dark:...`).
- Taskbar shows the Ghostty icon; the window title bar icon is set.
- `printf '\a'` beeps and flashes the taskbar button when unfocused.
- `ctrl+click` on a URL opens the default browser; an OSC 8 link to
  `file:///C:/Windows/System32/cmd.exe` is refused (logged), one to
  `file:///C:/Users` opens Explorer.
- `ctrl+shift+,` (default `reload_config`) applies a changed font size
  from the config file.

## Gotchas

- `DwmSetWindowAttribute` with attribute 20 requires Windows 11 (or
  Windows 10 20H1+ with the undocumented 19 value); we target 11 only.
- `WM_SETTINGCHANGE` `lParam` may be null; check before comparing.
- `ShellExecuteW` needs COM initialised for some verbs; call
  `CoInitializeEx(null, COINIT_APARTMENTTHREADED)` once at startup in
  `App.init` (also needed later for taskbar progress).
- Do not enable `DWMWA_SYSTEMBACKDROP_TYPE` (Mica); it fights the GL
  swapchain.
- The core calls `internal_os.open` with the renderer mutex held
  (`Surface.zig` mouse release -> `processLinks`). `ShellExecuteW` pumps
  messages until the handler starts; on the main thread it deadlocked
  (window "Not Responding" after Explorer opened). It runs on a detached
  worker thread with its own `CoInitializeEx(STA)`.
- `Config.finalize` turns `window-theme = auto` into `system` when `theme`
  is a light/dark pair, so the title bar follows the OS scheme there, not
  the background luminance.
- `WM_SETTINGCHANGE` is not delivered to `HWND_MESSAGE` windows; handle
  it on the top-level window and post to the message window so the core
  is not re-entered from a sent message.
- `DwmGetWindowAttribute` cannot read back `DWMWA_CAPTION_COLOR`/
  `DWMWA_TEXT_COLOR` (E_INVALIDARG); verify via the debug log or a
  `PrintWindow` capture.
- `MessageBoxW` for config errors is shown from a posted message, never
  inside `performAction` (its modal loop would dispatch the tick message
  and re-enter `core_app.tick`).
- `src/os/open.zig` tests were not referenced by any test root; P2-05 added
  `_ = openpkg` to the Windows branch of `src/os/main.zig`'s `test` block.
- `bell-features=title` shows the bell prefix only while the window is
  not foreground and clears it on activation (GTK also clears on key
  input). `bell-features=border` is not implemented on Windows yet.

## Out of scope

Custom title bar (client-side decorations), transparency/blur, jump
lists, notifications (P4-06).

## Wrap-up

Tick P2-05. Update `04-current-state.md` row for `open.zig`.
