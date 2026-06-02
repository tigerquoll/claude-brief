#!/usr/bin/env bash
# Open — or re-focus + reload — the docked iTerm2 pane showing this session's
# live brief. Singleton: re-running focuses the existing dock AND relaunches the
# viewer with the latest script. Run from /brief's bash (inherits $ITERM_SESSION_ID).
#   usage: brief-open.sh [float|refresh]
#     (default) dock : vertical split (side-by-side) in the current iTerm2 window
#     float          : a separate iTerm2 window instead
#     refresh        : regenerate the brief now (detached), then open the dock
arg="${1:-}"; refresh=0
case "$arg" in
  refresh) refresh=1; mode="dock" ;;
  float)   mode="float" ;;
  *)       mode="dock" ;;
esac

state_dir="$HOME/.claude/state"

# --- Resolve the session id of the pane we were invoked in ----------------
sid=""; via=""
# 1) iTerm2 pane UUID (per-pane: correct even with two tabs in the same dir).
#    Whitelist the key to hex+dash so a hostile $ITERM_SESSION_ID can't traverse.
pane=$(printf '%s' "${ITERM_SESSION_ID#*:}" | tr -dc '0-9A-Fa-f-')
if [ -n "$pane" ]; then
  pf="$state_dir/panes/$pane"
  [ -f "$pf" ] && { sid=$(cat "$pf"); via="pane"; }
fi
# 2) working directory
if [ -z "$sid" ]; then
  cf="$state_dir/cwds/$(printf '%s' "$PWD" | tr '/ ' '__')"
  [ -f "$cf" ] && { sid=$(cat "$cf"); via="cwd"; }
fi
# 3) last resort: most recently updated brief (only reliable when single-session)
if [ -z "$sid" ]; then
  newest=$(ls -t "$state_dir"/*.brief.md 2>/dev/null | head -1)
  [ -n "$newest" ] && { sid=$(basename "$newest" .brief.md); via="newest"; }
fi

[ -z "$sid" ] && { echo "brief: couldn't determine the current session id (no pane/cwd map, no briefs yet)"; exit 1; }
# Defense-in-depth: sid is interpolated into AppleScript and a shell command, so
# require a UUID-shaped value (hex + dashes only) and refuse anything else.
case "$sid" in *[!0-9a-fA-F-]*) echo "brief: refusing — session id is not UUID-shaped"; exit 1 ;; esac

# /brief refresh: regenerate the brief NOW (detached); the dock picks up the new
# brief.md via its mtime watch a few seconds later. Otherwise the brief refreshes
# only on the next completed turn.
if [ "$refresh" = 1 ]; then
  tp=$(ls -t "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)
  [ -n "$tp" ] && nohup "$HOME/.claude/hooks/task-summary-worker.sh" "$sid" "$tp" >/dev/null 2>&1 &
fi

sess_file="$state_dir/$sid.brief.session"   # iTerm2 session id of this session's dock
cmd="$HOME/.claude/bin/brief-view.sh $sid"
known=""
[ -f "$sess_file" ] && known=$(cat "$sess_file")
case "$known" in *[!0-9a-fA-F-]*) known="" ;; esac   # ignore a tampered/garbled .session id

# Reload model: CLOSE the previous dock pane (if it still exists), then create a
# fresh split running the latest viewer. No typing into an existing shell -> no
# race (that's what stacked the relaunch commands before). Closing one split
# pane leaves the rest of the window intact, and AppleScript close bypasses the
# "process running?" prompt — both verified.
new_id=$(osascript 2>/dev/null <<OSA
tell application "iTerm2"
  activate
  set victim to missing value
  if "$known" is not "" then
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (id of s) is "$known" then set victim to s
        end repeat
      end repeat
    end repeat
  end if
  if victim is not missing value then
    try
      close victim
    end try
    delay 0.15
  end if
  -- create the fresh dock; create/split take no 'command' param in 3.6 and
  -- create returns 'missing value', so grab current session + write text.
  -- Anchor the split to the brief's OWN pane (the session whose id == \$pane, the
  -- pane that ran /brief) rather than whatever is frontmost — otherwise a delayed
  -- /brief docks beside the wrong tab if you've switched away in the meantime.
  set anchor to missing value
  if "$pane" is not "" then
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (id of s) is "$pane" then set anchor to s
        end repeat
      end repeat
    end repeat
  end if
  if "$mode" is "float" then
    create window with profile "brief"
    set newSess to (current session of current window)
  else if anchor is not missing value then
    tell anchor
      set newSess to (split vertically with profile "brief")
    end tell
  else
    tell current session of current window
      set newSess to (split vertically with profile "brief")
    end tell
  end if
  tell newSess to write text "$cmd"
  return (id of newSess)
end tell
OSA
)

if [ -n "$new_id" ]; then
  printf '%s\n' "$new_id" > "$sess_file"
  echo "brief: dock ready for ${sid:0:8} (via=$via, mode=$mode)"
else
  echo "brief: iTerm2 scripting returned nothing — is iTerm2 frontmost? (sid=${sid:0:8}, via=$via, mode=$mode)"
  exit 1
fi
