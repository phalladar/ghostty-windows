# P2-06 — Config paths and Windows defaults: `%APPDATA%`, home, shell, TERM, locale, hostname

**Phase:** P2 · **Depends on:** P0-04 · **Size:** M ·
**Touches:** `src/os/xdg.zig`, `src/os/homedir.zig`, `src/config/path.zig`,
`src/config/Config.zig` (default command), `src/termio/Exec.zig` (TERM/TERMINFO),
`src/os/locale.zig`, `src/os/hostname.zig`, `src/termio/shell_integration.zig`
(`detectShell`), `src/os/edit.zig`, `src/cli/edit_config.zig`.

## Goal

Ghostty behaves like a well-mannered Windows app: config at
`%APPDATA%\ghostty\config`, `~` works in config values, the default shell
is PowerShell, `TERM` is sane for ConPTY, children get a UTF-8 `LANG`,
the hostname is correct for OSC 7, and `+edit-config` opens an editor.

## Read before starting (~300 lines)

- `src/os/xdg.zig:1-120` (`config`/`cache`/`state`, `dir` with
  `windows_env`, and the `home\.config` fallback).
- `src/os/homedir.zig:70-115` (`homeWindows`, `expandHome`).
- `src/config/path.zig:150-175` (`~` expansion skipped on Windows).
- `src/config/Config.zig:4726-4808` (default `command`/`working-directory`
  including the Windows `cmd.exe` branch at `:4770-4774`), `:5283`
  (`probableCliEnvironment`), `:4168-4238` (`loadDefaultFiles`).
- `src/termio/Exec.zig:630-665` (TERM/COLORTERM/TERMINFO env),
  `:1973-2006` (Windows shell argv handling).
- `src/os/locale.zig:30-60` (early return on Windows).
- `src/os/hostname.zig` (whole).
- `src/termio/shell_integration.zig:130-170` (`detectShell`).
- `src/os/edit.zig` (whole), `src/cli/edit_config.zig:80-140`.

## Steps

1. **xdg:** in `dir`, for Windows use per-kind env: config →
   `APPDATA` (Roaming), cache/state → `LOCALAPPDATA`. Keep `XDG_*` as the
   first lookup so power users can override. Keep the existing
   `LOCALAPPDATA` config location as a _read-only fallback_ so an
   existing `%LOCALAPPDATA%\ghostty\config` still loads (check
   `loadDefaultFiles` to see how multiple candidate files are already
   handled; add the fallback there rather than in `xdg.zig` if cleaner).
   Update the Windows-skipped tests to run with fake env maps.
2. **home:** `USERPROFILE` first, then `HOMEDRIVE`+`HOMEPATH`. `expandHome`
   on Windows: expand `~/` and `~\`.
3. **config/path.zig:** enable `~` expansion on Windows (same helper).
4. **Default shell:** in `Config.zig` Windows branch: `pwsh.exe` if found
   on PATH (`internal_os.path.expand`-style lookup or `SearchPathW`),
   else `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`,
   else `%COMSPEC%`. Keep `cmd.exe` special case in `Exec.zig` (it resolves
   `%COMSPEC%`); extend it so `pwsh.exe`/`powershell.exe` bare names are
   accepted (they go through `CreateProcessW` search anyway).
   Default `working-directory` = home.
5. **TERM:** in `Exec.zig`, on Windows set `TERM=xterm-256color` and do
   not set `TERMINFO` (there is no compiled database). Keep
   `TERM_PROGRAM=ghostty`, `COLORTERM=truecolor`. Leave the `term`
   config option working: if the user sets it, honour it verbatim.
6. **Locale:** `setlocale(LC_ALL, ".UTF-8")` on the process (UCRT accepts
   it), and for children put `LANG=<xx_YY>.UTF-8` in the env map derived
   from `GetUserDefaultLocaleName` (`en-US` → `en_US`) unless `LANG` is
   already set. Put the extern in `src/os/windows.zig`.
7. **Hostname:** `GetComputerNameExW(ComputerNameDnsHostname)` → UTF-8.
8. **detectShell:** compare the basename case-insensitively with a
   trailing `.exe` stripped, so `bash.exe` (Git Bash), `nu.exe`, `fish.exe`
   (MSYS2) get their integrations. Add a unit test.
9. **`+edit-config`:** on Windows, `ShellExecuteW(L"open", path)` fails
   for unregistered `config` files; instead resolve `$VISUAL`/`$EDITOR`
   else `notepad.exe`, and spawn via `Command.zig` with the path; wait for
   exit. Remove the "unsupported on Windows" early return.
10. **Config template:** the template written on first run
    (`loadDefaultFiles` writes a commented template) should land in the
    new `%APPDATA%` location.

## Acceptance

- Fresh profile (rename `%APPDATA%\ghostty` and `%LOCALAPPDATA%\ghostty`
  temporarily): first launch creates `%APPDATA%\ghostty\config`.
- `font-family = ~/fonts/...`-style value expands (verify with
  `+show-config` on a config that uses `~`).
- Default launch opens `pwsh` (prompt shows `PS`); `--command=cmd.exe`
  opens cmd; `--command="wsl.exe ~"` opens WSL.
- In WSL/Git Bash `echo $TERM` prints `xterm-256color` and `vim` starts
  without "unknown terminal type".
- `ghostty +edit-config` opens the config in the editor.
- `zig build test -Dtest-filter="xdg"` and `-Dtest-filter="shell_integration"`
  pass on Windows (tests un-skipped where possible).

## Gotchas

- `APPDATA` can be a UNC path on domain machines; treat as opaque.
- `SearchPathW` honours `PATHEXT`; if you use a manual PATH walk, append
  `.exe`.
- `TERM=xterm-256color` is also what Windows Terminal advertises; do not
  invent a `ghostty` TERM for Windows until a compiled terminfo ships
  (P5-02 option).
- `setlocale` must run before any FreeType/HarfBuzz init? No; it only
  affects CRT string functions; call it in `global.init` alongside
  `ensureLocale`.
- `Command.argIterator` for `.shell` values uses POSIX-style parsing, so
  backslashes are escapes: `C:\msys64\...\fish.exe` as a `.shell` string
  loses its separators and `detectShell` sees the wrong basename. Forward
  slashes or the `direct:` form work. The default full-path PowerShell is
  stored as `.direct` for this reason; `pwsh.exe` stays bare because its
  Store install path contains spaces.
- Upstream's default file is `config.ghostty`, so the template is written to
  `%APPDATA%\ghostty\config.ghostty`, not `...\config`.
- `LANG` is set on the Ghostty process via `SetEnvironmentVariableW`. On
  Windows `Environ` reads the PEB directly, so children inherit it without
  `syncEnviron`.
- `shell_integration` tests `xdg: empty/existing XDG_DATA_DIRS` stay skipped
  on Windows. They hard-code `:` as the separator, and whether MSYS2 fish
  wants `:` or `;` is an open question (P2-07/P2-08).
- Launch-time desktop screenshots can pick up unrelated windows. Check the
  process tree instead (`Win32_Process` with `ParentProcessId`).

## Out of scope

PowerShell integration script (P2-07), `%APPDATA%` migration of cache.

## Wrap-up

Tick P2-06. Update `02-environment.md` section 4 (config location) and
`04-current-state.md` rows.
