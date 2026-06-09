#!/usr/bin/env bash
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"   # plugin root (or ~/.claude when installed)
# UserPromptSubmit hook: shift the last result into "prev:" and mark the prompt
# now executing in "now:". NO model call — pure text, free and immediate.
# Writes:  goal / prev (last turn's summary) / now (⏳ current prompt).
# The Stop hook later replaces "now:" with this turn's Haiku summary.

# Recursion guard: the Stop worker's inner `claude -p` also fires this hook.
[ -n "$CLAUDE_TASK_SUMMARY" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0   # no jq: can't parse the transcript (the SessionStart hook tells the user)

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
prompt=$(printf '%s' "$input" | jq -r '.prompt // empty')
tpath=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[ -z "$sid" ] && exit 0
umask 077   # state files can summarize sensitive session content -> keep them private

# Record which session is live in this pane / working dir, so on-demand tools
# (the /brief command) can resolve the current session id from where they run.
# Primary key: the terminal's stable per-pane id, via the pluggable driver layer
# (iTerm2/tmux/kitty/Apple-Terminal) — correct even for two tabs in the same dir.
# Fallback key: cwd. Both this hook and a command's bash inherit the terminal env
# from the pane's shell, so they compute the same key. Done before the synthetic-
# prompt filter below so the map stays fresh even on /brief itself.
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
. "$ROOT/bin/lib/terminal-driver.sh"
pane=$(tdrv_self_pane); pane=$(printf '%s' "$pane" | tr -dc '0-9A-Za-z%:_-')   # fs-safe key
if [ -n "$pane" ]; then
  pane_dir="$HOME/.claude/state/panes"; mkdir -p "$pane_dir"
  printf '%s\n' "$sid" > "$pane_dir/$pane"
fi
if [ -n "$cwd" ]; then
  cwd_dir="$HOME/.claude/state/cwds"; mkdir -p "$cwd_dir"
  printf '%s\n' "$sid" > "$cwd_dir/$(printf '%s' "$cwd" | tr '/ ' '__')"
fi

# Ignore synthetic/system-injected "prompts" — background task-completion
# notifications, slash-command + bash-mode expansions, system reminders. These
# fire UserPromptSubmit but aren't user commands, so leave the state untouched.
case "$prompt" in
  '<task-notification'*|'<command-name>'*|'<command-message>'*|'<command-args>'*|'<local-command-'*|'<bash-input>'*|'<system-reminder>'*)
    exit 0 ;;
esac

state_dir="$HOME/.claude/state"
mkdir -p "$state_dir"
out="$state_dir/$sid.task"

# Preserve goal; shift the previous "now:" (last turn's summary) into "prev:".
goal_line=""; prevtext=""
if [ -f "$out" ]; then
  goal_line=$(grep -m1 '^▸ goal:' "$out")
  prevtext=$(grep -m1 '^▸ now:' "$out" | sed 's/^▸ now:[[:space:]]*//')
  prevtext=${prevtext#"⏳ "}   # drop the live marker if the turn was interrupted
fi
if [ -z "$goal_line" ] && [ -n "$tpath" ] && [ -f "$tpath" ]; then
  t=$(jq -rs 'map(select(.type=="ai-title").aiTitle) | last // empty' "$tpath" 2>/dev/null)
  [ -n "$t" ] && goal_line="▸ goal: $t"
fi

# Collapse the prompt to one short line, with an ellipsis if truncated.
full=$(printf '%s' "$prompt" | tr '\n\t' '  ' | sed 's/  */ /g; s/^ *//; s/ *$//')
nowtext=${full:0:64}
[ "${#full}" -gt 64 ] && nowtext="${nowtext}..."

{
  [ -n "$goal_line" ] && printf '%s\n' "$goal_line"
  [ -n "$prevtext" ]  && printf '▸ prev: %s\n' "$prevtext"
  printf '▸ now:  ⏳ %s\n' "$nowtext"
} > "$out.tmp" && mv "$out.tmp" "$out"
exit 0
