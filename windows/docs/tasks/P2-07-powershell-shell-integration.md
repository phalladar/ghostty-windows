# P2-07 — Shell integration for PowerShell (and cheap cmd.exe prompt marks)

**Phase:** P2 · **Depends on:** P2-06 · **Size:** M ·
**Touches:** `src/termio/shell_integration.zig`, `src/config/Config.zig`
(`ShellIntegration` enum), new `src/shell-integration/powershell/ghostty.ps1`,
`src/build/GhosttyResources.zig` (only if the directory copy is filtered by name),
`src/termio/Exec.zig` (argv injection).

## Goal

With the default `shell-integration = detect`, launching `pwsh.exe` or
`powershell.exe` gives prompt marks (OSC 133), working-directory
reporting (OSC 7), title updates, and `GHOSTTY_SHELL_FEATURES` honouring,
so `jump_to_prompt`, `new_tab` inheriting the cwd, and the
`command_finished` action work. cmd.exe gets prompt marks via `PROMPT`.

## Read before starting (~350 lines)

- `src/termio/shell_integration.zig:1-120` (`Shell` enum, `setup`, feature
  flags), `:130-170` (`detectShell`), `:290-410` (bash injection as the
  model for "rewrite argv + env"), `:620-700` (fish/elvish `XDG_DATA_DIRS`
  approach), `:690-760` (tests).
- `src/shell-integration/bash/ghostty.bash` and
  `src/shell-integration/zsh/ghostty-integration` (what OSC sequences are
  emitted and how features are gated: `cursor`, `sudo`, `title`,
  `ssh-env`, `ssh-terminfo`).
- `src/shell-integration/README.md` (contract for integration scripts).
- `src/config/Config.zig`: grep `shell-integration` and `ShellIntegration`
  (`:8811` region), `shell-integration-features`.
- `src/termio/Exec.zig:1973-2006` (Windows argv from the shell string).
- `src/build/GhosttyResources.zig:105-120` (shell-integration install).

## Design

**Detection:** add `.pwsh` to `Shell` and `Config.ShellIntegration`
(`powershell` as an accepted alias in the config parser if the enum
parsing allows aliases; else document `pwsh`). `detectShell` matches
`pwsh`, `pwsh.exe`, `powershell`, `powershell.exe` (case-insensitive).

