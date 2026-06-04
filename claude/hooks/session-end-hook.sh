#!/usr/bin/env bash
# SessionEnd hook: when a Claude session ends, close its brief dock pane (if one
# is open) and DELETE all of that session's brief state — the summary content
# (<sid>.brief.md / .task) and the ephemeral dock/accounting files — so nothing
# lingers on disk once the session is gone. The age-based prune (brief-prune.sh)
# is the backstop for sessions that exit without firing SessionEnd. Detached
# osascript so it never blocks.
[ -n "$CLAUDE_TASK_SUMMARY" ] && exit 0   # ignore the summarizer's inner claude

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
[ -z "$sid" ] && exit 0
case "$sid" in *[!0-9a-fA-F-]*) exit 0 ;; esac

st="$HOME/.claude/state"
known=$(cat "$st/$sid.brief.session" 2>/dev/null)
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

# Remove ALL of this session's brief state (content + ephemeral), not just the
# dock files. $sid is UUID-validated above, so the glob is safe.
rm -f "$st/$sid".* 2>/dev/null
rmdir "$st/$sid.brief.lock" 2>/dev/null    # a dir; rm -f won't take it
# Drop pane/cwd -> sid map entries that pointed at this (now-ended) session
# (a still-open session in the same cwd has already rewritten its entry to its own sid).
grep -lxF "$sid" "$st/panes/"* "$st/cwds/"* 2>/dev/null | while IFS= read -r f; do rm -f "$f"; done
exit 0
