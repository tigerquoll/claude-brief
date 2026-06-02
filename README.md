# claude-context — live session-brief dock for Claude Code + iTerm2

A per-session, auto-refreshing **brief** docked beside your Claude Code session in
iTerm2 — so you can tab between many concurrent sessions and instantly re-orient.

## Commands
- **`/brief`** — open/refocus a docked iTerm2 split showing this session's live
  brief (State · Tried · Gotchas · Decisions · Next). `/brief float` = separate
  window; `/brief refresh` = regenerate the brief now instead of next turn.

## How it works
- A **`Stop`** hook runs a cheap Haiku summary each completed turn (cost-gated:
  skips trivial turns) → `~/.claude/state/<sid>.brief.md` + `.task`.
- A **`UserPromptSubmit`** hook maps pane/cwd → session id so `/brief` resolves
  which session it's in.
- The viewer renders the brief with `glow` + a perl post-processor (gutter, indent
  hierarchy, dimmed bullets) on the iTerm2 alt-screen, height-clipped (top-anchored).
- A **`SessionEnd`** hook closes the dock when a session ends; state self-prunes
  (>3 days idle) opportunistically from the Stop hook.

## Files (mirror of the live `~/.claude` layout)
```
claude/hooks/      task-prompt-hook.sh task-summary-hook.sh task-summary-worker.sh session-end-hook.sh
claude/bin/        brief-open.sh brief-view.sh brief-prune.sh
claude/commands/   brief.md
claude/glow-brief.json
iterm2/DynamicProfiles/brief.json      (Default profile + 1.2x line spacing)
```

## Install / sync / restore
- `./install.sh` — copy repo → `~/.claude` (+ the iTerm2 profile). Use to restore
  or set up a new machine.
- `./sync.sh` — copy live `~/.claude` → repo. Run before committing local tweaks.
- **`~/.claude/settings.json` hook entries** (add by hand — settings.json is not
  committed, to avoid leaking config):
  ```
  UserPromptSubmit -> bash "$HOME/.claude/hooks/task-prompt-hook.sh"
  Stop             -> bash "$HOME/.claude/hooks/task-summary-hook.sh"
  SessionEnd       -> bash "$HOME/.claude/hooks/session-end-hook.sh"
  ```

## Requirements
macOS · iTerm2 3.6+ · bash 5 (`brew install bash`) · `glow` (`brew install glow`)
· `jq` · `perl` · the `claude` CLI.

Design notes, iTerm2/terminal gotchas, and the summary cost model are recorded in
this project's Claude memory (`brief-dock-system`, `iterm2-36-scripting-gotchas`,
`terminal-headless-render-gotchas`, `brief-summary-cost`).
