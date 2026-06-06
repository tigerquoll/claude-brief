#!/usr/bin/env bash
# Stop hook: fires when the agent finishes a turn. Launches a detached worker
# that refreshes the status-line task summary, then returns instantly so it
# never adds latency. The worker derives everything it needs from the
# transcript, so this hook just forwards the session id + transcript path.

# Recursion guard: the worker's inner `claude -p` re-fires this hook on Stop.
[ -n "$CLAUDE_TASK_SUMMARY" ] && exit 0
. "$HOME/.claude/bin/lib/portable.sh"   # _mtime/_perm (portable BSD/GNU stat)

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
tpath=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[ -z "$sid" ] && exit 0
umask 077   # state files can summarize sensitive session content -> keep them private

# End-of-turn auto refresh can be turned off from the dock (its 'a' key writes
# this flag), so the brief then updates ONLY on demand. The dock's own r/interval
# refresh call the worker directly, bypassing this hook, so they keep working.
[ -f "$HOME/.claude/state/$sid.brief.noauto" ] && exit 0

# Opportunistic state prune, at most once/day, detached so it adds no latency.
prunestamp="$HOME/.claude/state/.prune-stamp"
if [ ! -f "$prunestamp" ] || [ "$(( $(date +%s) - $(_mtime "$prunestamp") ))" -gt 86400 ]; then
  mkdir -p "$HOME/.claude/state"; : > "$prunestamp"
  nohup "$HOME/.claude/bin/brief-prune.sh" >/dev/null 2>&1 &
fi

# --- Skip trivial turns (Haiku cost guard) ---------------------------------
# A summary costs ~2c and fires on every Stop. Decide cheaply from the transcript
# (no model call): only summarize when, SINCE the last summary, the agent used a
# tool OR produced > ~300 chars of text. The tlines marker advances only when we
# DO summarize, so a run of tiny turns accumulates and eventually refreshes.
# Falls OPEN (summarizes) if anything is unreadable. Tune the 300 below.
marker="$HOME/.claude/state/$sid.tlines"
if [ -f "$tpath" ]; then
  cur=$(wc -l < "$tpath" 2>/dev/null); cur=${cur:-0}
  last=$(cat "$marker" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  set -- $(tail -n "+$((last + 1))" "$tpath" 2>/dev/null | jq -rs '
    [ .[] | select(.message.role? == "assistant") | .message.content[]? ] as $b
    | "\([ $b[] | select(.type? == "tool_use") ] | length) \([ $b[] | select(.type? == "text") | (.text | length) ] | add // 0)"
  ' 2>/dev/null)
  tools=${1:-1}; textlen=${2:-9999}
  case "$tools$textlen" in ''|*[!0-9]*) tools=1; textlen=9999 ;; esac
  skipf="$HOME/.claude/state/$sid.skipped"
  if [ "$tools" -eq 0 ] && [ "$textlen" -lt 300 ]; then
    n=$(cat "$skipf" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s\n' "$((n + 1))" > "$skipf"   # count it so the dock can show "N skipped"
    exit 0                                   # trivial turn -> skip; marker accumulates
  fi
  printf '%s\n' "$cur" > "$marker"
  : > "$skipf"                               # summarizing now -> reset the "skipped since" count
fi

nohup "$HOME/.claude/hooks/task-summary-worker.sh" "$sid" "$tpath" \
  >/dev/null 2>&1 &
exit 0
