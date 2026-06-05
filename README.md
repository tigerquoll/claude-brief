# claude-context — live session-brief dock for Claude Code

A per-session, auto-refreshing **brief** docked beside your Claude Code session —
so you can tab between many concurrent sessions and instantly re-orient. The
docking terminal is **pluggable**: iTerm2, tmux, kitty, ghostty, or Apple Terminal
are auto-detected, with a generic fallback for anything else.

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
  sources one of `bin/term/{iterm2,tmux,kitty,ghostty,terminal,generic}.sh`. The backend
  is auto-detected (inner multiplexer wins: tmux beats the host terminal); force one
  with `BRIEF_TERMINAL=<name>` (a name, never a path). Notes: **ghostty** docks via its
  AppleScript dictionary (a real in-window split, like iTerm2) and needs a one-time
  macOS Automation approval on first `/brief`; **Apple Terminal** has no scriptable
  split panes, so its dock is a companion window positioned beside the main one;
  **kitty** needs `allow_remote_control yes` plus the `splits` layout; unknown
  terminals fall back to **generic**, which just prints the `brief-view.sh <sid>`
  command for you to run in a split you make yourself.
- **Dock styling (`brief` profile = your profile + 1.2× line spacing).** iTerm2
  ships `iterm2/DynamicProfiles/brief.json` (auto-loaded; inherits your Default
  profile *live*). Apple Terminal generates one at install via
  `bin/brief-term-profile.sh` — from the profile you install *from* — and imports
  it once (Terminal can't inherit or auto-load, so it's a snapshot; re-run the
  helper to refresh). tmux/kitty/ghostty just inherit their own theme (ghostty's
  scripting exposes font size but no line-spacing, so it can't get a 1.2× `brief`
  profile). `$BRIEF_PROFILE` overrides the name (iTerm2/Apple Terminal);
  `$BRIEF_FONT_BUMP=N` (Apple Terminal) also enlarges the font.
  - **Unfocused-pane dimming** is a global app setting, not a dock profile, so you
    set it once yourself: on **iTerm2** uncheck Settings ▸ Appearance ▸ Dimming ▸
    *Dim inactive split panes* (otherwise the dock fades while you're typing in the
    session pane); on **ghostty** add `unfocused-split-opacity = 1` to
    `~/.config/ghostty/config` (plus `adjust-cell-height = 20%` for ~1.2× spacing).
    These are global — neither terminal can scope them to just the dock.
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
claude/bin/term/   iterm2.sh tmux.sh kitty.sh ghostty.sh terminal.sh generic.sh   (terminal drivers)
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
- **tmux** (macOS/Linux)
- **kitty** (macOS/Linux) — set `allow_remote_control yes` + the `splits` layout

Optional: `glow` (`brew install glow`, recommended) or `bat` for nicer rendering.
`./install.sh --check` reports which backends are available and the one
auto-detected in the current terminal.

Design notes, iTerm2/terminal gotchas, and the summary cost model are recorded in
this project's Claude memory (`brief-dock-system`, `iterm2-36-scripting-gotchas`,
`terminal-headless-render-gotchas`, `brief-summary-cost`).
