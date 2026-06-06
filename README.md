# claude-context — live session-brief dock for Claude Code

A per-session, auto-refreshing **brief** docked beside your Claude Code session —
so you can tab between many concurrent sessions and instantly re-orient. The
docking terminal is **pluggable**: iTerm2, tmux, kitty, WezTerm, ghostty, or Apple
Terminal are auto-detected, with a generic fallback for anything else.

## Commands
- **`/brief`** — open/refocus a docked split showing this session's live brief
  (State · Tried · Gotchas · Decisions · Next). `/brief float` = separate window;
  `/brief refresh` = regenerate the brief now instead of next turn;
  `/brief close` = tear the dock down (clean, no-prompt close on every backend).

## How it works
- A **`Stop`** hook runs a cheap Haiku summary each completed turn (cost-gated:
  skips trivial turns) → `~/.claude/state/<sid>.brief.md` + `.task`. The model
  call is **pluggable** — `task-summary-worker.sh` delegates to
  `bin/brief-summarize.sh` (default Haiku `claude -p`); point `$BRIEF_SUMMARIZER`
  at your own script **under `~/.claude/`** (e.g. `~/.claude/bin/`) to use another
  model. It's executed, so it's only honoured from that trusted dir and must be a
  user-owned, non-world-writable executable (contract documented in that file). A
  ready-made alternative, **`bin/brief-summarize-api.sh`**, calls the gateway's
  Anthropic API directly (`<base>/v1/messages`, Bearer token) — skips the CLI's
  ~30k-token prefix, ~5× cheaper. Opt in: `export
  BRIEF_SUMMARIZER=~/.claude/bin/brief-summarize-api.sh`. Configure it
  **independently of the main session** via `BRIEF_API_BASE` / `BRIEF_API_TOKEN`
  / `BRIEF_API_MODEL` (these override the shared `ANTHROPIC_*`); or put them in
  `~/.claude/brief-summarizer.env` (`chmod 600`, sourced if owned + not
  world/group-writable) to keep the token out of settings.json and out of the
  main Claude session's environment.
- **What each summary call sends as context:** a display-size directive, the
  conversation title, the previous brief, your latest prompt, and the recent
  conversation — the last ~14 user/assistant message **text** blocks, truncated
  to a few KB. Tool calls and their outputs are **stripped**, so raw file
  contents / command output are not sent (though the assistant's prose may quote
  paths, code, or errors). It goes wherever `$BRIEF_SUMMARIZER` targets (default:
  the same gateway Claude Code already uses).
- A **`UserPromptSubmit`** hook maps pane/cwd → session id so `/brief` resolves
  which session it's in.
- **Pluggable terminal backend.** The windowing (split the pane, run the viewer,
  close on exit) lives behind a tiny **driver** contract — `bin/lib/terminal-driver.sh`
  sources one of `bin/term/{iterm2,tmux,kitty,wezterm,ghostty,terminal,tabby,generic}.sh`. The
  backend is auto-detected (inner multiplexer wins: tmux beats the host terminal); force one
  with `BRIEF_TERMINAL=<name>` (a name, never a path). **Porting / custom terminals:**
  the core is OS-portable (file times/perms go through `bin/lib/portable.sh`, which
  handles BSD *and* GNU `stat`), and a new driver auto-detects with **no edit to the
  core** — drop a `term/<name>.sh` implementing the four `tdrv_*` functions plus an
  optional `tdrv_detect()` (return 0 when it recognises the terminal; an optional
  `tdrv_priority()` 0–99 breaks ties). Notes: **WezTerm** is the easy
  case — `wezterm cli` reaches the always-on multiplexer over a unix socket
  (`$WEZTERM_UNIX_SOCKET`, exported into every pane), so a real in-window split works
  with **no config and no tty** (the dock split refocuses the session pane so your
  keystrokes don't land in it) — but, like tmux/kitty/ghostty, WezTerm has no
  per-pane profile, so the dock can't be styled apart from the session (see Dock
  styling below); **ghostty** docks via its AppleScript dictionary (a
  real in-window split, like iTerm2) and needs a one-time macOS Automation approval on
  first `/brief`; **Apple Terminal** has no scriptable split panes, so its dock is a
  companion window positioned beside the main one;
  **kitty** needs SOCKET remote control — `allow_remote_control yes` **and**
  `listen_on unix:/tmp/kitty` in kitty.conf, then a restart — because /brief runs
  with no controlling tty, so a tty-only setup can't be reached (add the `splits`
  layout for a side-by-side dock); **Tabby** is *recognized but can't be auto-docked*
  — it has no scriptable split, its CLI only opens new tabs (no id, no close), and it
  ships no AppleScript, so the driver prints Tabby-specific instructions to split by
  hand and run the viewer; unknown
  terminals fall back to **generic**, which just prints the `brief-view.sh <sid>`
  command for you to run in a split you make yourself.
