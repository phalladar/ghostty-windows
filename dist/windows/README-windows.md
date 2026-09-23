# Ghostty for Windows

Ghostty on Windows is a native Win32 application (`-Dapp-runtime=win32`)
that renders with OpenGL and runs shells through ConPTY. It is
experimental: the features below work, but see
[Known issues](#known-issues) before relying on it.

## Requirements

- Windows 11 (x86_64). Windows 10 is not tested.
- A GPU and driver that provide **OpenGL 4.3**. Any current NVIDIA, AMD or
  Intel driver does. Virtual machines without GPU acceleration and remote
  sessions that fall back to the Microsoft Basic Render Driver do not; see
  [Known issues](#known-issues).

## Portable zip

Extract `ghostty-<version>-windows-x86_64.zip` anywhere and run
`ghostty\bin\ghostty.exe`. Keep the folder layout intact: Ghostty finds its
themes, shell integration and terminfo by walking up from `bin\` to
`share\ghostty` (it looks for `share\terminfo\ghostty.terminfo`). Setting
`GHOSTTY_RESOURCES_DIR` overrides the lookup.

```
ghostty\
  bin\ghostty.exe
  share\ghostty\themes\...
  share\ghostty\shell-integration\...
  share\terminfo\ghostty.terminfo
  LICENSE
  README-windows.md
```

The portable build does not create a Start menu shortcut, so some taskbar
pinning behaviour only works with the installer.

### "Open Ghostty here" without the installer

The installer adds the context menu entry for you. For the portable build,
run this in PowerShell (no elevation needed), with `$exe` pointing at your
copy of `ghostty.exe`:

```powershell
$exe = "C:\Tools\ghostty\bin\ghostty.exe"
foreach ($key in "Directory\shell", "Directory\Background\shell", "Drive\shell") {
    $k = "HKCU:\Software\Classes\$key\Ghostty"
    New-Item -Path "$k\command" -Force | Out-Null
    Set-ItemProperty -Path $k -Name "(default)" -Value "Open Ghostty here"
    Set-ItemProperty -Path $k -Name Icon -Value "`"$exe`",0"
    Set-ItemProperty -Path "$k\command" -Name "(default)" -Value "`"$exe`" `"--working-directory=%V\.`""
}
```

The trailing `\.` keeps drive roots such as `C:\` from escaping the closing
quote. To remove the entries:

```powershell
foreach ($key in "Directory\shell", "Directory\Background\shell", "Drive\shell") {
    Remove-Item "HKCU:\Software\Classes\$key\Ghostty" -Recurse
}
```

## Installer

`ghostty-<version>-windows-x86_64-setup.exe` installs per user into
`%LOCALAPPDATA%\Programs\Ghostty` without UAC. It creates a Start menu
shortcut carrying the AppUserModelID `com.mitchellh.ghostty` and, unless
the task is unticked, an "Open Ghostty here" entry on the folder, folder
background and drive context menus. An all-users install into
`Program Files` is available from the elevation dialog or with
`/ALLUSERS`.

Silent install and uninstall:

```
ghostty-<version>-windows-x86_64-setup.exe /VERYSILENT /CURRENTUSER [/DIR="C:\path"] [/TASKS="contextmenu"]
"%LOCALAPPDATA%\Programs\Ghostty\unins000.exe" /VERYSILENT
```

Uninstalling removes the program files, shortcuts, context menu keys and
the uninstall entry. It leaves your configuration
(`%LOCALAPPDATA%\ghostty`, `%APPDATA%\ghostty`) in place.

Windows 11 shows "Open Ghostty here" under "Show more options"; the
top-level Windows 11 menu requires a packaged (MSIX) app.

## Configuration

The configuration file is `%APPDATA%\ghostty\config.ghostty`. Ghostty
creates it with a commented template on first run. A file named `config`
in the same folder is also read. `XDG_CONFIG_HOME`, if set, takes
precedence over `%APPDATA%`. Older builds used `%LOCALAPPDATA%\ghostty`;
files there are still read when nothing exists in `%APPDATA%\ghostty`.

`ctrl+,` opens the file (with the `.ghostty` file association if there is
one, otherwise `%VISUAL%`, `%EDITOR%` or Notepad) and `ctrl+shift+,`
reloads it. Errors are shown in a dialog at startup and on reload.
`ghostty +validate-config` checks the file from a console, and
`ghostty +show-config --default --docs` prints every option with its
documentation.

All options are documented on the
[Ghostty website](https://ghostty.org/docs/config). Options that only
apply to macOS or GTK are ignored.

## Shells

Without a `command` setting Ghostty starts the first of:

1. `pwsh.exe` (PowerShell 7) if it is on `PATH`,
2. Windows PowerShell 5.1
   (`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`),
3. `cmd.exe` (`%COMSPEC%`).

To use something else set `command`, for example `command = cmd.exe`. The
value is split on whitespace and backslashes act as escape characters, so
write paths with forward slashes (`command = C:/msys64/usr/bin/fish.exe -l`)
or use the `direct:` prefix.

Shells see `TERM=xterm-256color`. The Ghostty terminfo entry is shipped as
a source file only and is not installed.

Shell integration is injected automatically for PowerShell 7, Windows
PowerShell 5.1 and `cmd.exe`. PowerShell gets prompt marks, exit codes,
working directory reporting (new tabs and splits open in the same folder)
and titles; `cmd.exe` gets prompt marks only. See
`src/shell-integration/README.md` in the Ghostty source for details and for
loading it manually. Set `shell-integration = none` to turn it off.

## Keybindings

The defaults match Ghostty on Linux. The most used ones:

| Keys                            | Action                |
| ------------------------------- | --------------------- |
| `ctrl+shift+c` / `ctrl+ins`     | Copy                  |
| `ctrl+shift+v`                  | Paste                 |
| `ctrl+shift+t`                  | New tab               |
| `ctrl+shift+n`                  | New window            |
| `ctrl+shift+w`                  | Close tab             |
| `alt+1` … `alt+8`, `alt+9`      | Go to tab N, last tab |
| `ctrl+tab`, `ctrl+pgdn`         | Next tab              |
| `ctrl+shift+o` / `ctrl+shift+e` | Split right / down    |
| `ctrl+alt+arrow`                | Move between splits   |
| `ctrl+enter`                    | Toggle fullscreen     |
| `ctrl+shift+q`                  | Quit                  |

`ghostty +list-keybinds --default` prints the full list.

## Logs

Ghostty is a GUI program, so it has no console of its own. To capture its
log, start it with standard error redirected to a file. From PowerShell:

```powershell
Start-Process ghostty.exe -RedirectStandardError "$env:TEMP\ghostty.log"
```

From `cmd.exe`:

```
ghostty.exe 2> %TEMP%\ghostty.log
```

Release builds log at `info` level and above; debug builds also log
`debug` messages and attach to the console they were started from.
`GHOSTTY_LOG=false` disables logging and `GHOSTTY_LOG=stderr` turns it back
on (see "Logging" in `HACKING.md`).

## Crash reports

When Ghostty crashes it writes a minidump (`.dmp`) to
`%LOCALAPPDATA%\ghostty\crash` (or `%XDG_STATE_HOME%\ghostty\crash` when
`XDG_STATE_HOME` is set). A Zig panic also writes a `.txt` file with the
panic message next to the dump. Nothing is sent anywhere.

List the reports from a console:

```
ghostty +crash-report
```

When reporting a crash, attach the `.dmp` (and `.txt`, if present) and
say which build you ran. Dumps are symbolised with the `ghostty.pdb` from
the same build, so keep it if you build Ghostty yourself.

> [!WARNING]
>
> A minidump contains the stack of every thread at the time of the crash
> and the memory those stacks point to, which can include terminal contents
> or other sensitive data. Review before sharing it publicly.

## Troubleshooting

- **SmartScreen warns about the installer or `ghostty.exe`.** Releases
  built by this process are not code signed (see
  [Code signing](#code-signing)). Choose "More info", then "Run anyway".
- **Ghostty exits at start or shows no window.** Capture a log (see
  [Logs](#logs)) and look for OpenGL errors. Ghostty needs OpenGL 4.3; update
  the GPU driver, or see the remote desktop entry under
  [Known issues](#known-issues).
- **Themes or shell integration are missing.** The `share` folder is not
  where Ghostty expects it. Keep the zip layout intact or set
  `GHOSTTY_RESOURCES_DIR` to the `share\ghostty` folder.
  `ghostty +list-themes` is a quick check.
- **A font is not found.** `ghostty +list-fonts` lists the families
  Ghostty sees, from both the system and the per-user font folders.
- **`ghostty +new-tab` or `+new-window` does nothing or opens a separate
  instance.** The command talks to a running Ghostty with the same `class`.
  It cannot reach a Ghostty running elevated ("as administrator") from a
  non-elevated console, and the reverse.
- **Ctrl+C does not interrupt programs.** This happens when Ghostty itself
  was started by a process that ignores Ctrl+C; the setting is inherited
  by the shell. Start Ghostty from the Start menu, Explorer or a normal
  shell.

## Known issues

Platform limitations:

- **Remote desktop and virtual machines.** Without a GPU that provides
  OpenGL 4.3 (RDP sessions using the Microsoft Basic Render Driver, VMs
  without GPU acceleration) the renderer cannot start.
- **OSC 52 clipboard read** does not work: ConPTY does not forward the
  query to the terminal. OSC 52 clipboard writes work.
- **`copy-on-select = primary`**, the default outside Linux, does nothing
  because Windows has no selection clipboard. Set `copy-on-select =
clipboard` to copy selections to the clipboard.
- **win32-input-mode** (`CSI ? 9001 h`), which ConPTY requests at startup,
  is not supported. Input is sent as VT sequences instead.
- **Elevated and non-elevated instances** cannot talk to each other
  (`+new-tab`, `+new-window`), because Windows blocks the message from a
  lower integrity level.
- **`ghostty +ssh`** cannot install terminfo on the remote host: it relies
  on ssh `ControlMaster`, which Windows OpenSSH does not support. Plain
  `ssh` works; the remote side sees `TERM=xterm-256color`.
- The "Open Ghostty here" entry only appears under "Show more options".
- **Resizing without the bundled ConPTY** (`conpty.dll` and
  `OpenConsole.exe` missing from the `bin` folder) loses lines at the top
  and can garble the prompt, because the inbox console host repaints the
  screen after every resize. See "Bundled ConPTY" below.

Not implemented yet:

- **IME** (Japanese, Chinese, Korean input): implemented, including the
  candidate window at the cursor, but not yet verified with a real IME.
  Reports are welcome.
- **Color emoji** use the bundled Noto Color Emoji font. Segoe UI Emoji
  (COLR color font) is found but renders in grayscale if selected.
- **Desktop notifications** are shown as tray balloons, not WinRT toasts,
  so they have no actions and are hidden while Focus Assist is on.
- **Unfocused split dimming** (`unfocused-split-opacity`,
  `unfocused-split-fill`) has no effect.
- **Global keybindings** (`global:`) are not registered.
- **Quick terminal**, **terminal inspector**, **command palette** and the
  **search** overlay are not available.
- **`background-opacity`** and **`background-blur`**: the window is always
  opaque.
- **`bell-features = border`** has no effect (the other bell features
  work).
- **OSC 8 links** open only `http`, `https`, `mailto` and local `file`
  URLs (folders and non-executable files); other schemes are refused.
- **Localization**: the UI is English only (i18n is not built on
  Windows).
- `.fon` bitmap fonts are not listed.
- No code signing and no winget package. Only x86_64 builds are produced.

## Building a release

Requirements: Zig (see `build.zig.zon`), PowerShell 5.1+ and, for the
installer, Inno Setup 6
(`winget install --id JRSoftware.InnoSetup -e`). Setting up the Zig and
MSVC toolchain on Windows is described under "Windows" in `HACKING.md`.

```
zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast -Dversion-string=1.2.3 -p build\release
pwsh -File dist\windows\make-zip.ps1 -Prefix build\release -OutDir build\dist
ISCC.exe /DAppVersion=1.2.3 /DSourceDir=build\dist\staging\ghostty /DOutputDir=build\dist dist\windows\installer\ghostty.iss
```

`-Doptimize=ReleaseFast` strips the executable by default. `make-zip.ps1`
reads the version from `ghostty.exe +version` unless `-Version` is given,
and writes entries in sorted order with a fixed timestamp so the same
inputs produce the same zip with the same PowerShell edition
(5.1 and 7 use different deflate implementations). The unpacked tree is
left in `<OutDir>\staging\ghostty` for the installer. `ISCC.exe` is not
long-path aware, so keep `OutDir` short enough that
`staging\ghostty\share\...` stays under 260 characters.

### Bundled ConPTY

Releases should ship `conpty.dll` and `OpenConsole.exe` from Microsoft's
MIT-licensed [`Microsoft.Windows.Console.ConPTY`](https://www.nuget.org/packages/Microsoft.Windows.Console.ConPTY)
NuGet package next to `ghostty.exe`. When they are present Ghostty uses
them instead of the ConPTY built into Windows; without them it falls back
to the inbox `conhost.exe`, which repaints the whole screen after every
resize and garbles reflowed output and multi-line prompts. They are not
checked into the repository. `make-zip.ps1` downloads the pinned package
version by default (checked against a pinned SHA-256). Use
`-ConptyVersion <v>` to pick another version, `-ConptyDir <dir>` to take
both files from a local folder, or `-NoConpty` to leave them out. Output
goes to `dist\windows\out\` (git-ignored) unless `-OutDir` is given:

```
pwsh -File dist\windows\make-zip.ps1 -Prefix build\release
```

The pinned default is `1.25.260710002-preview`: 1.25 is the first version
that resynchronises the cursor after a resize, and it is still a preview
on NuGet. Move the default to the first stable 1.25 release when one
ships.

The installer packages whatever `bin\` holds in the staged tree. Version
1.25 or newer is needed for correct resizing: older versions do not
resynchronise the cursor with the terminal after a resize. For a dev
build, copy the two files into `zig-out\bin`.

## Code signing

Nothing is signed by this process, so SmartScreen warns on first run of
the installer and the executable. To sign a release, sign `ghostty.exe`
before running `make-zip.ps1`, then sign the setup program and its
uninstaller:

```
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /f cert.pfx /p <password> build\release\bin\ghostty.exe
```

For the installer, register the same command as an Inno Setup sign tool
(`ISCC.exe "/Ssigntool=signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /f cert.pfx /p <password> $f" ...`)
and add `SignTool=signtool` to the `[Setup]` section so both
`setup.exe` and `unins000.exe` are signed. An OV or EV code signing
certificate (or Azure Trusted Signing) is needed for SmartScreen
reputation.

## winget

A winget manifest can point at the setup program later with
`InstallerType: inno`, `Scope: user`, and the silent switches above. No
manifest is submitted yet.
