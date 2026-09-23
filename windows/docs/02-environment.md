# 02 — Environment: toolchain, build, test, run, debug

State of this machine on 2026-09-22 (re-check with the commands below):

| Item                                                                         | Status                                                                                                                 |
| ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Windows 11 Home 10.0.26200, i9-13900K, 64 GB, RTX 4090 (driver 32.0.16.1664) | OK                                                                                                                     |
| Zig                                                                          | **not installed**; `winget` offers `zig.zig` 0.16.0, which matches `minimum_zig_version` in `build.zig.zon`            |
| Visual Studio Build Tools 2022 (17.14)                                       | installed, **but without the C++ toolset and without a Windows 10/11 SDK** (only the 8.1 kit and .NET SDK are present) |
| PowerShell 7.6, Git 2.54, winget, Python (miniconda)                         | OK                                                                                                                     |
| pandoc                                                                       | absent (only needed for `-Demit-docs`; docs default to off without it)                                                 |

## 1. Install the toolchain (one time)

### Zig 0.16.0

```powershell
winget install --id zig.zig --exact --version 0.16.0
# open a new shell, then:
zig version   # must print 0.16.0
```

winget puts a `zig.exe` shim in `%LOCALAPPDATA%\Microsoft\WinGet\Links`,
which is on PATH for new shells. If `zig` is still not found in the agent's
shell, prepend that directory to `$env:PATH` for the session.

### MSVC toolset + Windows 11 SDK (recommended)

Ghostty defaults Windows targets to the MSVC ABI (`src/build/Config.zig:100-111`).
Zig needs the MSVC CRT libraries and the Windows SDK to link for that ABI.
Add the "Desktop development with C++" workload to the existing Build Tools
install (needs an elevated prompt, roughly 4 GB):

```powershell
& "C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe" modify `
  --installPath "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools" `
  --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive --norestart
```

Verify: `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\<ver>\`
exists and `C:\Program Files (x86)\Windows Kits\10\Include\<ver>\um\windows.h` exists.
Zig finds both automatically; no `vcvars` shell is needed.

Why MSVC rather than GNU: PDB symbols (WinDbg, Visual Studio, RemedyBG),
it is upstream's default so future upstream Windows fixes land on this path,
and every C/C++ dependency in `pkg/` already has MSVC handling.

### Fallback: GNU ABI, no MSVC needed

Zig ships mingw-w64 headers and builds import libraries itself, so this
works with nothing else installed. Use it if the MSVC install is a problem:

```powershell
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu
```

Debug info is then DWARF inside the PE (use `lldb`/`gdb`, not WinDbg).
CI builds libghostty-vt with this ABI, so the C deps are known to compile.

### Windows settings that avoid build-time surprises

- **Developer Mode** (Settings, System, For developers): lets `zig fetch`
  create symlinks when unpacking tarballs (the libxml2 tarball is the known
  offender; `src/font/backend.zig:50` mentions it).
- **Long paths:** `git config --global core.longpaths true`, and set
  `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled` to 1.
- **Line endings:** the repo's `.gitattributes` forces LF for sources. Keep
  `core.autocrlf` at `input` or `false`. Never commit CRLF.
- Optional: exclude the repo, `%LOCALAPPDATA%\zig`, and `.zig-cache` from
  Defender real-time scanning; it roughly halves cold build time.

## 2. Build

All commands run from the repo root in PowerShell.

```powershell
# Toolchain smoke test. This is what upstream CI builds on Windows today.
zig build -Demit-lib-vt

# The app (`win32` is the default runtime on Windows; the flag is explicit).
zig build -Dapp-runtime=win32
# -> zig-out\bin\ghostty.exe, zig-out\share\ghostty\... (resources)

# Release build
zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast

# Build and launch, passing config flags after --
zig build run -Dapp-runtime=win32 -- --font-size=14
```

Notes:

- Cold build compiles FreeType, HarfBuzz, glslang, SPIRV-Cross, simdutf,
  highway, oniguruma, imgui. Expect several minutes the first time; later
  builds are incremental.
- `zig build run` sets `GHOSTTY_RESOURCES_DIR` to `zig-out\share\ghostty`
  (see `build.zig`, run step). When launching `ghostty.exe` directly,
  resources are found by walking up from the exe (`src/os/resourcesdir.zig`),
  so `zig-out\bin\ghostty.exe` works as-is.
- The exe is a GUI-subsystem binary (`src/build/GhosttyExe.zig:44-49`):
  nothing prints to the console unless the process attaches one. P0-04
  added `attachParentConsole` (`src/os/windows.zig`), called at the top of
  `main` for Debug builds or when a `+action` is present, so `ghostty
+version` and debug logs print to the launching terminal. PowerShell does
  not wait for a GUI exe; pipe it (`ghostty +version | Out-String`) or use
  `Start-Process -Wait -PassThru` to get the exit code.

## 3. Test

```powershell
# Targeted (always prefer this; the full suite is slow)
zig build test -Dtest-filter="pty"
zig build test -Dtest-filter="Command"

# libghostty-vt tests (upstream-supported on Windows)
zig build test-lib-vt -Dtest-filter="<name>"

# Whole suite (green on Windows since P0-05; track new failures in STATUS.md)
zig build test
```

Tests that cannot run on Windows use
`if (builtin.os.tag == .windows) return error.SkipZigTest;` (see
`src/os/xdg.zig:168`). Do the same for new tests that need POSIX.

## 4. Run and observe

- Launch: `.\zig-out\bin\ghostty.exe` or `zig build run -Dapp-runtime=win32`.
- Logging: `std.log` writes to stderr. Set `GHOSTTY_LOG=1` (the value is
  parsed by `src/global.zig:148-155`) and, once P0-05 is done, run from a
  terminal to see it. Debug builds log at `.debug` level.
- Config for experiments: pass `--key=value` flags on the command line, or
  write `%APPDATA%\ghostty\config.ghostty` (created as a template on first
  run; `%LOCALAPPDATA%\ghostty\config[.ghostty]` is still read as a
  fallback when the `%APPDATA%` files are missing).
- Kill a hung instance: `Stop-Process -Name ghostty`.

## 5. Debug

- Debug build (`-Doptimize=Debug`, the default) with the MSVC ABI produces
  `zig-out\bin\ghostty.pdb`. Open in WinDbg (`winget install Microsoft.WinDbg`)
  or attach from Visual Studio.
- Zig's own panic handler prints a stack trace to stderr (needs the console
  attached) and works with PDBs.
- GL debugging: the renderer enables `GL_DEBUG_OUTPUT` in debug builds and
  logs driver messages (`src/renderer/OpenGL.zig`, `prepareContext`). For
  frame captures use RenderDoc (`winget install RenderDoc.RenderDoc`).
- ConPTY/console debugging: run the child shell manually with the same
  argv to separate shell problems from pty problems.
- Message-loop debugging: Spy++ ships with Visual Studio; `WinSpy` from
  winget is a lighter alternative.

## 6. Formatting and hygiene

```powershell
zig fmt src/apprt/win32 src/os src/renderer   # or the exact files touched
```

Do not run `prettier -w .` on the whole tree from Windows unless it is
installed; it is only needed for non-Zig files you changed.
