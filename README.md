# claude-context — live session-brief dock for Claude Code + iTerm2

A per-session, auto-refreshing **brief** docked beside your Claude Code session in
iTerm2 — so you can tab between many concurrent sessions and instantly re-orient.

## Commands
- **`/brief`** — open/refocus a docked iTerm2 split showing this session's live
  brief (State · Tried · Gotchas · Decisions · Next). `/brief float` = separate
  window; `/brief refresh` = regenerate the brief now instead of next turn.

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
- A **`UserPromptSubmit`** hook maps pane/cwd → session id so `/brief` resolves
  which session it's in.
- The viewer renders the brief with `glow` + a perl post-processor (gutter, indent
  hierarchy, dimmed bullets) on the iTerm2 alt-screen, height-clipped (top-anchored).
- A **`SessionEnd`** hook closes the dock when a session ends; state self-prunes
  (>3 days idle) opportunistically from the Stop hook.

## Files (mirror of the live `~/.claude` layout)
```
claude/hooks/      task-prompt-hook.sh task-summary-hook.sh task-summary-worker.sh session-end-hook.sh
claude/bin/        brief-open.sh brief-view.sh brief-prune.sh brief-summarize.sh
claude/commands/   brief.md
claude/glow-brief.json
iterm2/DynamicProfiles/brief.json      (Default profile + 1.2x line spacing)
```

## Install / sync / restore
- `./install.sh` — runs a **dependency check** (see Requirements), then copies
  repo → `~/.claude` (+ the iTerm2 profile). Exits non-zero if a required dep is
  missing. Use to restore or set up a new machine.
- `./install.sh --check` — run only the dependency check; install nothing.
- `./sync.sh` — copy live `~/.claude` → repo. Run before committing local tweaks.
- **`~/.claude/settings.json` hook entries** (add by hand — settings.json is not
  committed, to avoid leaking config):
  ```
  UserPromptSubmit -> bash "$HOME/.claude/hooks/task-prompt-hook.sh"
  Stop             -> bash "$HOME/.claude/hooks/task-summary-hook.sh"
  SessionEnd       -> bash "$HOME/.claude/hooks/session-end-hook.sh"
  ```

## Requirements
macOS · iTerm2 3.6+ · bash ≥ 5 for the dock viewer (`brew install bash`; the
hooks alone are 3.2-safe) · `jq` · `perl` (built-in;
also the summarizer's 90s watchdog, so no coreutils needed) · the `claude` CLI ·
`osascript` (built-in). Optional: `glow` (`brew install glow`, recommended) or
`bat` for nicer rendering. `./install.sh --check` verifies all of these.

Design notes, iTerm2/terminal gotchas, and the summary cost model are recorded in
this project's Claude memory (`brief-dock-system`, `iterm2-36-scripting-gotchas`,
`terminal-headless-render-gotchas`, `brief-summary-cost`).
