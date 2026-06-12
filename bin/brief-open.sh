#!/usr/bin/env bash
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"   # plugin root (or ~/.claude when installed)
# Open — or re-focus + reload — the docked pane showing this session's live brief.
# Singleton: re-running closes the old dock and creates a fresh one running the
# latest viewer. Terminal-agnostic via the pluggable driver layer
# (bin/lib/terminal-driver.sh): iTerm2 / tmux / kitty / Apple Terminal, plus a
# generic fallback. Run from /brief's bash (inherits the terminal's pane env).
#   usage: brief-open.sh [float|refresh|close|help]
#     (default) dock : side-by-side split in the current window (a companion
#                      window on Apple Terminal, which has no scriptable splits)
#     float          : a separate window instead
#     refresh        : regenerate the brief now (detached), then open the dock
#     close          : tear down this session's dock (no reopen)
#     help           : print usage + the in-dock keys + docs pointers; no dock action
arg="${1:-}"; refresh=0
case "$arg" in
  refresh) refresh=1; mode="dock" ;;
  float)   mode="float" ;;
  close)   mode="close" ;;
  help)    mode="help" ;;
  *)       mode="dock" ;;
esac

# The slash command's name depends on the install path: bare /brief on a manual
# ~/.claude install, the namespaced /claude-brief:brief as a plugin (where ROOT is
# the plugin cache dir, not ~/.claude). Tab completes the prefix either way.
cmd="/claude-brief:brief"
[ "$ROOT" = "$HOME/.claude" ] && cmd="/brief"

# help: needs no session, driver, or dock — print and stop.
if [ "$mode" = help ]; then
  cat <<EOF
claude-brief — a live, auto-refreshing summary brief docked beside this session

usage: $cmd [float|refresh|close|help]
       (type /brief and press Tab — autocomplete fills in the rest)
  (none)   open or re-focus the dock — a side-by-side split showing this
           session's brief (a companion window on Apple Terminal)
  float    open it as a separate window instead of a split
  refresh  regenerate the brief now, instead of waiting for the next turn
  close    tear the dock down — a clean, no-prompt close on every backend
  help     this text

in-dock keys (click the dock pane first):
  r        refresh the brief now
  a        toggle auto-refresh at the end of each turn (default: on)
  i        toggle periodic refresh during a long turn (fires only on new activity)
  + / -    adjust the refresh interval (30s-1h)
  ?        key help
  q        close the dock

The brief updates after each turn that does real work (a small cost-gated Haiku
call; trivial turns are skipped). Force a terminal backend with
BRIEF_TERMINAL=<iterm2|tmux|kitty|wezterm|ghostty|terminal|tabby|generic>.

Full docs (README): https://github.com/tigerquoll/claude-brief#readme
EOF
  [ -f "$ROOT/README.md" ] && echo "Installed copy:      $ROOT/README.md"
  exit 0
fi

state_dir="$HOME/.claude/state"
. "$ROOT/bin/lib/terminal-driver.sh"   # provides tdrv_name/self_pane/open/close

# --- Resolve the session id of the pane we were invoked in ----------------
sid=""; via=""
# 0) AUTHORITATIVE: the session id Claude Code exports into the command's shell
#    ($CLAUDE_CODE_SESSION_ID, set since CC 2.1.132). This is the session /brief was
#    actually invoked in — correct for a FRESH or just-/clear'd session that has no
#    brief or pane/cwd map yet, where the heuristics below would otherwise fall
#    through to "newest brief" and dock SOME OTHER session. Only the env var is
#    trusted here; everything else is a fallback for older Claude Code.
if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  case "$CLAUDE_CODE_SESSION_ID" in
    *[!0-9a-fA-F-]*) : ;;                                   # not UUID-shaped -> ignore
    *) sid="$CLAUDE_CODE_SESSION_ID"; via="env" ;;
  esac
fi
# 1) terminal pane id (per-pane: correct even with two tabs in the same dir). The
#    driver already returns a value safe to use; whitelist once more for the key.
#    ALWAYS computed — $pane is also the split anchor passed to tdrv_open below.
pane=$(tdrv_self_pane); pane=$(printf '%s' "$pane" | tr -dc '0-9A-Za-z%:_-')
if [ -z "$sid" ] && [ -n "$pane" ]; then
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
  [ -n "$tp" ] && nohup "$ROOT/hooks/task-summary-worker.sh" "$sid" "$tp" >/dev/null 2>&1 &
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
    # shellcheck disable=SC2034  # BRIEF_TERMINAL is read by the sourced terminal-driver.sh
    ( BRIEF_TERMINAL="$oldname"; . "$ROOT/bin/lib/terminal-driver.sh"; tdrv_close "$oldid" )
  fi
fi

# /brief close: the dock (if any) is now torn down — drop the session file and stop,
# no reopen. (The close above ran via whichever driver opened it.)
if [ "$mode" = close ]; then
  if [ -f "$sess_file" ]; then rm -f "$sess_file"; echo "brief: dock closed for ${sid:0:8}"
  else echo "brief: no dock open for ${sid:0:8}"; fi
  exit 0
fi

new_id=$(tdrv_open "$mode" "$pane" "$ROOT/bin/brief-view.sh" "$sid")

if [ -n "$new_id" ]; then
  printf '%s %s\n' "$(tdrv_name)" "$new_id" > "$sess_file"
  echo "brief: dock ready for ${sid:0:8} (via=$via, term=$(tdrv_name), mode=$mode)"
  # One-time first-run hint (sentinel-gated, like the glow note in session-start):
  # point at the dock's own help key and the fuller /brief help.
  hint_sentinel="$state_dir/.brief-help-hinted"
  if [ ! -f "$hint_sentinel" ]; then
    : > "$hint_sentinel"
    echo "brief: first dock — click the dock pane and press ? for its keys; $cmd help has the full rundown (README: https://github.com/tigerquoll/claude-brief#readme)"
  fi
elif [ "$(tdrv_name)" = generic ] || [ "$(tdrv_name)" = tabby ]; then
  # generic + tabby can't script a dock; the driver may have printed a terminal-
  # specific hint to stderr — print the exact viewer command to run by hand.
  echo "brief: no auto-dock for this terminal — open the viewer in a split/window you create:"
  echo "       $ROOT/bin/brief-view.sh $sid"
  exit 0
else
  echo "brief: couldn't open the dock (term=$(tdrv_name), sid=${sid:0:8}, via=$via, mode=$mode)"
  exit 1
fi