- **Dock styling (`brief` profile = your profile + 1.2× line spacing).** iTerm2
  ships `iterm2/DynamicProfiles/brief.json` (auto-loaded; inherits your Default
  profile *live*). Apple Terminal generates one at install via
  `bin/brief-term-profile.sh` — from the profile you install *from* — and imports
  it once (Terminal can't inherit or auto-load, so it's a snapshot; re-run the
  helper to refresh). tmux/kitty/WezTerm/ghostty get no dedicated `brief` profile.
  **This is the tmux driver's main disadvantage:** tmux has no per-pane font
  control — every pane shares the host terminal's one font — so the dock can't have
  a different font size or line spacing from your session; you get whatever the host
  terminal uses. Only iTerm2 and Apple Terminal can give the dock its **own**
  profile; every other backend can at most widen line spacing **globally** (which
  also affects your session pane). What each backend can scope to just the dock:

  | Backend | Dock-scoped line spacing *(the `brief` profile's whole point)* | Other per-pane styling it can do | Global ~1.2× spacing lever |
  |---|---|---|---|
  | **iTerm2** | ✅ DynamicProfile (live-inherits Default) | full `brief` profile | — (built in) |
  | **Apple Terminal** | ✅ imported `.terminal` snapshot | full `brief` profile | — (built in) |
  | **ghostty** | ❌ no line-height key/action | per-surface font **size** only | `adjust-cell-height = 20%` |
  | **kitty** | ❌ font metrics are global | per-window **colors** (`kitty @ set-colors`) | `modify_font cell_height 120%` |
  | **WezTerm** | ❌ one global config | none via the CLI | `config.line_height = 1.2` |
  | **tmux** | ❌ shares the host terminal's font | none — can't change the font at all | (host terminal's font) |

  So **kitty, WezTerm, ghostty, and tmux all hit the same wall**: no dock-scoped
  `brief` spacing — the global lever (last column) is the only workaround, and it
  widens your session pane too. ghostty can at least vary per-surface font *size*
  and kitty can recolor a window, but neither (nor WezTerm/tmux) can give the dock
  the 1.2× line spacing. `$BRIEF_PROFILE` overrides the profile name (iTerm2/Apple
  Terminal); `$BRIEF_FONT_BUMP=N` (Apple Terminal) also enlarges the font.
  - **Unfocused-pane dimming** is a global app setting, not a dock profile, so you
    set it once yourself: on **iTerm2** uncheck Settings ▸ Appearance ▸ Dimming ▸
    *Dim inactive split panes* (otherwise the dock fades while you're typing in the
    session pane); on **ghostty** add `unfocused-split-opacity = 1` to
    `~/.config/ghostty/config` (plus `adjust-cell-height = 20%` for ~1.2× spacing);
    on **kitty** add `modify_font cell_height 120%` to `~/.config/kitty/kitty.conf`
    for ~1.2× spacing (the modern directive — replaces the old `adjust_line_height`;
    reload with ctrl+shift+f5); on **WezTerm** set `config.line_height = 1.2` in
    `~/.wezterm.lua` for ~1.2× spacing. These are global — none of these terminals
    can scope them to just the dock.
- The viewer renders the brief with `glow` + a perl post-processor (gutter, indent
  hierarchy, dimmed bullets) on the terminal alt-screen, height-clipped (top-anchored).
- A **`SessionEnd`** hook closes the dock when a session ends **and deletes that
  session's brief state** (summary `<sid>.brief.md`/`.task`, the ephemeral dock
  files, and its pane/cwd map entries) — so nothing lingers on disk. The age-based
  prune (>3 days idle, opportunistic from the Stop hook) is the backstop for
  sessions that exit without firing SessionEnd.

## Files (mirror of the live `~/.claude` layout)
```
claude/hooks/      task-prompt-hook.sh task-summary-hook.sh task-summary-worker.sh session-end-hook.sh
claude/bin/        brief-open.sh brief-view.sh brief-prune.sh brief-summarize.sh brief-summarize-api.sh brief-term-profile.sh
claude/bin/lib/    terminal-driver.sh                     (sourced: detect + dispatch)
claude/bin/term/   iterm2.sh tmux.sh kitty.sh wezterm.sh ghostty.sh terminal.sh tabby.sh generic.sh   (terminal drivers)
claude/commands/   brief.md
claude/glow-brief.json
iterm2/DynamicProfiles/brief.json      (iterm2 dock profile: Default + 1.2x line spacing)
```

## Install / sync / restore
- `./install.sh` — runs a **dependency check** (see Requirements), then copies
  repo → `~/.claude` (+ the iTerm2 profile). Exits non-zero if a required dep is
  missing. Use to restore or set up a new machine.
- `./install.sh --check` — run only the dependency check; install nothing.
- `./sync.sh` — copy live `~/.claude` → repo. Run before committing local tweaks.
- `./test.sh` — regression tests (run after install/sync). Drives the live
  `~/.claude` scripts with throwaway sessions + fake summarisers (no real model
  calls); exit status = number of failures.
- **`~/.claude/settings.json` hook entries** (add by hand — settings.json is not
  committed, to avoid leaking config):
  ```
  UserPromptSubmit -> bash "$HOME/.claude/hooks/task-prompt-hook.sh"
  Stop             -> bash "$HOME/.claude/hooks/task-summary-hook.sh"
  SessionEnd       -> bash "$HOME/.claude/hooks/session-end-hook.sh"
  ```

## Requirements
bash ≥ 5 for the dock viewer (`brew install bash`; the hooks + drivers alone are
3.2-safe) · `jq` · `perl` (built-in; also the summarizer's 90s watchdog, so no
coreutils needed) · the `claude` CLI. Plus **one terminal backend**:
- **iTerm2** 3.6+ (macOS) — uses `osascript` (built-in)
- **ghostty** (macOS) — `osascript` via Ghostty's AppleScript dictionary; real
  in-window split; first run needs a one-time Automation approval
- **Apple Terminal** (macOS) — `osascript`; companion window, no splits; first run
  needs a one-time Automation approval
- **tmux** (macOS/Linux) — real split via `split-window`, inside any host terminal
  (incl. Apple Terminal). Wins auto-detection when `$TMUX` is set. Main tradeoff:
  no dock-specific font — tmux has no per-pane font control, so the dock can't have
  a different font size / line spacing from the session (it just uses the host
  terminal's font). Covered by a real headless end-to-end check in `test.sh`.
- **kitty** (macOS/Linux) — needs socket remote control in kitty.conf + a restart:
  `allow_remote_control yes`, `listen_on unix:/tmp/kitty` (required — /brief has no
  controlling tty), and `enabled_layouts splits,stack` for a side-by-side dock
- **WezTerm** (macOS/Linux) — real split via `wezterm cli split-pane`, **no config
  needed** (the mux is always on and reachable over `$WEZTERM_UNIX_SOCKET` without a
  tty). The dock split refocuses your session pane. Covered by a hermetic wiring test
  plus a live GUI end-to-end check in `test.sh`.
- **Tabby** (macOS/Linux/Windows) — *manual dock only.* Tabby exposes no scriptable
  split, no targetable/closable CLI (its CLI opens tabs with no id), and no
  AppleScript — so `/brief` can't auto-dock; it prints the split-it-yourself
  instructions and the `brief-view.sh <sid>` command to run. A true dock would need
  a Tabby plugin. Detected via `$TERM_PROGRAM=Tabby`.

Optional: `glow` (`brew install glow`, recommended) or `bat` for nicer rendering.
`./install.sh --check` reports which backends are available and the one
auto-detected in the current terminal.

Design notes, iTerm2/terminal gotchas, and the summary cost model are recorded in
this project's Claude memory (`brief-dock-system`, `iterm2-36-scripting-gotchas`,
`terminal-headless-render-gotchas`, `brief-summary-cost`).
