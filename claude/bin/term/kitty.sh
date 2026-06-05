# kitty driver. Uses kitty's remote control (`kitty @`). PREREQS the user must set
# in kitty.conf: `allow_remote_control yes` AND an `enabled_layouts` that includes
# `splits` with the tab on it — otherwise --location=vsplit is silently ignored and
# the window just opens normally. `kitty @` auto-finds the socket via the
# controlling tty when run inside a kitty window. Sourced — bash-3.2-safe.

tdrv_name(){ printf 'kitty'; }

tdrv_self_pane(){ printf '%s' "${KITTY_WINDOW_ID:-}"; }   # integer id

# tdrv_open MODE ANCHOR CMD…  -> echo the new window id (integer)
# --location=vsplit = side-by-side; --keep-focus = don't switch to it; --hold keeps
# the window at a prompt if the viewer exits. CMD is passed as exec'd argv (no shell).
tdrv_open(){
  _mode=$1; shift 2
  _err="${TMPDIR:-/tmp}/brief-kitty.$$"
  if [ "$_mode" = float ]; then
    _id=$(kitty @ launch --type=os-window --cwd=current --keep-focus --hold "$@" 2>"$_err")
  else
    _id=$(kitty @ launch --type=window --location=vsplit --cwd=current --keep-focus --hold "$@" 2>"$_err")
  fi
  if [ -z "$_id" ]; then
    case "$(cat "$_err" 2>/dev/null)" in
      *remote\ control*|*disabled*)
        printf 'brief: kitty remote control is off — add `allow_remote_control yes` to kitty.conf (and use the `splits` layout for a side-by-side dock).\n' >&2 ;;
    esac
  fi
  rm -f "$_err" 2>/dev/null
  printf '%s' "$_id"
}

tdrv_close(){
  _id=$1; [ -n "$_id" ] || return 0
  case "$_id" in *[!0-9]*) return 0 ;; esac   # integer id only
  kitty @ close-window --match "id:$_id" 2>/dev/null || true
}
