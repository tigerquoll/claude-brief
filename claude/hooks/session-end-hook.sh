#!/usr/bin/env bash
# SessionEnd hook: when a Claude session ends, close its brief dock pane (if one
# is open) and drop the dock-state files. Leaves <sid>.task/.brief.md for the
# /sessions overview + the age-based prune. Detached osascript so it never blocks.
[ -n "$CLAUDE_TASK_SUMMARY" ] && exit 0   # ignore the summarizer's inner claude

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
[ -z "$sid" ] && exit 0
case "$sid" in *[!0-9a-fA-F-]*) exit 0 ;; esac

st="$HOME/.claude/state"
known=$(cat "$st/$sid.induct.session" 2>/dev/null)
case "$known" in *[!0-9a-fA-F-]*) known="" ;; esac   # only act on a UUID-shaped id

if [ -n "$known" ]; then
  osascript >/dev/null 2>&1 <<OSA &
tell application "iTerm2"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (id of s) is "$known" then close s
      end repeat
    end repeat
  end repeat
end tell
OSA
fi

rm -f "$st/$sid.induct.session" "$st/$sid.induct.pid" "$st/$sid.induct.seen"
exit 0
