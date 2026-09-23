# P5-01 — Exe metadata: manifest (UTF-8, long paths), VERSIONINFO, AppUserModelID

**Phase:** P5 · **Depends on:** P2-05 · **Size:** S ·
**Touches:** `dist/windows/ghostty.manifest`, `dist/windows/ghostty.rc`,
`src/build/GhosttyExe.zig`.

## Goal

`ghostty.exe` declares a UTF-8 active code page, long-path awareness,
PerMonitorV2 DPI (already), Common Controls v6 (already), supported OS
(Windows 10/11 GUID), and carries a filled VERSIONINFO with the build
version so Explorer's Properties dialog and crash tooling show
"Ghostty 1.3.2".

## Read before starting (~80 lines)

- `dist/windows/ghostty.manifest`, `dist/windows/ghostty.rc` (whole).
- `src/build/GhosttyExe.zig:43-51` (`addWin32ResourceFile`; it accepts
  `.flags` for the resource compiler, and Zig's `rc` supports `/d NAME=value`).
- `src/build/Config.zig`: how `version` is available (`config.version`,
  a `std.SemanticVersion`).

## Steps

1. Manifest: add under `windowsSettings`:
   `<activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>`
   and `<longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>`;
   add a `<compatibility>` block with the Windows 10 `supportedOS` GUID
   (`{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}`), which also covers 11.
   With `activeCodePage=UTF-8`, the P0-04 `SetConsoleOutputCP` call
   becomes redundant but harmless.
2. `.rc`: uncomment/fill `FILEVERSION`/`PRODUCTVERSION` and the string
   values using `VERSION_MAJOR/MINOR/PATCH` and a `VERSION_STRING` macro;
   pass them from `GhosttyExe.zig` via `.flags = &.{ "/d", "VERSION_MAJOR=1", ... }`
   built from `cfg.version`. `FileDescription = "Ghostty Terminal"`,
   `CompanyName = "Ghostty"`, `LegalCopyright` from the LICENSE year.
   Set `FILEFLAGS VS_FF_DEBUG` in Debug builds.
3. AppUserModelID: ensure P2-05's `SetCurrentProcessExplicitAppUserModelID`
   uses `com.mitchellh.ghostty` (matches `build_config.bundle_id`).
4. Verify: `(Get-Item .\zig-out\bin\ghostty.exe).VersionInfo`, and
   `[System.Text.Encoding]::Default` inside a spawned pwsh reports
   UTF-8? (that is the child; check instead that
   `ghostty +version` prints the version and that a config path with
   non-ASCII characters loads).

## Acceptance

- `VersionInfo.FileVersion` matches `build.zig.zon` version.
- Explorer Properties → Details shows product name, description, version.
- A config under a directory named `C:\Users\<you>\tést\` loads
  (`--config-file`), proving UTF-8 paths through the CRT.

## Gotchas

- `activeCodePage` only takes effect on Windows 10 1903+; fine.
- Zig's resource compiler is `resinator`; it supports `/d` defines and
  `#define` inside the `.rc`. Test both forms if one fails.
- The `.rc` does not include `winver.h`, so `VS_VERSION_INFO` was an
  undefined identifier and the resource got the string name
  "VS_VERSION_INFO" instead of ID 1; Windows ignored it and
  `VersionInfo` was empty. The `.rc` now `#define`s it to 1 and uses
  numeric literals for the `VS_*`/`VOS_*`/`VFT_*` constants.
- `VersionInfo.FileVersion` is the full semver string (`1.3.2-main-+<sha>`
  for git dev builds, `1.3.2` with `-Dversion-string=1.3.2`); the numeric
  FILEVERSION is `major.minor.patch.0`.
- Checking the manifest effect: a tiny exe embedding `ghostty.rc` reports
  `GetACP()=65001` and `RtlAreLongPathsEnabled()=1` (vs 1252/0 without).

## Out of scope

Code signing (P5-02 note), installer.

## Wrap-up

Tick P5-01.
