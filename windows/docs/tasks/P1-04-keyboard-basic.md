# P1-04 — Keyboard input, basic: scancode → `input.Key`, modifiers, text

**Phase:** P1 · **Depends on:** P1-02 · **Size:** M ·
**Touches:** new `src/apprt/win32/key.zig`, `src/apprt/win32/Surface.zig`,
`src/apprt/win32/c.zig`.

## Goal

Typing works in the shell: printable ASCII, Enter, Backspace, Tab,
Escape, arrows, Home/End/PageUp/PageDown/Delete/Insert, function keys,
Ctrl+letter (Ctrl+C interrupts, Ctrl+D/Ctrl+L behave), Shift+arrows, and
the default keybinds that the core handles from key events (e.g.
`ctrl+shift+v` will fail until clipboard exists; that is fine). Layout
correctness, AltGr, dead keys, and IME are P2-01/P2-04.

## Read before starting (~350 lines)

- `windows/docs/05-architecture.md` "Input on Windows".
- `src/input/key.zig:16-49` (`KeyEvent`), `:84-100` (`Action`),
  `src/input/key_mods.zig:20-60` (`Mods` packed struct and side bits).
- `src/input/keycodes.zig:1-60` (`entries`, `.native` column = Windows
  scancode; extended keys as `0xE0xx`) and a few rows to see the shape
  (`grep -n "key_a\|arrow_left\|enter\|escape" src/input/keycodes.zig`).
- `src/apprt/embedded.zig:104-150` (`App.KeyEvent`), `:202-230`
  (`keyEvent`: scancode lookup, calling `core.keyCallback`, `App.keyEvent`
  for global binds).
- `src/apprt/gtk/class/surface.zig:1256-1330` only (the part of `keyEvent`
  that builds the `KeyEvent`, computes `consumed_mods`, and handles
  `.closed`). Skip the IM sections.
- `src/Surface.zig:2694-2720` (`keyCallback` return semantics).
- `src/input/key_encode.zig:82-95` (`encode`), `:708-790` (`ctrlSeq`: how an
  empty or ctrl-agnostic utf8 becomes a C0 byte).

## Design (`key.zig`)

```zig
pub fn translate(hwnd, msg: UINT, wparam: WPARAM, lparam: LPARAM, hkl: HKL) ?input.KeyEvent
```

- `action`: `WM_KEYDOWN`/`WM_SYSKEYDOWN` → `.press` unless bit 30 of
  `lParam` (previous state) is set → `.repeat`; `WM_KEYUP`/`WM_SYSKEYUP`
  → `.release`.
- `native = ((lParam >> 16) & 0xFF) | (if (lParam & (1 << 24) != 0) 0xE000 else 0)`;
  linear scan of `input.keycodes.entries` for `.native == native`;
  unknown → `.unidentified`. Special cases: `VK_PAUSE` (`0xE11D45`
  sequence; treat scancode `0x45` with extended flag rules), `VK_SNAPSHOT`
  (`0xE037`), NumLock (`0xE045` vs `0x45`); the table comments say which.
- `mods`: `GetKeyState(VK_SHIFT|VK_CONTROL|VK_MENU) & 0x8000`, `VK_LWIN|VK_RWIN`
  → `super`, `GetKeyState(VK_CAPITAL|VK_NUMLOCK) & 1` → lock bits; sides
  from `VK_LSHIFT/VK_RSHIFT` etc.
- `utf8`: `ToUnicodeEx(vk, scancode, keystate[256], buf[8], 8, 0x4, hkl)`.
  `> 0` → encode UTF-16 result to UTF-8 into a small per-surface buffer;
  `0` → empty; `-1` → dead key: set `composing = true`, empty utf8. For
  P1 leave the dead-key state as Windows manages it (flag `0x4` keeps it
  intact for the following `WM_CHAR`); P2-01 finishes this.
  Skip text for keys with `ctrl` held so `Ctrl+C` yields `utf8 = ""` and
  the core encodes the control byte itself (this mirrors GTK where the
  keyval-to-text step is skipped when ctrl is down; confirm in the GTK
  slice above and copy the condition exactly).
- `unshifted_codepoint`: `ToUnicodeEx` again with a cleared keystate
  (no shift/ctrl/alt/caps) and flag `0x4`; take the first codepoint.
- `consumed_mods`: `shift` when utf8 is non-empty and shift was held
  (again mirror the GTK condition); `alt`/`ctrl` never consumed in P1.

