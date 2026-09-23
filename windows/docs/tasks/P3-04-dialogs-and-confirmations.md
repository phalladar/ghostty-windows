# P3-04 — Dialogs: close confirmation, child exited, config errors, title prompt

**Phase:** P3 · **Depends on:** P3-02 · **Size:** S–M ·
**Touches:** new `src/apprt/win32/dialogs.zig`, `src/apprt/win32/{Window,Surface,App}.zig`.

## Goal

The confirmation and error surfaces that P1–P3 implemented with plain
`MessageBoxW` become consistent, use `TaskDialogIndirect` (native
Windows 11 look, custom button labels), and the remaining dialog-type
actions are handled: `show_child_exited` (with the core fallback kept
as the non-native option), `config_change` errors, `prompt_title`,
`open_config`.

## Read before starting (~200 lines)

- `src/apprt/gtk/class/close_confirmation_dialog.zig`,
  `config_errors_dialog.zig`, `title_dialog.zig`, `surface_child_exited.zig`
  (read only the strings and the decision logic; ~40 lines each).
- `src/apprt/action.zig`: `ChildExited`, `PromptTitle`, `OpenConfig`.
- `src/Surface.zig:1257-1300` (what the core does when
  `show_child_exited` returns false: prints an in-terminal message and
  waits for a key) and `:940-960` (`needsConfirmQuit`).
- `src/config/Config.zig`: grep `wait-after-command`, `confirm-close-surface`,
  `diagnostics` / `ErrorList`.
- `src/config/edit.zig` (`openPath`), `src/cli/edit_config.zig`
  (`runWindows`, the editor fallback), `src/os/open.zig` (`openWindows`).

## Steps

1. `dialogs.zig`: thin wrappers over `TaskDialogIndirect` (comctl32 v6,
   already manifested): `confirm(owner, title, main, content, yes_label, no_label) bool`,
   `info(owner, title, content)`, and a simple text input dialog for
   `prompt_title` (`DialogBoxIndirectParamW` with an in-memory template,
   or a tiny custom window with an edit control; either is fine).
2. Replace the P1/P3-01 `MessageBoxW` uses with `confirm`.
3. `show_child_exited`: keep returning `false` (core fallback prints the
   message in the terminal, which is what users expect for
   `wait-after-command`). Document the decision; a native banner is optional.
4. Config errors: on startup and on `reload_config`, if the loaded config
   has diagnostics, show `info` with the joined messages (GTK's dialog
   text). Do not block startup on it: show after the first window is up.
5. `prompt_title`: input dialog prefilled with the current title; on OK
   call the `set_title` path with `.override` semantics (see the
   `PromptTitle` payload).
6. `open_config`: `.os_open` → `ShellExecuteW("open", config_path)` falls
   back to notepad via the P2-06 editor logic; `.new_window` → open a
   window running the editor command? Match GTK: it opens the file with
   the OS. Return true.

## Acceptance

- Close/quit confirmations show a Windows 11 TaskDialog with
  "Close"/"Cancel" style buttons; Esc cancels.
- A config with a bad key shows the errors dialog once, after the window
  appears; the app still runs.
- `prompt_title` keybind changes the tab/window title.
- `open_config` keybind opens the config file.

## Gotchas

- `TaskDialogIndirect` requires `CoInitialize`? No, but it requires the
  comctl32 v6 manifest (present) and must be called on the UI thread.
- Owner HWND must be the top-level window, or the dialog can end up
  behind it.
- (P3-04 result) `TASKDIALOGCONFIG` is `#pragma pack(1)` in commctrl.h:
  160 bytes on x64, `TASKDIALOG_BUTTON` 12. Declared with `align(1)`
  fields and a comptime size assert.
- (P3-04 result) `TaskDialogIndirect` is resolved with
  `LoadLibraryW("comctl32.dll")` + `GetProcAddress`, not linked: v5
  comctl32 (no manifest, e.g. test binaries) does not export it and the
  process would fail to load. If it is missing, `dialogs.confirm` falls back
  to `MessageBoxW`.
- (P3-04 result) Custom buttons use IDs `IDOK`/`IDCANCEL` with
  `TDF_ALLOW_DIALOG_CANCELLATION`, so Esc and the title-bar X return
  `IDCANCEL`. Clipboard prompts default to "Deny" (GTK); close prompts
  default to "Close" (same as the old `MB_YESNO`).
- (P3-04 result) TaskDialog buttons are not addressable child controls
  by ID. Tests click them with `TDM_CLICK_BUTTON` (`WM_USER + 102`,
  wParam = button ID) sent to the `#32770` HWND and read the text with UI
  Automation. Esc is tested by posting `WM_KEYDOWN VK_ESCAPE` to
  `GetGUIThreadInfo(tid).hwndFocus`.
- (P3-04 result) `prompt_title` runs the modal dialog from a message posted
  to the surface HWND (`WM_APP + 0x60`), not inside `performAction`. After
  the dialog returns it checks that the surface and window are still alive.
- (P3-04 result) `show_child_exited` still returns false so the core prints
  its in-terminal message, which `wait-after-command` users expect.
- (P3-04 result) `open_config` treats `.os_open` and `.new_window` the same:
  `ShellExecuteW("open")` if `FindExecutableW` finds an association for the
  config file, otherwise `$VISUAL`/`$EDITOR`/`notepad.exe` (P2-06 logic),
  spawned and waited on a detached thread. `.ghostty` has no association on a
  stock install, so it falls through to the editor path.
- (P3-04 result) Config errors are posted to the message window after the
  first `Window.create` in `App.init`. The dialog has "Reload Configuration"
  and "Ignore" buttons like GTK.
- (P3-04 result) Set `XDG_CONFIG_HOME` to a scratch folder in live tests:
  `config.edit.openPath` creates the config file if it does not exist.

## Out of scope

Toast notifications (P4-06), a settings UI.

## Wrap-up

Tick P3-04. This completes P3; update the phase summary in STATUS.md.
