# P5-02 — Release build, portable zip layout, installer/winget path

**Phase:** P5 · **Depends on:** P5-01, P3-04 · **Size:** M ·
**Touches:** `build.zig` (a `dist-windows` step, optional), new
`dist/windows/installer/` (Inno Setup script or WiX), docs.

## Goal

A reproducible `ghostty-<version>-windows-x86_64.zip` containing
`bin\ghostty.exe` and `share\ghostty\...` that runs from any folder, plus
an installer that adds a Start Menu shortcut (needed for toast
notifications and taskbar pinning) and an optional "Open Ghostty here"
Explorer context menu.

## Read before starting (~150 lines)

- `src/os/resourcesdir.zig` (how the resources dir is located relative
  to the exe: walks up from `bin\` to find `share\ghostty`).
- `src/build/GhosttyResources.zig` (what gets installed to `share\ghostty`;
  themes, shell integration, terminfo source).
- `src/build/GhosttyDist.zig:150-200` (existing `dist` tarball step, for
  the pattern of adding a build step).
- `src/build/Config.zig`: `strip`, `optimize` defaults.

## Steps

1. Release build: `zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast`
   (strip defaults to true). Confirm `ghostty.exe` size and that
   `ghostty +version` still works.
2. Zip layout: `ghostty\bin\ghostty.exe`, `ghostty\share\ghostty\**`,
   `ghostty\LICENSE`, `ghostty\README-windows.md`. Add a `zig build
dist-windows` step that runs `Compress-Archive` via `addSystemCommand`
   or write a `dist/windows/make-zip.ps1` script; either is fine, prefer
   the script (no PowerShell dependency inside the build graph).
3. Installer: Inno Setup script (`dist/windows/installer/ghostty.iss`)
   installing to `%LOCALAPPDATA%\Programs\Ghostty` per-user by default,
   Start Menu shortcut with `AppUserModelID = com.mitchellh.ghostty`
   (Inno supports `AppUserModelID` in `[Icons]`), optional registry keys
   for `HKCU\Software\Classes\Directory\Background\shell\Ghostty` ("Open
   Ghostty here" → `ghostty.exe --working-directory="%V"`), and an
   uninstaller. Document that winget manifests can point at the installer
   later (no submission in this plan).
4. Compiled terminfo (optional): if a Linux/WSL `tic` is available at
   build time, produce `share\terminfo\x\xterm-ghostty` and ship it, and
   then P2-06's `TERM` rule can prefer `xterm-ghostty` when that file
   exists. Skip if it complicates the build.
5. Code signing: note the steps (signtool + certificate) in
   `README-windows.md`; do not sign in this plan.

## Acceptance

- The zip runs from `C:\Temp\ghostty\bin\ghostty.exe` with themes and
  shell integration working (resources found).
- The installer installs, creates the shortcut, and uninstalls cleanly
  (no leftover registry keys except user config).
- "Open Ghostty here" opens a window in that directory.

## Gotchas

- SmartScreen will warn on unsigned installers; expected.
- `%V` in the shell verb command expands to the folder path with spaces;
  quote it.
- Per-user install avoids UAC and matches Windows Terminal's model.
- `%V` for a drive root is `C:\`, and `"...=C:\"` makes the closing quote
  an escaped `"` under MSVC argv rules. The verb passes
  `"--working-directory=%V\."` instead; `C:\\.` and `D:\a b\.` both resolve.
- The resources sentinel on Windows is `share\terminfo\ghostty.terminfo`,
  so the zip/installer must ship `share\terminfo` next to `share\ghostty`.
- `ISCC.exe` is not long-path aware: with a long `OutDir` it fails with
  "The system cannot find the path specified" on the deepest
  `shell-integration` file. `make-zip.ps1` stages into `<OutDir>\staging`.
- The zip is byte-reproducible per PowerShell edition only (5.1 and 7 ship
  different deflate implementations).
- `+show-config` prints nothing from the win32 build; `+list-themes`
  works and is the quickest check that resources were found.
- Releases must ship `conpty.dll` + `OpenConsole.exe` (ConPTY >= 1.25) in
  `bin\`, or resize reflow is broken (see P4-03 "Resize fix"). Opt-in:
  `make-zip.ps1` by default (pinned NuGet version + SHA-256),
  `-ConptyVersion <v>`, or `-ConptyDir <dir>`. Binaries are never
  committed; dev builds fall back to the inbox conhost.

## Out of scope

MSIX/Store, auto-update, winget submission.

## Wrap-up

Tick P5-02.
