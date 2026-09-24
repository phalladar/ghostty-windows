# STATUS — Windows port progress

Load this file first in every session. Pick the first unchecked task
whose "needs" are all checked. Keep this file under 150 lines: one line
per task, short notes, no logs.

Legend: `[ ]` not started · `[~]` in progress · `[x]` done · `[-]` skipped (say why)

## Next up

- All tasks are [x] or [-]. See "Remaining work" below.

## P0 — Compile the world

- [x] P0-01 toolchain + lib-vt smoke build — needs: none — 2026-09-22 zig 0.16.0 (winget; prepend %LOCALAPPDATA%\Microsoft\WinGet\Links to PATH in agent shells), MSVC 14.44 + SDK 10.0.26100; lib-vt build + Parser tests pass; `-Dapp-runtime=none` fails: `posix_c.h:2:10: fatal error: 'pwd.h' not found` (P0-02)
- [x] P0-02 win32 runtime skeleton + build wiring + posix_c gating — needs: P0-01 — 2026-09-22 remaining errors all in renderer: Dmabuf.zig:44,55 (*anyopaque vs int); link then needs EGL syms + WinMain
- [x] P0-03 renderer: WGL provider + direct present, exe links — needs: P0-02 — 2026-09-22 exe links; wgl test: NVIDIA RTX 4090, GL 4.3.0 NVIDIA 616.64; msvc entry=mainCRTStartup (WinMain fix); blit not Y-flipped (verify in P1-02)
- [x] P0-04 CLI actions + console attach — needs: P0-03 — 2026-09-22 +version/+list-fonts/+show-config/+list-keybinds/+validate-config exit 0 in console; +list-themes/+boo run (TUI, not exit-checked); gtk build not runnable here (no GTK headers)
- [x] P0-05 unit tests build; Windows-relevant tests pass — needs: P0-03 — 2026-09-22 no source changes needed; full suite 3768 pass / 60 skip / 0 fail

## P1 — Hello terminal

