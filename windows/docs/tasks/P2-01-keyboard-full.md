# P2-01 — Keyboard, complete: layouts, AltGr, dead keys, kitty protocol, keybinds

**Phase:** P2 · **Depends on:** P1-04 · **Size:** M ·
**Touches:** `src/apprt/win32/key.zig`, `src/apprt/win32/Surface.zig`,
`src/apprt/win32/App.zig` (keyboard-layout change), `src/input/keycodes.zig`
(only if a scancode is missing).

## Goal

Every keyboard layout produces the right text; AltGr and dead keys work;
neovim/helix (kitty keyboard protocol) get correct press/release/repeat
with proper `unshifted_codepoint`; keybinds like `ctrl+shift+c`,
`ctrl+shift+v`, `ctrl+shift+t`, `ctrl+plus/minus` reach the core's
binding system; the Windows key acts as `super`.

## Read before starting (~300 lines)

- `src/apprt/win32/key.zig` as written in P1-04.
- `src/apprt/gtk/class/surface.zig:1330-1472` (the rest of `keyEvent`:
  how GTK derives `consumed_mods`, handles composing, and what it does
  when a binding is matched vs text produced).
- `src/input/Binding.zig`: grep `pub fn parse`, `Trigger`, and the
  `physical`/`unicode` matching rules (`grep -n "unshifted\|physical\|translated" src/input/Binding.zig | head -40`).
- `src/Surface.zig:2694-2800` (`keyCallback`: binding lookup before text,
  what `consumed_mods` affects, the kitty encoder inputs).
- `src/Surface.zig`: `textCallback` (~3328) and `preeditCallback` (~2571).
- `src/input/keycodes.zig`: rows for `alt_right`, `control_right`,
  `meta_left/right`, numpad, `intl_backslash`, `intl_ro`, `intl_yen`
  (`grep -n "int_\|numpad\|meta\|_right" src/input/keycodes.zig`).

## Design additions to `key.zig`

- **AltGr.** Windows sends LCtrl-down (synthetic, scancode `0x1D` with
  no extended bit but with `lParam` flag pattern) immediately before
  RAlt-down for AltGr layouts. When `RAlt` is down and the current
  layout has an AltGr (test once per layout: `ToUnicodeEx` on a known
  key with ctrl+alt state yields a printable char, or check the
  `KLLF_ALTGR` flag via `GetKeyboardLayout` → `KbdLayerDescriptor`; the
  cheaper heuristic is fine): report `mods.alt = false, mods.ctrl = false`
  for the text result and put `.ctrl` and `.alt` into `consumed_mods`.
  For non-AltGr layouts keep Ctrl+Alt as-is. Also drop the synthetic
  LCtrl-down/up events so the core does not see a spurious Ctrl press
  (detect via `GetMessageTime` equality with the following RAlt message
  or by peeking the queue with `PeekMessageW(PM_NOREMOVE)`).
- **Dead keys.** When `ToUnicodeEx` returns `-1`, mark `composing = true`
  and remember that a dead key is pending. On the next key, Windows
  combines it; `ToUnicodeEx` returns the composed char (or two chars if
  invalid). Send the composed result as `utf8` with `composing = false`.
  Call `preeditCallback` with the dead-key glyph while pending (e.g. "´")
  and clear it on the next event; this mirrors GTK's preedit display.
- **Layout change.** `WM_INPUTLANGCHANGE` (top-level and child) →
  refresh cached `HKL`; there is no keymap cache to invalidate in the
  core on Windows, but log it.
- **`unshifted_codepoint`** for every key including when text is empty
  (bindings like `ctrl+plus` on layouts where `+` is shifted rely on it).
- **Numpad:** `numpad_*` entries from extended/non-extended scancodes;
  with NumLock off Windows maps them to navigation VKs but the
  _scancode_ stays the same, which is what `key` uses.
- **`TranslateMessage`:** now that text comes from `ToUnicodeEx`, never
  call `TranslateMessage` for key messages targeting a surface (avoids
  duplicate `WM_CHAR`). Keep it for other windows (dialogs).

## Steps

1. Implement the additions with unit tests for the pure parts
   (scancode mapping table, AltGr mod rewriting given a synthetic
   keystate).
