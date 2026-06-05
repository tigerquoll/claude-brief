# Apple Terminal (Terminal.app) driver. Terminal has NO scriptable split panes
# (its ⌘D "Split Pane" is a same-session view, and AppleScript exposes only
# windows→tabs), so the dock is a SEPARATE window positioned beside the frontmost
# one — the scriptable equivalent of manual macOS Split View tiling. `do script`
# opens a new window and returns its tab; `close … saving no` suppresses the
# "process still running?" prompt. First use triggers the one-time TCC Automation
# approval (osascript error -1743 until granted). Sourced — bash-3.2-safe.

tdrv_name(){ printf 'terminal'; }

# $TERM_SESSION_ID is `wXtYpZ:UUID`; the wXtYpZ prefix is positional/unstable, the
# UUID is the stable per-session token. Hex+dash only (used as the map key).
tdrv_self_pane(){ printf '%s' "${TERM_SESSION_ID#*:}" | tr -dc '0-9A-Fa-f-'; }

# tdrv_open MODE ANCHOR CMD…  -> echo the new window id (integer)
tdrv_open(){
  _mode=$1; shift 2; _cmd="$*"
  _pos=1; [ "$_mode" = float ] && _pos=0
  _err="${TMPDIR:-/tmp}/brief-term.$$"
  _id=$(osascript 2>"$_err" <<OSA
tell application "Terminal"
  activate
  set fb to {0, 0, 0, 0}
  try
    set fb to bounds of front window
  end try
  set newTab to do script "exec $_cmd"
  set theWin to (first window whose selected tab is newTab)
  if $_pos is 1 then
    set {l, tp, r, b} to fb
    try
      set bounds of theWin to {r, tp, r + (r - l), b}
    end try
  end if
  return id of theWin
end tell
OSA
)
  if [ -z "$_id" ]; then
    case "$(cat "$_err" 2>/dev/null)" in
      *-1743*|*[Nn]ot\ authorized*)
        printf 'brief: Terminal automation not authorized — approve it in System Settings ▸ Privacy & Security ▸ Automation, then retry /brief.\n' >&2 ;;
    esac
  fi
  rm -f "$_err" 2>/dev/null
  printf '%s' "$_id"
}

tdrv_close(){
  _id=$1; [ -n "$_id" ] || return 0
  case "$_id" in *[!0-9]*) return 0 ;; esac   # integer window id only
  osascript >/dev/null 2>&1 <<OSA
tell application "Terminal" to close (every window whose id is $_id) saving no
OSA
}
