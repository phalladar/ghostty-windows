# 00 — Index of the Windows port docs

Written 2026-09-22 against HEAD `4ae9f1a2d`. Everything here is designed
to be read one file at a time; see `windows/CLAUDE.md` for the loading rules.

## Reference docs (load only when a task says so)

| File                   | Lines | When to load                                                                                                    |
| ---------------------- | ----- | --------------------------------------------------------------------------------------------------------------- |
| `01-strategy.md`       | ~130  | Once, before P0-02; whenever a design question comes up ("why WGL?", "why not GTK?")                            |
| `02-environment.md`    | ~150  | P0-01, and whenever a build/test/run command is unclear                                                         |
| `03-conventions.md`    | ~150  | Before writing any Windows-specific Zig (P0-02 onward)                                                          |
| `04-current-state.md`  | ~140  | When you need to know whether something already exists or is a known bug; each task lists the rows it relies on |
| `05-architecture.md`   | ~150  | Once before P1-01; again before P3-03                                                                           |
| `06-apprt-contract.md` | ~200  | P0-02, P1-01, and any task that adds a `performAction` case                                                     |
| `STATUS.md`            | <150  | Every session, first                                                                                            |

## Tasks (`tasks/`)

Sizes: S ≈ under 150 lines of change, M ≈ 150–500, L ≈ 500+.

| Task                                         | Size | Needs        | One-line goal                                                     |
| -------------------------------------------- | ---- | ------------ | ----------------------------------------------------------------- |
| P0-01 toolchain-and-smoke-build              | S    | –            | Zig 0.16 + MSVC installed; `zig build -Demit-lib-vt` works        |
| P0-02 win32-runtime-skeleton                 | M    | P0-01        | `win32` runtime enum, stub module, `posix_c` gating, link libs    |
| P0-03 renderer-wgl-provider                  | L    | P0-02        | WGL context + direct present; `ghostty.exe` links                 |
| P0-04 cli-actions-and-console                | S    | P0-03        | `+version`, `+list-fonts` print from a terminal                   |
| P0-05 unit-tests-build-on-windows            | S–M  | P0-03        | `zig build test` builds; key tests pass; failures listed          |
| P1-01 window-and-message-loop                | L    | P0-03, P0-04 | Window opens, surface starts, clean exit                          |
| P1-02 first-pixels-resize-dpi                | M    | P1-01        | Prompt visible, resize, DPI, vsync toggle                         |
| P1-03 conpty-shutdown-and-eof-fixes          | M    | P0-05        | Reader EOF, shutdown order, no leaks                              |
| P1-04 keyboard-basic                         | M    | P1-02        | Typing, Ctrl+C, arrows, F-keys                                    |
| P1-05 focus-mouse-cursor-basics              | M    | P1-02        | Focus, occlusion, mouse, cursor shapes                            |
| P2-01 keyboard-full                          | M    | P1-04        | Layouts, AltGr, dead keys, kitty protocol                         |
| P2-02 mouse-full                             | S    | P1-05        | Click timing, precision scroll, capture                           |
| P2-03 clipboard                              | M    | P1-04        | Copy/paste, unsafe-paste confirm, OSC 52                          |
| P2-04 ime                                    | M    | P2-01        | CJK IME composition and commit                                    |
| P2-05 window-chrome-and-system-integration   | M    | P1-05        | Dark title bar, theme, icon, bell, URLs, fullscreen, reload       |
| P2-06 config-paths-and-defaults              | M    | P0-04        | `%APPDATA%`, `~`, pwsh default, TERM, LANG, hostname, edit-config |
| P2-07 powershell-shell-integration           | M    | P2-06        | OSC 133/7 for pwsh; cmd PROMPT marks                              |
| P3-01 multiple-windows                       | M    | P1-05, P2-03 | New window, goto_window, quit semantics                           |
| P3-02 tabs                                   | L    | P3-01        | Custom tab bar, tab actions                                       |
| P3-03 splits                                 | L    | P3-02        | Split tree layout, dividers, split actions                        |
| P3-04 dialogs-and-confirmations              | S–M  | P3-02        | TaskDialog confirmations, config errors, prompt_title             |
| P4-01 font-discovery-improvements            | M    | P0-05        | Index, style scoring, fallback order                              |
| P4-02 directwrite-fallback-optional          | L    | P4-01        | DirectWrite discovery (optional)                                  |
| P4-03 conpty-advanced                        | M    | P1-03        | Job objects, inherit cursor, process info, OSC 7                  |
| P4-04 presentation-upgrade-vsync-dxgi        | M/L  | P1-02, P3-03 | Vsync policy, resize polish, optional DXGI                        |
| P4-05 ipc-and-single-instance                | S–M  | P3-02        | `+new-window`/`+new-tab` via WM_COPYDATA                          |
| P4-06 taskbar-progress-and-notifications     | S–M  | P2-05        | ITaskbarList3, notifications, misc actions                        |
| P5-01 manifest-version-info-and-exe-metadata | S    | P2-05        | UTF-8/long-path manifest, VERSIONINFO                             |
| P5-02 release-build-and-distribution         | M    | P5-01, P3-04 | Zip layout, installer, context menu                               |
| P5-03 ci-windows-job                         | S    | P0-05        | GitHub Actions job for the app                                    |
| P5-04 crash-reporting-decision               | S/M  | P5-01        | Minidump handler (or Sentry)                                      |
| P5-05 docs-and-known-issues                  | S    | P5-02        | README, HACKING, Windows notes                                    |

## Task file layout

Every task file has the same sections so a session can skim:
Goal · Why · Read before starting (with line ranges and a line budget) ·
Design (when non-trivial) · Steps · Acceptance · Gotchas · Out of scope ·
Wrap-up. P4/P5 files are deliberately terser; refine them when reached
if the earlier phases changed the picture.

## Research provenance

The inventory in `04-current-state.md` and the line references in task
files come from five code surveys run on 2026-09-22 (termio/process,
apprt contract, renderer/fonts, OS/config/CLI, build/CI). Nothing was
compiled during the survey because no Zig toolchain was installed; treat
"will not compile" claims as strong expectations, not proofs, and record
the truth in STATUS.md when you hit it.
