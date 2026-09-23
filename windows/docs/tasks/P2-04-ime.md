# P2-04 — IME: composition (preedit), commit, candidate window placement

**Phase:** P2 · **Depends on:** P2-01 · **Size:** M ·
**Touches:** new `src/apprt/win32/ime.zig`, `src/apprt/win32/Surface.zig`,
`src/apprt/win32/c.zig`, `src/build/SharedDeps.zig` (link `imm32` if not already).

## Goal

Japanese, Chinese, and Korean input via the Windows IME works: the
composition string is shown inline through the core's preedit support,
the candidate window appears at the cursor, and the committed text is
delivered to the terminal. Non-IME Unicode input (`VK_PACKET`, emoji
panel `Win+.`) also works.

## Read before starting (~250 lines)

- `src/Surface.zig:2571-2640` (`preeditCallback`), `:2123-2140` (`imePoint`),
  `:3328-3340` (`textCallback`).
- `src/apprt/gtk/class/surface.zig:3156-3300` (IM context callbacks:
  preedit-start/changed/end, commit; how they interact with `keyEvent`
  and the `composing` flag) — read for the ordering rules only.
- `src/apprt/embedded.zig:1122-1140` (`preeditCallback`/`textCallback`
  thin wrappers).
- `src/apprt/win32/key.zig` (P2-01 version): where `WM_CHAR` is handled.
- `src/apprt/win32/Surface.zig` `keyMessage`, `charMessage`, `wndProc`
  (`WM_CHAR` branch): where `ime.State` is wired in.

## Design (`ime.zig`)

Messages on the surface HWND:

- `WM_IME_SETCONTEXT`: clear `ISC_SHOWUICOMPOSITIONWINDOW` from `lParam`
  before `DefWindowProcW` so the IME does not draw its own composition
  window (we render the preedit inline).
- `WM_IME_STARTCOMPOSITION`: return 0 (suppress default window).
- `WM_IME_COMPOSITION`: `ImmGetContext` → if `lParam & GCS_RESULTSTR`,
  `ImmGetCompositionStringW(GCS_RESULTSTR)` → `textCallback(utf8)` and
  `preeditCallback(null)`; if `lParam & GCS_COMPSTR`,
  `ImmGetCompositionStringW(GCS_COMPSTR)` → `preeditCallback(utf8)` (empty
  → null). `ImmReleaseContext`.
- `WM_IME_ENDCOMPOSITION`: `preeditCallback(null)`.
- `WM_IME_NOTIFY` with `IMN_OPENCANDIDATE`/`IMN_SETCOMPOSITIONWINDOW`:
  position the candidate window: `ImmSetCandidateWindow` with
  `CFS_EXCLUDE`/`CFS_CANDIDATEPOS` at `core.imePoint()` (convert the
  surface-pixel point to client coordinates; it already is client-relative),
  and `ImmSetCompositionWindow(CFS_POINT)` at the same point so the
  fallback UI (if any) appears at the cursor.
- `WM_IME_CHAR`: return 0 (we already consumed the result string).
- While composing, key messages must not reach the core as text: set a
  `composing` flag from `WM_IME_STARTCOMPOSITION` to `END`, and in
  `key.zig` pass `composing = true` with empty `utf8` for keys that
  arrive during that window, so the core does not treat Enter/Backspace
  as terminal input (this mirrors GTK's `im_composing` handling).
- `WM_CHAR` for `VK_PACKET`: high surrogate + low surrogate arrive as
  two messages; buffer the high surrogate and emit one `textCallback`
  with the combined codepoint. Only handle `WM_CHAR` when the
  preceding key was `VK_PACKET` or the char came from the IME/emoji
  panel; regular typing already went through `ToUnicodeEx`.

## Steps

1. Externs (imm32): `ImmGetContext`, `ImmReleaseContext`,
   `ImmGetCompositionStringW`, `ImmSetCandidateWindow`,
   `ImmSetCompositionWindow`, `ImmAssociateContextEx`? (not needed);
   structs `CANDIDATEFORM`, `COMPOSITIONFORM`; constants `GCS_*`, `CFS_*`,
   `ISC_*`, `IMN_*`, `WM_IME_*`. Link `imm32`.
2. Implement `ime.zig` and the WndProc wiring.
3. Manual with Japanese IME (add "Japanese" language, Microsoft IME):
   type `nihongo`, see inline preedit, space to convert, Enter commits
   `日本語`; Esc cancels and clears the preedit; Backspace during
   composition edits the preedit not the terminal. Repeat with Chinese
   (Pinyin) and Korean (2-Beolsik: `한글` commit-on-next-key behaviour).
4. `Win+.` emoji panel inserts an emoji; a two-codepoint emoji (flag or
   skin tone) arrives intact.

## Acceptance

- The three IME checks pass; no stray characters reach the shell during
  composition.
- Candidate window appears next to the terminal cursor, not at the
  window corner.
- `Win+.` emoji insertion works, including surrogate pairs.

## Gotchas

- `ImmGetCompositionStringW` returns bytes, not chars; call once with
  null buffer to get the size.
- Some IMEs commit via `WM_CHAR` instead of `GCS_RESULTSTR` when the
  composition window is suppressed; keep the `WM_CHAR` path tolerant
  (deduplicate by ignoring `WM_CHAR` that follows a `GCS_RESULTSTR` in the
  same message batch, using `GetMessageTime`).
- Korean IMEs commit the previous syllable when the next key starts; the
  sequence `GCS_RESULTSTR` + `GCS_COMPSTR` can arrive in one message; handle
  both flags in order (result first).
- DPI: `imePoint` returns points divided by the content scale (not surface
  pixels); multiply by `content_scale` to get client pixels. Its `x` is the
  cell midpoint, so subtract half a cell for the caret left edge.
- Commit goes through `keyCallback(.unidentified, utf8)` like GTK `imCommit`,
  not `textCallback`: `textCallback` is a paste and would be wrapped in
  bracketed-paste markers.
- Key-ups for keys whose down was eaten as `VK_PROCESSKEY` arrive with the
  real VK, often after `WM_IME_ENDCOMPOSITION`. `ime.State` records the real
  VK via `ImmGetVirtualKey` and sends that release as `composing`, otherwise
  kitty report-events emits an orphan release.
- `composing` is rechecked on every non-`VK_PROCESSKEY` key-down with
  `ImmGetCompositionStringW(GCS_COMPSTR)` so a lost `ENDCOMPOSITION` cannot
  swallow keys forever.
- Without an installed IME, `ImmSetCompositionStringW(SCS_SETSTR)` returns
  TRUE but stores nothing. The unit test writes a `COMPOSITIONSTRING` directly
  into the window's HIMC (`ImmLockIMC`, `hCompStr` at offset 288 on x64,
  `ImmReSizeIMCC`/`ImmLockIMCC`); `ImmGetCompositionStringW` then returns it.
  This only works in-process, so the exe itself can only be driven with
  posted `WM_IME_*` messages carrying empty strings.
- IMM externs and constants live in `ime.zig`, not `c.zig`, to keep
  concurrent edits to `c.zig` apart. `imm32` was already linked.

## Out of scope

TSF (Text Services Framework) native integration; the IMM32 shim is
enough for terminal use and is what most terminals use.

## Wrap-up

Tick P2-04; note which IMEs were tested.
