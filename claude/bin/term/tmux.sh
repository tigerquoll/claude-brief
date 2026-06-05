# tmux driver. Works on macOS + Linux, no AppleScript. The dock is a real split;
# closing the session kills the pane. Sourced by terminal-driver.sh — bash-3.2-safe.

tdrv_name(){ printf 'tmux'; }

# $TMUX_PANE is the current pane id (form %N) — fs-safe and usable as -t anchor.
tdrv_self_pane(){ printf '%s' "${TMUX_PANE:-}"; }

# tdrv_open MODE ANCHOR CMD…  -> echo the new pane id (%N)
# -h = side-by-side (split along a horizontal axis -> vertical divider), -d = keep
# focus, -P -F prints the id. The command is passed as MULTIPLE args, so tmux execs
# it directly (no /bin/sh, no quoting pitfalls); CMD must be an absolute path since
# this bypasses the login shell's PATH.
tdrv_open(){
  _mode=$1 _anchor=$2; shift 2
  if [ "$_mode" = float ]; then
    tmux new-window -d -P -F '#{pane_id}' "$@" 2>/dev/null
  elif [ -n "$_anchor" ]; then
    tmux split-window -h -d -P -F '#{pane_id}' -t "$_anchor" "$@" 2>/dev/null
  else
    tmux split-window -h -d -P -F '#{pane_id}' "$@" 2>/dev/null
  fi
}

tdrv_close(){
  _id=$1; [ -n "$_id" ] || return 0
  case "$_id" in *[!%0-9]*) return 0 ;; esac   # %N only
  tmux kill-pane -t "$_id" 2>/dev/null || true
}
