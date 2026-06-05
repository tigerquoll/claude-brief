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
# Close the dock via whichever driver opened it. <sid>.brief.session = "<driver>
# <pane-id>" (legacy single-token => iterm2). Force that driver, then tdrv_close
# (which validates the id for its own format). Detached so it never blocks.
sess=$(cat "$st/$sid.brief.session" 2>/dev/null)
dname=${sess%% *}; did=${sess#* }
[ "$dname" = "$did" ] && dname=iterm2                 # legacy single-token => iterm2
case "$dname" in *[!a-z0-9]*) dname="" ;; esac        # only honour a clean driver name
if [ -n "$dname" ] && [ -n "$did" ]; then
  ( BRIEF_TERMINAL="$dname"; . "$HOME/.claude/bin/lib/terminal-driver.sh"; tdrv_close "$did" ) &
fi

# Remove ALL of this session's brief state (content + ephemeral), not just the
# dock files. $sid is UUID-validated above, so the glob is safe.
rm -f "$st/$sid".* 2>/dev/null
rmdir "$st/$sid.brief.lock" 2>/dev/null    # a dir; rm -f won't take it
# Drop pane/cwd -> sid map entries that pointed at this (now-ended) session
# (a still-open session in the same cwd has already rewritten its entry to its own sid).
grep -lxF "$sid" "$st/panes/"* "$st/cwds/"* 2>/dev/null | while IFS= read -r f; do rm -f "$f"; done

# Apple Terminal only: if WE auto-created the dock settings set (the terminal driver
# leaves a marker holding its name) and NO other Apple Terminal docks remain — ref-
# counted via the surviving "<driver> ..." session files — delete the profile too.
# This session's own .brief.session was just removed above, so it's excluded.
if [ -f "$st/brief.profile.auto" ]; then
  others=0
  for sf in "$st"/*.brief.session; do
    [ -f "$sf" ] || continue
    case "$(cat "$sf" 2>/dev/null)" in terminal\ *) others=1 ;; esac
  done
  if [ "$others" = 0 ]; then
    pn=$(cat "$st/brief.profile.auto" 2>/dev/null)
    case "$pn" in ''|*[!A-Za-z0-9_-]*) pn="" ;; esac
    [ -n "$pn" ] && osascript -e "tell application \"Terminal\" to delete settings set \"$pn\"" >/dev/null 2>&1
    rm -f "$st/brief.profile.auto"
  fi
fi
exit 0
