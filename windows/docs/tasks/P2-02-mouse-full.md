# P2-02 — Mouse, complete: multi-click timing, precision scroll, capture, link hover

**Phase:** P2 · **Depends on:** P1-05 · **Size:** S ·
**Touches:** `src/os/mouse.zig`, `src/os/windows.zig`, `src/apprt/win32/Surface.zig`.

## Goal

Double-click selects a word and triple-click a line with the system
double-click time; precision touchpads scroll smoothly; drag-selection
continues outside the window; the pointer becomes a hand over links and
`ctrl+click` opens them (via `open_url` → `internal_os.open`, fixed in P2-05).

## Read before starting (~150 lines)

- `src/os/mouse.zig` (whole; returns null on non-macOS).
- `src/Surface.zig`: grep `clickInterval`, `mouse_over_link`, `link`
  (how multi-click is timed and how links are detected/hovered).
- `src/apprt/gtk/class/surface.zig`: grep `scroll` for the precision
  handling (`precision = true` for pixel deltas, and the sign convention).
- `src/input/mouse.zig:80-100` (`ScrollMods`).

## Steps

1. `src/os/mouse.zig`: add a `.windows` branch returning
   `GetDoubleClickTime()` milliseconds (extern in `src/os/windows.zig`
   under a new `exp.user32` namespace, or in the apprt `c.zig` if you
   prefer to keep user32 out of `os/`; the former keeps `os/` self-contained).
2. Precision scrolling: Windows delivers touchpad scrolling as
   `WM_MOUSEWHEEL` with deltas smaller than 120. Pass
   `precision = (delta % 120 != 0)` and `yoff = delta / 120.0 * lines_per_notch`
   where `lines_per_notch` comes from `SystemParametersInfoW(SPI_GETWHEELSCROLLLINES)`
   (default 3). Check how the core scales `precision` scroll (pixels vs
   lines) and match GTK's units.
3. Horizontal scroll: `WM_MOUSEHWHEEL`; also shift+wheel → horizontal
   only if the core does not already do that (grep `shift` in
   `scrollCallback`).
4. Link hover: implement `mouse_over_link` action to show the URL in the
   title bar? No: keep to the pointer only (the core already sends
   `mouse_shape = .pointer` over links). Implementing the action as a
   no-op that returns true is fine.
5. `WM_MOUSEMOVE` while captured: coordinates may be outside the client
   rect; forward as-is so selection autoscroll works.
6. Manual: double/triple click, drag out of window, touchpad two-finger
   scroll in `less`, `ctrl+click` on `https://ghostty.org` printed by
   `Write-Host`.

## Acceptance

- Double-click selects a word using the system interval (change it in
  Settings → Mouse to verify).
- Touchpad scroll is smooth; a mouse wheel notch scrolls the configured
  number of lines.
- Dragging past the bottom edge autoscrolls the selection.
- `ctrl+click` on a URL opens the browser (after P2-05; before that the
  log shows the `open_url` action).

## Gotchas

- `SPI_GETWHEELSCROLLLINES` can return `WHEEL_PAGESCROLL` (`UINT_MAX`) →
  treat as a page (use the visible rows).
- Some mice send 240 per notch; `delta / 120.0` still gives the right
  notch count.
- Discrete wheel events (delta a multiple of 120) pass notches and let
  `mouse-scroll-multiplier.discrete` (default 3) set the lines, like GTK
  and macOS. Only precision events use `SPI_GETWHEELSCROLLLINES`, converted
  to pixels (`notches * lines * cell.height`), so both paths scroll 3 lines
  per 120 at defaults. Multiplying discrete events by the system lines too
  would give 9 lines per notch.
- Posted mouse messages in tests: `TrackMouseEvent` posts `WM_MOUSELEAVE`
  at once when the real cursor is elsewhere, which resets the core cursor
  pos to -1,-1 (wheel reports then go nowhere, link hover clears). Hold a
  posted button down during wheel tests; `mouseLeave` is ignored while
  buttons are down.
- Test a `ctrl+click` without launching a browser by printing an OSC 8
  link to a nonexistent `file:///` path; the log then shows
  `refusing to open OSC 8 link err=error.InaccessibleFile`.

## Out of scope

Mouse reporting protocol correctness (core-owned), gestures.

## Wrap-up

Tick P2-02.