**Injection:** PowerShell has no `ENV`/`ZDOTDIR` hook. Append to argv:
`-NoExit -Command ". '<resources>\shell-integration\powershell\ghostty.ps1'"`
(single quotes; escape `'` in the path as `''`). Skip injection when the
user's argv already contains any of `-Command`, `-c`, `-File`, `-f`,
`-EncodedCommand`, `-e`, `-NoExit` (case-insensitive, prefix match on
PowerShell's abbreviated switches is acceptable: `-Com`, `-Fi`), or
`-NoProfile` is _not_ a blocker (profile still loads, our script runs
after it). Pass `GHOSTTY_RESOURCES_DIR` and `GHOSTTY_SHELL_FEATURES` in
env as for other shells.

**`ghostty.ps1`** (keep it dependency-free; PSReadLine optional):

- Guard: return if `$env:GHOSTTY_SHELL_INTEGRATION_NO_PWSH` or if already
  loaded; `$env:TERM_PROGRAM -ne 'ghostty'` → return.
- Save the existing `prompt` function; define a new `prompt` that emits
  `ESC ] 133 ; D ; <exitcode> BEL` (from `$LASTEXITCODE`/`$?`) then
  `ESC ] 133 ; A BEL`, the original prompt output, `ESC ] 133 ; B BEL`;
  emit `ESC ] 7 ; file://<hostname>/<path with forward slashes> BEL`
  (URL-encode spaces; `C:\Users\x` → `file://host/C:/Users/x`), and, if
  the `title` feature is on, `ESC ] 2 ; <cwd> BEL`.
- Command start (`133;C`): with PSReadLine, wrap
  `PSConsoleHostReadLine` so that after the user presses Enter the
  function writes `ESC ] 133 ; C BEL` before returning the line; without
  PSReadLine, fall back to emitting `C` at the start of `prompt`'s
  previous cycle (less precise; acceptable).
- Cursor feature: `[Console]::Write("`e[5 q")`(bar cursor) when`cursor`is in`GHOSTTY_SHELL_FEATURES`.
- Respect `$env:GHOSTTY_SHELL_FEATURES` list exactly as bash does.
- Use `[char]27` and `[char]7`; avoid `Write-Host` (goes through the
  host formatter) — use `[Console]::Write`.

**cmd.exe:** if `detectShell` sees `cmd.exe` and integration is on, set
`PROMPT=$E]133;D$E\$E]133;A$E\$P$G$E]133;B$E\` in the child env (only if
the user has not set `PROMPT`). No OSC 7 (cmd cannot emit the cwd
reliably without a helper); note this limitation.

## Steps

1. Enum and detection changes with unit tests (`detectShell` matrix).
2. Argv injection with tests (`pwsh`, `pwsh -NoLogo`, `pwsh -Command x`
   → no injection, `powershell.exe -NoProfile` → injected).
3. Write `ghostty.ps1`; test manually in pwsh 7 and Windows PowerShell 5.1.
4. Verify resources install: `zig-out\share\ghostty\shell-integration\powershell\ghostty.ps1` exists.
5. Manual: `jump_to_prompt` keybind (`ctrl+shift+up`?) moves between
   prompts; open a new tab (P3) inherits the cwd; `Get-ChildItem` then
   observe `command_finished` action in the debug log; run a failing
   command and see the exit code in the `D` mark (debug log or
   `+list-...`? use the inspector once it exists; the log is enough).

## Acceptance

- Unit tests pass (`zig build test -Dtest-filter="shell_integration"`).
- In pwsh 7: prompt marks visible via `jump_to_prompt`; OSC 7 sets the
  surface pwd (check the `pwd` action in the debug log after `cd C:\`).
- In Windows PowerShell 5.1: script loads without errors.
- With `-Command` in the user's `command`, no injection happens.
- cmd.exe prompt marks appear (`jump_to_prompt` works in cmd).

## Gotchas

- Windows PowerShell 5.1 is UTF-16 host-internal; `[Console]::Write` of
  `[char]27` works, but `OutputEncoding` must be UTF-8 for non-ASCII
  cwd in OSC 7: set `[Console]::OutputEncoding = [Text.Encoding]::UTF8`
  only if not already.
- `$?`/`$LASTEXITCODE` semantics differ (native vs cmdlet); report
  `$LASTEXITCODE` if the last command was native, else `0`/`1` from `$?`.
- ConPTY passes OSC 133 and OSC 7 through on Windows 11; if marks do not
  arrive, test with `$env:GHOSTTY_LOG=1` and the termio debug logs first
  before blaming the script.
- The `-Command` string is parsed by PowerShell, not cmd; do not use
  cmd quoting.
- Quoting through `Exec.zig`'s whitespace split: build the argv list
  directly (the `.direct` form) so the `. '...'` argument stays one token.

- `PROMPT=$P$G` is set system-wide on Windows, so "only if unset" would
  never fire; cmd integration wraps the existing `PROMPT` instead and skips
  it when it already contains `]133;`.
- Detect PSReadLine with `Test-Path Function:PSConsoleHostReadLine`, not
  `Get-Command` (autoloads PSReadLine) or `Get-Item -ErrorAction
SilentlyContinue` (pushes an entry into `$Error` every prompt, which
  breaks the cmdlet-vs-native exit code heuristic).
- Without keyboard input (before P1-04), type into the child by running a
  helper that `FreeConsole` → `AttachConsole(childPid)` → `WriteConsoleInputW`
  on `CONIN$`; ConPTY children accept it. `WM_CLOSE` closing without the
  confirm dialog proves `cursorIsAtPrompt` (i.e. OSC 133 marks arrived).
- The prompt mark is `OSC 133;A;redraw=0`: PSReadLine never redraws the
  prompt on resize, so without it the core clears the prompt lines on every
  resize and they stay blank (see P4-03 "Resize fix").

## Out of scope

Oh-My-Posh/Starship coexistence testing beyond "does not break" (they
redefine `prompt`; load order matters: our wrapper wraps theirs if we
run last, which `-NoExit -Command` guarantees).

## Wrap-up

Tick P2-07. Add `powershell` to the shell list in the repo docs later
(P5-05).
