#!/usr/bin/env bash
# Open — or re-focus + reload — the docked pane showing this session's live brief.
# Singleton: re-running closes the old dock and creates a fresh one running the
# latest viewer. Terminal-agnostic via the pluggable driver layer
# (bin/lib/terminal-driver.sh): iTerm2 / tmux / kitty / Apple Terminal, plus a
# generic fallback. Run from /brief's bash (inherits the terminal's pane env).
#   usage: brief-open.sh [float|refresh|close]
#     (default) dock : side-by-side split in the current window (a companion
#                      window on Apple Terminal, which has no scriptable splits)
#     float          : a separate window instead
#     refresh        : regenerate the brief now (detached), then open the dock
#     close          : tear down this session's dock (no reopen)
arg="${1:-}"; refresh=0
case "$arg" in
  refresh) refresh=1; mode="dock" ;;
  float)   mode="float" ;;
  close)   mode="close" ;;
  *)       mode="dock" ;;
esac

state_dir="$HOME/.claude/state"
. "$HOME/.claude/bin/lib/terminal-driver.sh"   # provides tdrv_name/self_pane/open/close

# --- Resolve the session id of the pane we were invoked in ----------------
sid=""; via=""
# 1) terminal pane id (per-pane: correct even with two tabs in the same dir). The
#    driver already returns a value safe to use; whitelist once more for the key.
pane=$(tdrv_self_pane); pane=$(printf '%s' "$pane" | tr -dc '0-9A-Za-z%:_-')
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
# Defense-in-depth: sid is interpolated into the driver's launch command, so
# require a UUID-shaped value (hex + dashes only) and refuse anything else.
case "$sid" in *[!0-9a-fA-F-]*) echo "brief: refusing — session id is not UUID-shaped"; exit 1 ;; esac

# /brief refresh: regenerate the brief NOW (detached); the dock picks up the new
# brief.md via its mtime watch a few seconds later. Otherwise the brief refreshes
# only on the next completed turn.
if [ "$refresh" = 1 ]; then
  tp=$(ls -t "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)
  [ -n "$tp" ] && nohup "$HOME/.claude/hooks/task-summary-worker.sh" "$sid" "$tp" >/dev/null 2>&1 &
fi

sess_file="$state_dir/$sid.brief.session"   # "<driver> <dock-pane-id>"

# Reload model: CLOSE the previous dock first (via whichever driver opened it —
# possibly different from the current one), then open a fresh one. Two steps rather
# than one atomic script, but the close completes before the open begins.
if [ -f "$sess_file" ]; then
  old=$(cat "$sess_file")
  oldname=${old%% *}; oldid=${old#* }
  [ "$oldname" = "$oldid" ] && oldname=iterm2        # legacy single-token => iterm2
  case "$oldname" in *[!a-z0-9]*) oldname="" ;; esac  # only honour a clean driver name
  if [ -n "$oldname" ] && [ -n "$oldid" ]; then
    ( BRIEF_TERMINAL="$oldname"; . "$HOME/.claude/bin/lib/terminal-driver.sh"; tdrv_close "$oldid" )
  fi
fi

# /brief close: the dock (if any) is now torn down — drop the session file and stop,
# no reopen. (The close above ran via whichever driver opened it.)
if [ "$mode" = close ]; then
  if [ -f "$sess_file" ]; then rm -f "$sess_file"; echo "brief: dock closed for ${sid:0:8}"
  else echo "brief: no dock open for ${sid:0:8}"; fi
  exit 0
fi

new_id=$(tdrv_open "$mode" "$pane" "$HOME/.claude/bin/brief-view.sh" "$sid")

if [ -n "$new_id" ]; then
  printf '%s %s\n' "$(tdrv_name)" "$new_id" > "$sess_file"
  echo "brief: dock ready for ${sid:0:8} (via=$via, term=$(tdrv_name), mode=$mode)"
elif [ "$(tdrv_name)" = generic ]; then
  echo "brief: no dock driver for this terminal — open the viewer in a split/window you create:"
  echo "       $HOME/.claude/bin/brief-view.sh $sid"
  exit 0
else
  echo "brief: couldn't open the dock (term=$(tdrv_name), sid=${sid:0:8}, via=$via, mode=$mode)"
  exit 1
fi
