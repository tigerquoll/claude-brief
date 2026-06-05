# Apple Terminal (Terminal.app) driver. Terminal has NO scriptable split panes
# (its ⌘D "Split Pane" is a same-session view, and AppleScript exposes only
# windows→tabs), so the dock is a SEPARATE window positioned beside the frontmost
# one — the scriptable equivalent of manual macOS Split View tiling. `do script`
# opens a new window and returns its tab. First use triggers the one-time TCC
# Automation approval (osascript error -1743 until granted). Sourced — bash-3.2-safe.
#
# CLOSING is the hard part, and two Terminal quirks shape this driver:
#  1. AppleScript silently refuses to close a window with a running process (the
#     dock runs brief-view.sh), and `saving no` only covers the *save* dialog.
#     Assigning a "never prompt" profile doesn't help — close behaviour is bound at
#     window-creation, which `do script` can't influence. Only an IDLE window
#     closes cleanly. So tdrv_close KILLS the window's processes first, then closes.
#  2. `first window whose id is N` is unreliable (intermittent "Invalid index"),
#     which breaks looking up the window's tty at close time. So we CAPTURE the tty
#     at open (from the fresh tab) and encode it in the id token ("<winid>:<tty>"),
#     and we close by ITERATING windows rather than by `whose id`.

tdrv_name(){ printf 'terminal'; }

# $TERM_SESSION_ID is `wXtYpZ:UUID` (or a bare UUID on some builds); the wXtYpZ
# prefix is positional/unstable, the UUID is the stable token. Hex+dash only.
tdrv_self_pane(){ printf '%s' "${TERM_SESSION_ID#*:}" | tr -dc '0-9A-Fa-f-'; }

# tdrv_open MODE ANCHOR CMD…  -> echo "<winid>:<tty>" (tty captured for a reliable close)
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
  set theTty to ""
  try
    set theTty to tty of newTab
  end try
  set theWin to (first window whose selected tab is newTab)
  if $_pos is 1 then
    set {l, tp, r, b} to fb
    try
      set bounds of theWin to {r, tp, r + (r - l), b}
    end try
  end if
  return ((id of theWin) as string) & ":" & theTty
end tell
OSA
)
  if [ -z "$_id" ] || [ "$_id" = ":" ]; then
    case "$(cat "$_err" 2>/dev/null)" in
      *-1743*|*[Nn]ot\ authorized*)
        printf 'brief: Terminal automation not authorized — approve it in System Settings ▸ Privacy & Security ▸ Automation, then retry /brief.\n' >&2 ;;
    esac
    rm -f "$_err" 2>/dev/null; return 0
  fi
  rm -f "$_err" 2>/dev/null
  printf '%s' "$_id"
}

# tdrv_close "<winid>:<tty>"  — kill the dock's processes, WAIT until the window is
# genuinely idle (process dead AND Terminal's `busy` cleared — closing before that
# pops the terminate prompt), then close by iterating windows. Both the wait and the
# close avoid the flaky `whose id is` lookup (ps for the process, iteration for busy).
tdrv_close(){
  _id=$1; [ -n "$_id" ] || return 0
  _win=${_id%%:*}; _tty=${_id#*:}
  case "$_win" in ''|*[!0-9]*) return 0 ;; esac
  case "$_tty" in
    /dev/tty*)
      _abbr=${_tty#/dev/}
      kill $(ps -t "$_abbr" -o pid= 2>/dev/null) 2>/dev/null
      _i=0                       # wait (≤~3s) for: no processes on the tty …
      while [ "$_i" -lt 15 ]; do
        if [ -z "$(ps -t "$_abbr" -o pid= 2>/dev/null | tr -d ' \n')" ]; then
          # … and Terminal having registered the tab as not busy (else close prompts)
          _b=$(osascript -e "tell application \"Terminal\"
  repeat with w in windows
    if (id of w) is $_win then return (busy of selected tab of w)
  end repeat
  return false
end tell" 2>/dev/null)
          [ "$_b" = false ] && break
        fi
        perl -e 'select(undef,undef,undef,0.2)'
        _i=$((_i+1))
      done ;;
  esac
  osascript >/dev/null 2>&1 <<OSA
tell application "Terminal"
  repeat with w in windows
    try
      if (id of w) is $_win then close w
    end try
  end repeat
end tell
OSA
}