Surface wiring: in the child WndProc, on the four key messages call
`translate`, then `core_surface.keyCallback(event)`; on `.closed` return
immediately; for `.ignored` with `WM_SYSKEYDOWN` fall through to
`DefWindowProcW` so Alt+F4/Alt+Space keep working; otherwise return 0.
Also run `app.core_app.keyEvent(app, event)` first for global binds only
if the core requires it (check `App.zig:344`: it needs `rt_app.config`).
Do **not** call `TranslateMessage` for key messages you consumed (or
`WM_CHAR` would duplicate input); simplest is to skip `TranslateMessage`
entirely in P1 and revisit in P2-01/P2-04.

## Steps

1. Externs: `GetKeyState`, `GetKeyboardState`, `ToUnicodeEx`,
   `GetKeyboardLayout`, `MapVirtualKeyExW`; constants `VK_*` you use,
   `WM_KEYDOWN/UP`, `WM_SYSKEYDOWN/UP`, `WM_CHAR`, `WM_SYSCHAR`.
2. Implement `key.zig` with a Windows-gated unit test for the scancode →
   key mapping of a handful of keys (`0x1E` → `key_a`, `0xE04B` →
   `arrow_left`, `0x1C` → `enter`, `0xE01C` → `numpad_enter` if present).
3. Wire the WndProc.
4. Manual matrix (record in STATUS): letters/digits/punctuation with and
   without Shift, Enter, Backspace, Tab, Esc, arrows, Home/End, F1–F12,
   Ctrl+C on `ping -t 127.0.0.1`, Ctrl+L, Alt+F4 closes, Alt+Enter is
   passed to the shell, Win key alone does nothing, Ctrl+Shift+C is
   seen as a binding (no crash even though clipboard is unimplemented).

## Acceptance

- The unit test passes.
- All rows of the manual matrix behave; PSReadLine history navigation
  with Up/Down works; `Ctrl+C` interrupts `ping`.
- Holding a key produces `.repeat` events (visible in debug log) and
  auto-repeat text.

## Gotchas

- `WM_SYSKEYDOWN` is sent for Alt combinations and F10; consuming it
  without a return to `DefWindowProcW` breaks system menus.
- `lParam` bit 24 (extended) distinguishes right Ctrl/Alt, numpad Enter,
  arrows vs numpad. Do not use `VK_*` alone for `key`; VKs are
  layout-dependent, scancodes are not.
- `ToUnicodeEx` with ctrl held returns control characters (0x03 for
  Ctrl+C); do not feed those as text (see the ctrl rule above).
- Caps Lock inverts case only for letters; `ToUnicodeEx` handles it if
  `keystate[VK_CAPITAL] & 1` is set, which `GetKeyboardState` provides.
- The kitty keyboard protocol (used by neovim/helix) needs correct
  release events and `unshifted_codepoint`; P2-01 verifies it.
- GTK does not drop text when ctrl is held; it drops only codepoints < 0x20
  from a ctrl-agnostic keyval (ctrl+c gives utf8 "c"). key.zig mirrors that by
  clearing the ctrl bits in the keystate copy passed to `ToUnicodeEx` (unless
  alt is also down, i.e. AltGr) and dropping C0/DEL results. The encoder
  still emits 0x03 via `ctrlSeq`.
- The app loop still calls `TranslateMessage`; the surface swallows `WM_CHAR`
  and passes `WM_SYSCHAR` to `DefWindowProcW` only when the preceding
  `WM_SYSKEYDOWN` was ignored by the core (otherwise Alt+letter beeps).
- Ctrl+C reaches ConPTY as 0x03 but does not interrupt `ping` when ghostty
  inherits the "ignore Ctrl+C" console flag from its launcher (e.g. an agent
  harness via `Start-Process`); launched from a clean parent (Explorer, or
  WMI `Win32_Process.Create`) it works. Possible fix: call
  `SetConsoleCtrlHandler(null, FALSE)` before spawning the child.
- Automated key tests: post `WM_KEYDOWN`/`WM_KEYUP` to the `GhosttySurface`
  HWND (modifier state is not visible to posted messages; use the
  `translateState` unit test for modifiers). In PowerShell `Add-Type`, give
  `FindWindowExW` `CharSet.Unicode` and pass `[NullString]::Value`, not `$null`.

## Out of scope

AltGr, dead keys, layout switching, IME, keybind editor. Global
keybinds (Windows has no equivalent to macOS global hotkeys here;
`RegisterHotKey` is a P4 option).

## Wrap-up

Tick P1-04, paste the matrix results into STATUS.md briefly (one line).
