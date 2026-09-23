# P4-02 — (Optional) DirectWrite-based discovery and per-codepoint fallback

**Phase:** P4 · **Depends on:** P4-01 · **Size:** L · **Optional: only if P4-01's heuristics prove insufficient.**
**Touches:** `src/font/backend.zig` (new `directwrite_freetype`), new
`src/font/discovery/directwrite.zig` (or a `DirectWrite` struct in `discovery.zig`),
`src/build/Config.zig` (backend option), `src/build/SharedDeps.zig` (link `dwrite`).

## Goal

Font discovery and fallback use the system's DirectWrite font collection
and `IDWriteFontFallback::MapCharacters`, which is what Windows Terminal,
browsers, and Office use. Rasterising and shaping stay on FreeType and
HarfBuzz, so the result of discovery is still a `(path, face_index)` pair
consumed by `DeferredFace.Windows`.

## Read before starting

- P4-01's index code and `DeferredFace.Windows`.
- `src/font/backend.zig` (whole; add the enum value and `has*` answers).
- COM-in-Zig pattern: there is no COM helper in the repo. Define vtables
  as `extern struct` of function pointers with `callconv(.winapi)`, and
  call through `self.vtable.Method(self, ...)`. Only declare the vtable
  slots you use, but the slot _order_ must match the SDK headers
  (`dwrite.h`, `dwrite_3.h`): fill unused slots with `*const anyopaque`.

## Steps

1. `DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, IID_IDWriteFactory3)`.
2. Discovery: `GetSystemFontCollection` → `FindFamilyName` →
   `GetFontFamily` → `GetFirstMatchingFont(weight, stretch, style)` →
   `CreateFontFace` → `GetFiles` → `IDWriteFontFile::GetReferenceKey`
   - `GetLoader` → `QueryInterface(IDWriteLocalFontFileLoader)` →
     `GetFilePathFromKey`; face index from `IDWriteFontFace::GetIndex`.
3. Fallback: `IDWriteFactory2::GetSystemFontFallback` →
   `MapCharacters(textSource, 0, len, collection, baseFamily, weight,
style, stretch, &mappedLength, &font, &scale)` with a tiny
   `IDWriteTextAnalysisSource` implementation (needs a COM object with
   `IUnknown` + 5 methods; refcount via atomics). Locale from
   `GetUserDefaultLocaleName`.
4. Backend plumbing: `-Dfont-backend=directwrite_freetype`; keep
   `freetype_windows` as the default until this is proven; then switch
   the default.
5. Tests as in P4-01 plus a fallback test for a Devanagari codepoint.

## Acceptance

Same as P4-01's acceptance, with fallback choices matching Windows
Terminal for a sample of CJK/emoji/Indic strings.

## Gotchas

- `MapCharacters` can return a font whose file is not a local file (e.g.
  downloadable fonts); skip those (`GetLoader` QI fails).
- Variable fonts: DirectWrite returns named instances; use the base file
  and let FreeType apply variations.
- COM must be initialised (`CoInitializeEx`) on the calling thread; font
  discovery runs on the main thread and the renderer thread? Check
  where `discover` is called (font thread?) and initialise per thread
  (COINIT_MULTITHREADED is simplest).
- 2026-09-22 evaluation (skipped): P4-01's curated fallback was compared
  against `IDWriteFontFallback::MapCharacters` (a throwaway C program
  built with `zig cc -target x86_64-windows-gnu x.c -ldwrite`; mingw's
  `dwrite_2.h` works with `COBJMACROS`) on ~150 codepoints across CJK,
  Hangul, 9 Indic scripts, Sinhala, Thai/Lao/Khmer, Myanmar, Tibetan,
  Hebrew/Arabic/Syriac/Thaana, Ethiopic, Cherokee, UCAS, Runic,
  Mongolian, Yi, symbols and emoji. Every script picked the same family.
  Only differences: CJK Ext-B (Yu Gothic UI vs MingLiU-ExtB, both cover
  it), Bopomofo on en-US (YaHei UI vs JhengHei UI), and emoji (bundled
  Noto on purpose). The test source's `QueryInterface` must return
  `E_NOINTERFACE` for unknown IIDs or `MapCharacters` crashes.
- DirectWrite discovery would not fix Segoe UI Emoji: finding it already
  works; the gap is COLR rendering in `face/freetype.zig`, which is a
  rendering task.

## Out of scope

Rendering with DirectWrite/Direct2D.

## Wrap-up

Tick P4-02 (or mark "skipped: P4-01 sufficient" in STATUS.md).
