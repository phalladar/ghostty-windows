# P3-03 — Splits: layout the split tree with child HWNDs, dividers, split keybinds

**Phase:** P3 · **Depends on:** P3-02 · **Size:** L ·
**Touches:** `src/apprt/win32/{Window,Surface,App}.zig`, new `src/apprt/win32/SplitView.zig`.

## Goal

`new_split` (right/down/left/up), `goto_split`, `resize_split`,
`equalize_splits`, `toggle_split_zoom` work within a tab; dividers can
be dragged; focus moves between splits with the default keybinds; closing
a split collapses the tree.

## Read before starting (~350 lines)

- `src/datastruct/split_tree.zig`: public API (`grep -n "pub fn" src/datastruct/split_tree.zig`)
  — the core provides the tree data structure (insert, remove, resize,
  equalize, zoom, navigation, and an iterator that yields layout
  rectangles as ratios). Note the `app_runtime` switch at `:1327`.
- `src/apprt/gtk/class/split_tree.zig:1-200` and the parts that call
  the datastructure (`grep -n "SplitTree\|split_tree\." src/apprt/gtk/class/split_tree.zig | head -60`),
  to see how GTK maps tree changes to widgets and how `goto_split`
  direction resolution works.
- `src/apprt/action.zig`: `SplitDirection`, `GotoSplit`, `ResizeSplit`.
- `src/config/Config.zig`: default keybinds for `new_split`, `goto_split`,
  `resize_split`, `equalize_splits`, `toggle_split_zoom`, and
  `unfocused-split-opacity` / `split-divider-color` options.
- `src/Surface.zig:1851-1900` (`recomputeInitialSize`), called from surface
  init and `setCellSize`.

## Steps

1. Per tab, keep a `SplitTree(*Surface)` from `datastruct/split_tree.zig`
   (confirm its generic parameter and ownership model).
2. `SplitView.zig`: given the tab's content `RECT` and the tree, compute
   each leaf's device-pixel rect and `SetWindowPos` the surface HWNDs
   (`SWP_NOZORDER | SWP_NOACTIVATE`), leaving a divider gap of
   `split-divider` width scaled by DPI. Dividers are drawn by the parent
   window's `WM_PAINT` (fill the gaps with `split-divider-color`) —
   the parent paints only gaps, never over surfaces.
3. Divider drag: `WM_NCHITTEST`-free approach: on parent `WM_LBUTTONDOWN`
   in a gap, capture, on `WM_MOUSEMOVE` update the tree's ratio for that
   node and relayout; cursor `IDC_SIZEWE`/`IDC_SIZENS` over gaps via
   `WM_SETCURSOR`.
4. Actions: `new_split` (insert relative to the focused leaf; new surface
   with `.split` parent context), `goto_split` (direction resolution by
   geometry: pick the neighbour whose rect is closest in that direction;
   GTK's algorithm is the reference), `resize_split` (adjust ratio by
   pixels), `equalize_splits`, `toggle_split_zoom` (zoomed leaf fills the
   tab; others hidden).
5. Unfocused split dimming: send `focusCallback` correctly; the core
   renders `unfocused-split-opacity` itself? Check `Surface.zig` for
   `unfocused` handling; if it is apprt-side in GTK (CSS overlay), draw a
   translucent overlay child window or skip (document).
6. Closing a split surface removes the leaf and relayouts; closing the
   last leaf closes the tab.

## Acceptance

- Split right then down; navigate with `ctrl+alt+arrows` (or whatever
  the defaults are); resize with the keybind and by dragging; zoom
  toggles; equalize restores.
- Splits survive window resize and DPI change with correct ratios.
- No visual gap flicker while dragging (double-buffer the gap paint or
  use `WS_EX_COMPOSITED`? test; prefer painting only invalidated gap rects).

## Gotchas

- `SetWindowPos` on many children: wrap in `BeginDeferWindowPos`/
  `DeferWindowPos`/`EndDeferWindowPos` to avoid intermediate paints.
- `WS_CLIPCHILDREN` on the parent so its `WM_PAINT` cannot overdraw GL
  content.
- The split tree datastructure may hold values by copy; surfaces must be
  heap pointers.
- (P3-03 result) `SplitTree(Surface)` stores `*Surface`; `Surface.ref`
  returns `self` and `unref` is a no-op. The Window owns surface lifetime:
  every tree op returns a new tree (`replaceTree` deinits the old one) and
  removed leaves are destroyed explicitly after focus has moved.
- (P3-03 result) There is no `split-divider` width option. The gap is 5 dip
  filled with `background`, with a 1 dip line in `split-divider-color`
  (default: the tab bar separator colour). Dragging needs the gap to be the
  parent's client area; the minimum pane size while dragging is 4 gaps.
- (P3-03 result) `layout()` is the single source of show/hide: it positions
  every tab's leaves in one `DeferWindowPos` batch, shows only the active
  tab's visible leaves (zoom hides the rest) and calls `setVisible` only for
  leaves whose `WS_VISIBLE` changed. `split_view` holds the active tab's
  layout for hit testing and painting; recompute it after every tree change.
- (P3-03 result) The core fires `initial_size` from every new surface's init
  (tabs and splits), and the first one arrives before the tab is inserted.
  `setInitialSize` now ignores it once the window is visible and scales by
  `GetDpiForWindow`, so splits no longer resize the window and
  `window-width`/`window-height` apply to the first surface again.
- (P3-03 result) Unfocused-split dimming (`unfocused-split-opacity`/`-fill`)
  is apprt-side in GTK (CSS overlay) and is not implemented here; it needs a
  layered child overlay per unfocused leaf. Follow-up.
- (P3-03 result) White surfaces in `PrintWindow(hwnd, hdc, 2)` or in on-screen
  pixels while the user is idle mean the monitor is off (power plan turns
  the display off after 300 s on AC), not a renderer bug: presents succeed,
  but DWM shows no GL content at all. A standalone WGL test window that
  clears to red came out white/gray too, and so did old builds that had
  rendered text earlier. Check `GetLastInputInfo` idle time before
  bisecting. Use `GetWindowRect` of the `GhosttySurface` children for split
  geometry. DPI change and drag flicker were not
  checked live (display settings are off-limits; no screen capture).

## Out of scope

Split drag-and-drop between windows/tabs, animated zoom.

## Wrap-up

Tick P3-03.
