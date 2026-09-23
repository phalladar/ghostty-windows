# P4-01 — Font discovery: index once, match styles, sane fallback order

**Phase:** P4 · **Depends on:** P0-05 · **Size:** M ·
**Touches:** `src/font/discovery.zig` (the `Windows` struct), `src/font/DeferredFace.zig` (minor).

## Goal

`font-family = "Cascadia Code"` picks the real bold/italic faces;
`font-family = "JetBrainsMono Nerd Font"` from the user font dir works;
CJK falls back to the locale's UI font (Yu Gothic UI / Microsoft YaHei UI
/ Malgun Gothic) instead of the first file alphabetically; emoji use
Segoe UI Emoji; a cache miss no longer opens 300 files with FreeType.

## Read before starting (~450 lines)

- `src/font/discovery.zig:954-1263` (the Windows scanner: `discover`,
  `discoverFallback`, directory walk `:1085-1113`, `.ttc` probe `:1131`,
  `matches` `:1156-1165`, `isFontFile` `:1245`, name matching `:1254-1262`),
  and the CoreText `Score` logic at `:663-890` as the model for scoring
  (`:760-785` already parses `head.macStyle` / OS/2 weight).
- `src/font/DeferredFace.zig:58-92, 241-252, 350-356` (`Windows` variant:
  path + face index + peek face).
- `src/font/CodepointResolver.zig:160-200` (how fallback discovery is
  requested: `monospace=false`, codepoint set).
- `src/font/opentype/os2.zig` (weight/selection parsing available).
- `src/font/discovery.zig:1397-1416` (the existing Windows test).
- Added after the fact: `src/cli/list_fonts.zig:95-140` (uses
  `familyName`/`name`), `src/font/SharedGridSet.zig:176-250` (primary
  style lookup takes the first result; retries without bold/italic when
  variations are set), `src/font/face/freetype.zig:66-160, 278-335`
  (`initFile`, `setVariations`), `pkg/freetype/face.zig`.

## Steps

1. **Index once.** Build a process-global, lazily-initialised index:
   for each font file (system dir, user dir, plus files listed under
   `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts` and the
   `HKCU` equivalent, via `RegEnumValueW`), open with FreeType once,
   read `num_faces`, and for each face record family (English name and
   the localised name from the SFNT name table), style name, weight
   (OS/2 `usWeightClass`), italic (`fsSelection`/`macStyle`), monospace
   (`FT_IS_FIXED_WIDTH` or post table), variable (`FT_FACE_FLAG_MULTIPLE_MASTERS`),
   path, index. Guard with a mutex; ~1–2 s on a large font set is
   acceptable on first use; log the timing.
2. **Scoring.** Implement a `Score` like CoreText's: exact family match
   > localized match; requested `bold`/`italic` match; `monospace`
   > preference when requested; variable fonts preferred when `variations`
   > are requested; then stable path order. Return an iterator ordered by
   > score.
3. **Fallback.** For codepoint fallback: first try a curated list
   ordered by script guess of the codepoint (emoji → `Segoe UI Emoji`,
   symbols → `Segoe UI Symbol`, CJK → locale-ordered `Yu Gothic UI`,
   `Microsoft YaHei UI`, `Microsoft JhengHei UI`, `Malgun Gothic`, then the
   others; Devanagari etc. → `Nirmala UI`; Arabic → `Segoe UI`), using the
   index's cmap check (cache a per-face `hasCodepoint` via the peek face);
   then fall back to scanning the index. Locale from
   `GetUserDefaultLocaleName`.
4. **Variable fonts:** ensure `variations` from config reach
   `Face.setVariations` for indexed variable fonts (should already work;
   verify with `JetBrains Mono` variable + `font-variation = wght=600`).
5. Tests: index builds and finds `Arial` bold; `Segoe UI Emoji` resolves
   for U+1F600; `Consolas` is monospace; a `.ttc` (`msgothic.ttc` if
   present) enumerates more than one face.

## Acceptance

- `ghostty +list-fonts` lists families once each with styles, in under
  3 s on this machine.
- `--font-family="Cascadia Mono"` renders bold prompts with the real
  bold face (compare glyph shapes to synthetic bold).
- `echo 日本語 😀 ∑ ➜` renders every glyph with sensible fonts.
- Unit tests pass.

## Gotchas

- Registry values map display names to file names that may be relative
  to `%SystemRoot%\Fonts`.
- Localised family names live in name IDs 1/16 with non-English
  language IDs; FreeType's `family_name` is the English one.
- Some `.ttc` files have 20+ faces (`msgothic.ttc` has 3, `mingliu` more);
  use `num_faces`, never a fixed 16.
- Do not load every face's glyphs; only headers and cmap.
- Windows 11 ships Cascadia Code/Mono as upright variable fonts only
  (no italic file). Named instances are indexed as face index
  `(instance << 16) | face`; FreeType opens them with the instance's
  coordinates and `Face.setVariations` starts from those, so user
  `font-variation` still applies on top.
- Segoe UI Emoji is COLR (outline layers). Ghostty's FreeType
  `renderGlyph` converts outline glyphs to 8bpp gray, so rendering it
  into the color atlas fails with `WrongAtlas`. The embedded Noto Color
  Emoji (CBDT) therefore stays ahead of discovery; COLR support is a
  separate task.
- `FT_Get_Next_Char` takes `FT_ULong`, which is 32-bit on Windows.
- The orchestrator's scratchpad is shared with other workers: build to a
  private `--prefix` subfolder, and `zig-out/bin/ghostty.exe` may be locked
  by another agent's running instance.
- `src/cli/show_face.zig` (`+show-face --string=...`, with
  `GHOSTTY_LOG=stderr` to see `font bold: ...` lines) checks style and
  fallback selection without a GUI.

## Out of scope

DirectWrite (P4-02), font hinting/ClearType-like rendering choices.

## Wrap-up

Tick P4-01. Update the fonts rows in `04-current-state.md`.