- [x] P1-01 window classes, message loop, wakeup, surface lifecycle, clean exit — needs: P0-03, P0-04 — 2026-09-22 title/initial_size/min size/tick/WM_CLOSE→exit 0 verified; app quits on last window close; default size fixed in P3-01
- [x] P1-02 first pixels, resize, DPI, swap interval — needs: P1-01 — 2026-09-23 upright (no Y-flip needed), live resize reflow, 96↔144 DPI reflow, minimise pauses; vsync on 240fps / off 2000-3000fps (ReleaseFast); full suite 3792 pass/58 skip
- [x] P1-03 ConPTY EOF/shutdown/handle fixes — needs: P0-05 — 2026-09-22 self-exit + kill close surface (exit 0), conhost not leaked, 100 spawn cycles handle drift 0; ConPTY closed before reader quit (deviation, see task Gotchas)
- [x] P1-04 keyboard basic — needs: P1-02 — 2026-09-23 key.zig translate + unit tests; text/editing/arrows/F-keys/history/Tab/repeat verified; Ctrl+C interrupts ping when launched from a normal parent
- [x] P1-05 focus, occlusion, mouse basics, cursor shape — needs: P1-02 — 2026-09-23 SGR mouse report/wheel/X1, focus ESC[I/O, I-beam/arrow, scrollback, selection, hide-while-typing, minimise restore OK; less(Git Bash) check substituted by pwsh mouse logger

## P2 — Daily driver

- [x] P2-01 keyboard full (layouts, AltGr, dead keys, kitty) — needs: P1-04 — 2026-09-23 US/US-Intl/German/French via unit tests (HKL loaded w/o activation; JIS not installed); AltGr, dead keys+preedit, kitty press/repeat/release, fake-LCtrl filtered, VK_PACKET/WM_CHAR text incl. surrogates
- [x] P2-02 mouse full (click timing, precision scroll) — needs: P1-05 — 2026-09-23 click interval = GetDoubleClickTime; double/triple click select; precision wheel (non-120 deltas) to pixels; capture-loss release fixed; drag autoscroll; ctrl+click reaches opener. Real touchpad simulated only
- [x] P2-03 clipboard — needs: P1-04 — 2026-09-23 copy/paste/copy-on-select, CRLF→LF, unsafe-paste + OSC 52 write prompts (MessageBoxW), emoji/CJK round trip; OSC 52 read unreachable (ConPTY swallows it)
- [-] P2-04 IME — needs: P2-01 — 2026-09-23 implemented (ime.zig: preedit, commit via key path, cand/comp window at cursor, dup-char suppression) + in-process tests pass; live JA/ZH/KO + Win+. acceptance NOT run (no IME installed; see Deviations)
- [x] P2-05 window chrome, theme, icon, bell, URLs, fullscreen, reload — needs: P1-05 — 2026-09-23 dark/light/ghostty caption, icon, bell flash+title, fullscreen/maximize, OSC 8 safety (cmd.exe refused, folder opens), reload + error dialog; live OS theme flip not exercised (message path tested)
- [x] P2-06 config paths and Windows defaults — needs: P0-04 — 2026-09-22 config in %APPDATA%\ghostty\config.ghostty (legacy %LOCALAPPDATA% read-only fallback); default shell pwsh→powershell→cmd; TERM=xterm-256color; vim check only in Git Bash (WSL has only docker-desktop)
- [x] P2-07 PowerShell shell integration — needs: P2-06 — 2026-09-23 pwsh 7/5.1/cmd auto-injected; OSC 133 A/B/C/D(exit code)/7/title verified; -Command skips injection; jump_to_prompt proven via no-confirm close (re-test with keybind after P1-04)

## P3 — Multi-surface

- [x] P3-01 multiple windows, quit semantics — needs: P1-05, P2-03 — 2026-09-23 independent windows, no handle leak, default 80x24 + cascade, goto_window, quit/close-all confirm, quit delay; new-window-during-quit-delay verified in P4-05
- [x] P3-02 tabs — needs: P3-01 — 2026-09-23 GDI TabBar; 5 tabs cycle/goto/close/middle-click (GTK neighbour rule), OSC 2 + set_tab_title, hidden tabs paused (369 vs 1408 ms CPU/s), new tab inherits cwd (P4-03 check OK); tab-bar DPI relayout not exercised live (user desktop)
- [x] P3-03 splits — needs: P3-02 — 2026-09-23 split tree per tab (SplitView.zig): split/navigate/resize (keys+drag)/equalize/zoom/close verified by window geometry; ratios kept on resize; DPI + drag + pixels verified by user 2026-09-23
- [x] P3-04 dialogs and confirmations — needs: P3-02 — 2026-09-23 dialogs.zig: TaskDialog confirm (Esc cancels), config-errors dialog at startup+reload, prompt_title (surface/tab/window), open_config; clipboard prompt defaults to Deny (GTK)

## P4 — Depth

- [x] P4-01 font discovery improvements — needs: P0-05 — 2026-09-22 indexed 520 faces/50ms; +list-fonts 0.18s no dup families; Cascadia Mono real bold; CJK/Hangul/Indic fallback OK; emoji use bundled Noto (Segoe UI Emoji COLR not renderable by FreeType path yet)
- [-] P4-02 DirectWrite fallback (optional) — needs: P4-01 — 2026-09-22 skipped: P4-01 fallback matches IDWriteFontFallback::MapCharacters for ~150 codepoints across 30+ scripts (see task Gotchas)
- [x] P4-03 ConPTY advanced (job objects, OSC 7, process info) — needs: P1-03 — 2026-09-23 job w/ BREAKAWAY_OK (no kill-on-close), ClosePseudoConsole then TerminateJobObject after 1s; ping -t gone on close; OSC 7 Windows paths; INHERIT_CURSOR clean. New-tab-cwd verified in P3-02
- [x] P4-04 presentation upgrade (vsync policy, optional DXGI) — needs: P1-02, P3-03 — 2026-09-23 Part A (interval 1 / DwmFlush pacing, WM_SIZE waits for new-size present); user verified no tearing and clean resize. DXGI (Part B) not needed
- [x] P4-05 IPC for +new-window/+new-tab — needs: P3-02 — 2026-09-23 WM_COPYDATA to per-class message window; +new-tab/+new-window/--surface-id/--working-directory OK; malformed payloads rejected; fallback launches new instance; new window during quit delay OK; foreground raise unverified (agent not foreground)
- [x] P4-06 taskbar progress, notifications, misc actions — needs: P2-05 — 2026-09-23 ITaskbarList3 progress (all states, 15s timeout), tray-balloon notifications, command_finished bell/notify, float_window, toggle_visibility; WinRT toasts deferred to P5-02 (need AUMID shortcut)

## P5 — Ship

- [x] P5-01 manifest, VERSIONINFO, exe metadata — needs: P2-05 — 2026-09-23 VERSIONINFO fixed (was never emitted: VS_VERSION_INFO undefined), version from build cfg; manifest adds supportedOS/longPathAware/activeCodePage UTF-8 (GetACP=65001 verified)
- [x] P5-02 release build, zip, installer — needs: P5-01, P3-04 — 2026-09-23 ReleaseFast exe; dist/windows/make-zip.ps1 (deterministic zip, resources found); Inno Setup per-user installer w/ AUMID Start-menu shortcut + "Open Ghostty here"; silent install/uninstall leaves no trace; terminfo not compiled
- [x] P5-03 CI Windows job — needs: P0-05 — 2026-09-22 job build-windows-app added; actionlint+prettier clean; its zig commands pass locally (tests 3769/60 skip). First real CI run pending a push
- [x] P5-04 crash reporting decision — needs: P5-01 — 2026-09-23 local minidumps (+ .txt on panic) in %LOCALAPPDATA%\ghostty\crash, listed by +crash-report; stacks symbolised via dbghelp+PDB (WinDbg not installed)
- [x] P5-05 docs and known issues — needs: P5-02 — 2026-09-23 README-windows.md (install/config/shells/keys/logs/crash/known issues), README.md + HACKING.md Windows sections, 04-current-state rewritten; clean-VM walkthrough not run (no VM)

## Decisions (append; one line each, dated)

- 2026-09-22 Plan written against HEAD 4ae9f1a2d. Runtime name: `win32`. Renderer: WGL + direct SwapBuffers (see 01-strategy.md).
- 2026-09-23 ConPTY job object: BREAKAWAY_OK only, no KILL_ON_JOB_CLOSE (it killed GUI apps like VS Code launched from the shell). Close = ClosePseudoConsole, then TerminateJobObject if the shell is alive after 1s. Matches Windows Terminal.
- 2026-09-23 Crash reporting: local MiniDumpWriteDump only, no network; Sentry stays off on Windows until a public Windows release.
- 2026-09-22 ABI: msvc (default). GNU ABI lib-vt build also verified working as fallback.

- 2026-09-23 ConPTY: ship conpty.dll + OpenConsole.exe from NuGet Microsoft.Windows.Console.ConPTY (MIT) next to ghostty.exe; pinned 1.25.260710002-preview (first version that resyncs the cursor after resize). make-zip.ps1 bundles it by default; dev builds fall back to inbox conhost.
- 2026-09-23 Distribution: public repo phalladar/ghostty-windows, labelled an unofficial community port. release-windows.yml builds on tag windows-v<version> and publishes Ghostty-Windows-Setup-x64.exe / Ghostty-Windows-x64.zip / SHA256SUMS.txt (stable names for the README download links). Installer/VERSIONINFO publisher is the community port; THIRD-PARTY-NOTICES.md + font licenses ship in zip and installer.

- 2026-09-23 Windows defaults: ctrl+v = paste and ctrl+c = copy (both performable, so ^C/^V still reach apps when there is nothing to copy/paste), matching Windows Terminal. OSC 8 hyperlink cells show the pointer when an app has mouse reporting on (Windows-only).
- 2026-09-23 CI/release runners: windows-2025. windows-2022 leaked one handle per ConPTY session in the spawn test; windows-2025 passes the full suite.

## Known test failures (from P0-05; owner task in parentheses)

- None. Full `zig build test -Dapp-runtime=win32` (2026-09-23): 3810 pass, 60 skip, 0 fail; Linux cross-build + zig fmt clean. Stray "failed command" line comes from std.debug.print in src/benchmark/TerminalFormatter.zig:405 (upstream, all platforms); trust exit code + Build Summary.

## Deviations from the plan (append when a task file was wrong or a step was skipped)

- 2026-09-22 P0-03: WinMain link fix added to GhosttyExe.zig (not in plan). Windows blit skips the Y-flip the task asked for; P1-02 must confirm orientation.
- 2026-09-22 P0-04: also touched src/cli/{validate,explain}_config.zig: Writer.end() fails on Windows console handles (FileTooBig), so they flush on Windows instead.
- 2026-09-22 P5-03: acceptance "job succeeds on next push" not verifiable (no push allowed); validated locally only. Uses setup-zig cache, not actions/cache (pinact).
- 2026-09-22 P2-06: file is config.ghostty (upstream name), not `config`; +edit-config spawns via std.process not Command.zig (needs console stdio); `term=xterm-ghostty` mapped to xterm-256color on Windows.
- 2026-09-22 P4-01: Segoe UI Emoji needs COLR color rendering in the FreeType face (follow-up, fits P4-02); bundled Noto emoji stays first. .fon bitmap fonts not indexed.
- 2026-09-22 P4-02 skipped (optional; P4-01 sufficient). Open items: COLR emoji rendering (no task yet); freetype Face.name() returns platform-0 UTF-16BE names raw (shared code, cosmetic).
- 2026-09-23 P1-05: lost mouse capture mid-drag clears button state without sending a release to core (fixed in P2-02).
- 2026-09-23 P2-01: win32-input-mode (?9001) not supported (VT input works; own task if needed). Unfocused global keybinds (RegisterHotKey) not done. Surface skips TranslateMessage for keys (dead keys). One unexplained 08/7F burst seen once on an intermediate build; not reproduced.
- 2026-09-23 P2-04 marked [-]: code done, but acceptance needs a real IME; installing JA/ZH/KO input languages would alter the user's active input setup mid-session. To close: add Microsoft IME(s), run the task's manual matrix, then flip to [x].
- 2026-09-23 P3-03: white captures after ~00:55 were the monitor idle-off (all OpenGL windows blank, incl. a minimal GL test and older builds), not a regression. Re-run scratchpad p303\probe2.ps1 (with/without -Split) with the display on to confirm text renders. No unfocused-split dimming yet; no split-divider width option (5 dip gap).
- 2026-09-23 P2-03: OSC 52 clipboard _read_ never reaches Ghostty through ConPTY; `copy-on-select=primary` (non-Linux default) is a no-op on Windows (no selection clipboard). Real-clipboard unit test gated by GHOSTTY_TEST_CLIPBOARD=1.
- 2026-09-23 P2-05: ShellExecuteW runs on a worker thread (core opens URLs under renderer lock). OSC 8 schemes other than http/https/mailto/file refused (no confirm dialog yet); bell-features=border not implemented. `-Dapp-runtime=none` on Windows fails: OpenGL.zig needs rt_surface.hwnd (embedded apprt) — libghostty-on-Windows out of scope.
- 2026-09-23 P2-07: cmd.exe PROMPT is always set system-wide, so integration wraps it (skips if it already has 133). Shell integration enum gains `pwsh` (no `powershell` alias).
- 2026-09-23 P1-02: fixed renderer wakeup — libxev IOCP Async is stateful, termio now holds `*xev.Async` (Options/Termio/stream_handler/Surface.zig:681). Never copy an xev.Async by value. Window-snapping to cells (optional step) not done.
- 2026-09-23 P1-04: global keybinds not wired (App.keyEvent); processes whose parent ignores Ctrl+C pass that to the shell — consider SetConsoleCtrlHandler(null,FALSE) before spawn (P2-01). conhost requests win32-input-mode (?9001) — unimplemented, logged.
- 2026-09-23 P4-03: "new tab opens in C:\Windows" needs tabs; verify in P3-02. OpenConsole.exe/conpty.dll not bundled (optional later: load conpty.dll next to exe if present).

## User verification (2026-09-23, hand-tested on this machine)

- Rendering, colors, scrolling (no tearing/stutter), wheel scrollback: OK (P4-04).
- Resize and splits with a multi-line oh-my-posh prompt: OK with bundled ConPTY 1.25-preview (see Decisions). Output PowerShell formats while a pane is narrow stays narrow (PowerShell hard-wraps tables).
- DPI changes 100/125/150/175% with tabs + splits: OK after a settle redraw was added (P3-02/P3-03 DPI relayout verified).
- +new-tab / +new-window raise the running window (P4-05). Live Windows light/dark switch (P2-05).
- Tab drag-to-reorder and tear-off into a new window / merge into another window (added after P3-02; TabBar.zig, Window.zig).
- Touchpad: skipped (no touchpad on this machine).
- Ctrl+V paste / Ctrl+C copy-with-selection (Windows-only performable defaults) and pointer cursor over OSC 8 links in mouse-reporting apps such as Claude Code: verified in Claude Code.
- Releases: windows-v1.3.2-win.1 published from GitHub Actions (release-windows.yml on windows-2025); win.2 adds the link pointer.

## Remaining work

- P2-04: install a Microsoft JA/ZH/KO IME and run the task's manual matrix; test Win+. emoji panel.
- Real touchpad (P2-02) and SendInput KEYEVENTF_UNICODE (P2-01): quick manual checks.
- P5-03 / release-windows.yml: first real CI and release runs after the repo is pushed to GitHub. P5-05: clean-VM walkthrough of README-windows.md.
- ConPTY: move make-zip.ps1's pinned default from 1.25.260710002-preview to the first stable 1.25 on NuGet.
- Flaky hang: two ghostty-test.exe runs hung during parallel work on 2026-09-22/23, both `-Dtest-filter=windows` while other agents spawned processes; likely a ConPTY test not answering ESC[6n (see P4-03 Gotchas). Full suites passed 4x since; find the test before relying on CI.
- Not in plan yet: COLR emoji rendering, win32-input-mode, unfocused-split dimming, WinRT toasts, global hotkeys, code signing, winget, ARM64.

## Phase summaries (one line when a phase completes)

- P0: done 2026-09-22
- P1: done 2026-09-23
- P2: done 2026-09-23 except P2-04 live IME check
- P3: done 2026-09-23
- P4: done 2026-09-23; P4-02 skipped (not needed)
- P5: done 2026-09-23