2. Manual matrix, run with each of these layouts installed via Settings:
   - US: baseline, `ctrl+shift+c` reaches the binding (log), `ctrl+plus`/`ctrl+minus` change font size.
   - US-International: `'` then `a` → `á`; `'` then space → `'`; `"` then `u` → `ü`.
   - German: `AltGr+Q` → `@`, `AltGr+8` → `[`, `ß`, `ü`; `^` dead key.
   - French (AZERTY): `AltGr+0` → `@`, digits need shift, `²`.
   - Japanese IME off: 106-key `¥`/`_` keys (`intl_yen`, `intl_ro`) if a JIS
     layout is installed; otherwise skip.
3. Kitty protocol: in Git Bash or WSL run `kitten show-key -m kitty` if
   available, else `nvim` with a `<C-i>` vs `<Tab>` mapping test, or
   `printf '\e[>1u'; cat -v` and press keys: verify release events and
   `shift+tab`, `ctrl+i` vs `tab` distinction.
4. Win key: `super+...` bindings in config should match; plain Win press
   must still open Start (do not consume `WM_KEYUP` for `VK_LWIN`).

## Acceptance

- Layout matrix rows pass (record which layouts you actually tested).
- Kitty protocol distinguishes press/repeat/release and reports the
  unshifted key.
- Default keybinds `ctrl+shift+t/n/w` are recognised by the core (they
  perform `new_tab`/`new_window`/`close_surface`; the first two return
  false until P3 and must not crash).

## Gotchas

- `ToUnicodeEx` without flag `0x4` clears the dead-key state; with it
  (Win10 1607+) it does not, but on some layouts it still returns the
  composed character only on the _second_ call; test with a real German
  layout.
- Right Alt on US layout is plain `alt`, not AltGr.
- `VK_PACKET` (`SendInput` Unicode, used by some password managers)
  carries text in `wParam`'s high word via `WM_CHAR`; add a `WM_CHAR`
  handler that calls `textCallback` only for `VK_PACKET`-originated
  chars or for IME results (P2-04) to keep them from being dropped.
- Left/right `super` sides: `VK_LWIN`/`VK_RWIN` both map to `super`.
- `ToUnicodeEx` flag `0x4` means "do not change keyboard state", so a dead key
  pressed with it is never stored. The main text call uses flags `0`; all
  probes (unshifted codepoint, consumed shift, AltGr detection) use `0x4` and
  run after the main call so they do not see or eat a pending dead key.
- `TranslateMessage` also runs `ToUnicode` and would consume the dead key
  before `key.zig` sees it. The loop skips it for surface key messages
  (`Surface.skipTranslate`), except `VK_PACKET`/`VK_PROCESSKEY`. The
  ignored-`WM_SYSKEYDOWN` path calls `TranslateMessage` itself so
  `WM_SYSCHAR` still reaches `DefWindowProcW`.
- `wParam` of `VK_PACKET` key messages can carry data in the high word; mask
  with `0xFFFF` before comparing VKs.
- Every `WM_CHAR` reaching the surface is treated as text (`key.charEvent`,
  sent through `keyCallback`) unless a non-modifier `WM_KEYDOWN` is still
  down, which means the char duplicates text `ToUnicodeEx` already produced
  (e.g. AutoHotkey `ControlSend` posts down/char/up). `TranslateMessage` on a
  posted `VK_PACKET` emits a `WM_CHAR` of 0 (or the lParam high-word char), so
  0 is ignored and must not reset a pending high surrogate.
- `keycodes.zig` has Windows natives for `IntlBackslash`/`IntlRo`/`IntlYen`
  but no `code_to_key` entries, so they resolve to `.unidentified` on every
  platform; `key.zig` maps `0x56/0x73/0x7D` itself to avoid changing shared
  behaviour.
- Tests for other layouts load them with `LoadKeyboardLayoutW(KLF_NOTELLSHELL)`
  and unload only if they were not already in `GetKeyboardLayoutList`. This
  does not activate them or touch the user's language list.
- Modifiers for posted-key runtime tests: `AttachThreadInput` to the ghostty
  UI thread + `SetKeyboardState`, post, wait, zero the state, detach. No
  global input injection needed.
- Posting the AltGr pair from PowerShell one call at a time is too slow (the
  LCtrl is processed before RAlt is queued); post both from one native loop.
- Kitty protocol passes through ConPTY (Windows 11 26200): `CSI > 11 u` from
  the child reaches the core and CSI-u reports reach the child.

## Out of scope

IME composition (P2-04), on-screen keyboard, keybind UI.

## Wrap-up

Tick P2-01; note layouts tested in STATUS.md.
