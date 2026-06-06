# kitty driver. Drives kitty's remote control (`kitty @`) to open/close the dock.
#
# REQUIRED kitty.conf setup — /brief runs brief-open via Claude Code's Bash tool,
# which has NO controlling tty, so `kitty @` cannot use the terminal transport and
# MUST reach kitty over a unix socket:
#   allow_remote_control yes        # or `socket-only` (tighter: socket transport only)
#   listen_on unix:/tmp/kitty       # REQUIRED — without it /brief can't talk to kitty
#   enabled_layouts splits,stack    # so --location=vsplit gives a side-by-side dock
# Then RESTART kitty (listen_on is read only at startup). kitty exports $KITTY_LISTEN_ON
# to the processes it launches, so Claude Code (and thus brief-open) inherit it and
# this driver passes it back via `kitty @ --to`. allow_remote_control ALONE is not
# enough in the tty-less /brief context. Sourced by terminal-driver.sh — bash-3.2-safe.

tdrv_name(){ printf 'kitty'; }

tdrv_self_pane(){ printf '%s' "${KITTY_WINDOW_ID:-}"; }   # per-window integer id

# `kitty @`, routed over the socket when one is advertised ($KITTY_LISTEN_ON) — the
# only transport that works from /brief's tty-less context. Falls back to the bare
# command (tty transport) when unset, so a normal interactive shell still works.
_kitty_at(){
  if [ -n "${KITTY_LISTEN_ON:-}" ]; then kitty @ --to "$KITTY_LISTEN_ON" "$@"
  else kitty @ "$@"; fi
}

# tdrv_open MODE ANCHOR CMD…  -> echo the new window id (integer)
# --location=vsplit = side-by-side (needs the splits layout); --keep-focus = don't
# switch to it; no --hold, so the viewer's `q` / a clean exit closes the window like
# a tmux pane. A window opened by kitty inherits kitty's OWN launch env (minimal if
# kitty was started from the macOS GUI), so --env PATH="$PATH" hands it the caller's
# full interactive PATH — that's how the bash-5 viewer + glow + claude resolve. CMD
# is exec'd as argv (no shell), so it must be an absolute path.
tdrv_open(){
  _mode=$1; shift 2
  _err="${TMPDIR:-/tmp}/brief-kitty.$$"
  if [ "$_mode" = float ]; then
    _id=$(_kitty_at launch --type=os-window --cwd=current --keep-focus --env "PATH=$PATH" "$@" 2>"$_err")
  else
    _id=$(_kitty_at launch --type=window --location=vsplit --cwd=current --keep-focus --env "PATH=$PATH" "$@" 2>"$_err")
  fi
  if [ -z "$_id" ]; then
    {
      printf 'brief: kitty dock could not open. /brief has no controlling tty, so kitty\n'
      printf '       needs SOCKET remote control. Add to kitty.conf, then RESTART kitty:\n'
      printf '         allow_remote_control yes        (or: socket-only)\n'
      printf '         listen_on unix:/tmp/kitty\n'
      printf '         enabled_layouts splits,stack    (for a side-by-side dock)\n'
      _msg=$(tr '\n' ' ' <"$_err" 2>/dev/null)
      [ -n "$_msg" ] && printf '       [kitty said: %s]\n' "$_msg"
    } >&2
  fi
  rm -f "$_err" 2>/dev/null
  printf '%s' "$_id"
}

tdrv_close(){
  _id=$1; [ -n "$_id" ] || return 0
  case "$_id" in *[!0-9]*) return 0 ;; esac   # integer id only
  _kitty_at close-window --match "id:$_id" 2>/dev/null || true
}
