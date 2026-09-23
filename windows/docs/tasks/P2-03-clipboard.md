# P2-03 — Clipboard: read, write, unsafe-paste confirmation, OSC 52

**Phase:** P2 · **Depends on:** P1-04 · **Size:** M ·
**Touches:** new `src/apprt/win32/clipboard.zig`, `src/apprt/win32/Surface.zig`,
`src/apprt/win32/c.zig`.

## Goal

`ctrl+shift+c`/`ctrl+shift+v` (and `copy-on-select`, right-click paste
if configured) work with `CF_UNICODETEXT`; pasting multi-line or
bracketed-paste-unsafe text asks for confirmation when the config says
so; OSC 52 read/write follow `clipboard-read`/`clipboard-write` settings.

## Read before starting (~300 lines)

- `windows/docs/06-apprt-contract.md`: `supportsClipboard`,
  `clipboardRequest`, `setClipboard`, `completeClipboardRequest`,
  `denyClipboardRequest`, and the struct types.
- `src/apprt/structs.zig:40-130` (`Clipboard`, `ClipboardContent`,
  `ClipboardRequest`, `ClipboardReadResult`).
- `src/Surface.zig:5863-5960` (`CompleteClipboard`, `completeClipboardRequest`
  and the `UnsafePaste`/`UnauthorizedPaste` errors), `:6049-6070`
  (`denyClipboardRequest`), `:6143-6180` (where `clipboardRequest` is invoked).
- `src/apprt/gtk/class/surface.zig:3984-4120` (the GTK read path and
  confirmation flow; skip the dialog widget code), `:4200-4300` (write path).
- `src/apprt/embedded.zig:699-760` (`supportsClipboard`, `clipboardRequest`
  for a host that answers synchronously; the closest model for Win32),
  `:962-990` (`setClipboard`).
- `src/config/Config.zig`: grep `clipboard-read`, `clipboard-write`,
  `clipboard-paste-protection`, `clipboard-paste-bracketed-safe`, `copy-on-select`.

## Design (`clipboard.zig`)

```zig
pub fn readText(alloc, hwnd) !?[]u8      // OpenClipboard(hwnd) → GetClipboardData(CF_UNICODETEXT) → GlobalLock → utf16→utf8 → GlobalUnlock → CloseClipboard
pub fn writeText(hwnd, text: []const u8) !void  // OpenClipboard → EmptyClipboard → GlobalAlloc(GMEM_MOVEABLE) → copy utf16 + NUL → SetClipboardData(CF_UNICODETEXT) → CloseClipboard
```

Surface:

- `supportsClipboard`: `.standard` → true; `.selection`/`.primary` → false.
- `clipboardRequest(clip, req)`: read synchronously; if empty →
  `.unavailable`; else call `core.completeClipboardRequest(req, .{ .contents = text, .available = true, .confirmed = false, .remember = false })`.
  On `error.UnsafePaste` / `error.UnauthorizedPaste`: show a
  `MessageBoxW` (Yes/No, `MB_ICONWARNING`) with the same wording GTK uses
  ("Warning: Potentially Unsafe Paste" etc., copy the strings from the GTK
  dialog file), then call again with `.confirmed = true` or
  `denyClipboardRequest`. Return `.started` (the contract lets the read be
  completed before returning).
- `setClipboard(clip, contents, confirm)`: pick the `text/plain` entry
  (`ClipboardContent.mime`), if `confirm` show the OSC 52 write
  confirmation MessageBox first, then `writeText`.
- Kitty clipboard requests (`kitty_read`/`kitty_write`) carry MIME
  types; support `text/plain` only, deny others with `.unsupported`.

## Steps

1. Externs: `OpenClipboard`, `CloseClipboard`, `EmptyClipboard`,
   `GetClipboardData`, `SetClipboardData`, `IsClipboardFormatAvailable`,
   `GlobalAlloc`, `GlobalLock`, `GlobalUnlock`, `GlobalSize`, `GlobalFree`;
   `CF_UNICODETEXT = 13`, `GMEM_MOVEABLE = 0x0002`.
2. Implement `clipboard.zig` with a Windows-gated round-trip test
   (write "héllo\r\nwörld", read it back). Convert `\r\n` to `\n` on
   read? No: the core's paste path handles CRLF (check
   `Surface.zig` paste normalisation); if it does not, convert and note it.
3. Wire the Surface methods and the confirmation dialogs.
4. Manual: select text, `ctrl+shift+c`, paste into Notepad; copy from
   Notepad, `ctrl+shift+v` into the shell; paste a multi-line snippet
   with `clipboard-paste-protection = true` and confirm the warning;
   in bash run `printf '\e]52;c;%s\a' "$(echo -n hi | base64)"` and check
   the `clipboard-write` setting is respected.

## Acceptance

- Round-trip unit test passes.
- The four manual checks pass; text with emoji and CJK survives both
  directions.
- With `copy-on-select = true`, selecting text updates the clipboard.

## Gotchas

- `OpenClipboard` fails if another app holds it; retry a few times with
  a 10 ms sleep, then give up with `.unavailable`.
- Windows replaces `\n` with `\r\n` in _some_ apps' clipboard writes;
  Ghostty should write `\n` as-is (the terminal receives what was
  copied), but normalise `\r\n` → `\n` on read if the core does not.
- The memory handed to `SetClipboardData` is owned by the system after
  success; do not `GlobalFree` it unless the call failed.
- MessageBox blocks the message loop: fine for confirmations, but never
  call it from a non-main thread.
- The core does not normalise CRLF: non-bracketed paste maps `\n` to `\r`,
  so `\r\n` from Notepad-style writers would become `\r\r` (an extra Enter).
  `clipboard.pasteTextFromUtf16` drops the `\r` of each `\r\n` on read.
- ConPTY forwards OSC 52 writes but swallows OSC 52 queries
  (`ESC]52;c;?BEL`): the read request never reaches the apprt, so the
  `clipboard-read` flow cannot be exercised through ConPTY (only via
  Kitty OSC 5522 or a non-ConPTY pty, if ever added).
- `OpenClipboard(NULL)` + `EmptyClipboard` leaves no owner and
  `SetClipboardData` may fail; always pass an HWND (the unit test creates
  a message-only `STATIC` window).
- The round-trip unit test writes the real clipboard. It saves every
  HGLOBAL format and restores it, and skips when a non-HGLOBAL format
  (bitmap, metafile, ...) is present. Live tests should do the same
  (see the save/restore helper pattern in the test).

## Out of scope

Rich formats (HTML/RTF), image paste (kitty image protocol via
clipboard), clipboard history integration.

## Wrap-up

Tick P2-03.

- The "clipboard round trip" test touches the real system clipboard, so it only runs with `GHOSTTY_TEST_CLIPBOARD=1` set (orchestrator change, 2026-09-23).
