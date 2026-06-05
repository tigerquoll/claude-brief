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

# Lazily create the dock's settings set ($BRIEF_PROFILE, default "brief") the first
# time it's needed, by CLONING the session's current profile (font, colors, …) and
# bumping the font size ($BRIEF_FONT_BUMP, default +2) — entirely via AppleScript, so
# NO window is opened. Records a marker so session-end can delete it (ref-counted)
# once the last dock closes. NOTE: line spacing (FontHeightSpacing) is deliberately
# NOT set — AppleScript can't, and the only alternative (importing a .terminal) opens
# a window that Terminal won't let us close cleanly. Best-effort: on failure the dock
# just inherits the session profile unchanged.
_brief_make_profile(){
  _p="${BRIEF_PROFILE:-brief}"
  osascript -e "tell application \"Terminal\" to return (exists settings set \"$_p\")" 2>/dev/null | grep -qi true && return 0
  osascript >/dev/null 2>&1 <<OSA
tell application "Terminal"
  try
    set ns to (make new settings set with properties (properties of current settings of front window))
    try
      set name of ns to "$_p"
    end try
    try
      set font size of ns to ((font size of ns) + ${BRIEF_FONT_BUMP:-2})
    end try
  end try
end tell
OSA
  # mark auto-created (only if it now exists) so session-end can ref-count + delete it
  osascript -e "tell application \"Terminal\" to return (exists settings set \"$_p\")" 2>/dev/null | grep -qi true \
    && printf '%s' "$_p" > "$HOME/.claude/state/brief.profile.auto" 2>/dev/null
  return 0
}

# tdrv_open MODE ANCHOR CMD…  -> echo "<winid>:<tty>" (tty captured for a reliable close)
tdrv_open(){
  _mode=$1; shift 2; _cmd="$*"
  _pos=1; [ "$_mode" = float ] && _pos=0
  _prof="${BRIEF_PROFILE:-brief}"
  _brief_make_profile                    # lazily create "brief" from the session profile if missing
  _err="${TMPDIR:-/tmp}/brief-term.$$"
  _id=$(osascript 2>"$_err" <<OSA
tell application "Terminal"
  activate
  set fb to {0, 0, 0, 0}
  set srcSet to missing value
  try
    set fb to bounds of front window
    set srcSet to current settings of front window   -- the session's profile (for inheritance)
  end try
  set newTab to do script "exec $_cmd"
  set theTty to ""
  try
    set theTty to tty of newTab
  end try
  set theWin to (first window whose selected tab is newTab)
  -- Dock styling: the "brief" settings set (\$BRIEF_PROFILE) if it exists — the
  -- shipped brief = your default profile + 1.2× line spacing — else inherit the
  -- session window's profile. Styling only; close stays kill-based (independent).
  if (exists settings set "$_prof") then
    try
      set current settings of newTab to settings set "$_prof"
    end try
  else if srcSet is not missing value then
    try
      set current settings of newTab to srcSet
    end try
  end if
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

# tdrv_close "<winid>:<tty>"  — make the dock window idle, then close it (a busy
# window won't close and pops the terminate prompt; only an idle one closes clean).
# SAFETY: ttys get recycled, so we must NEVER blanket-kill a tty — a closed dock's
# tty may now belong to something else (e.g. a fresh `claude`). So: (a) bail unless
# the dock window still exists, and (b) kill ONLY processes whose command is THIS
# dock's viewer (brief-view.sh) on that tty — never anything else sharing it.
tdrv_close(){
  _id=$1; [ -n "$_id" ] || return 0
  _win=${_id%%:*}; _tty=${_id#*:}
  case "$_win" in ''|*[!0-9]*) return 0 ;; esac
  # The dock window must still exist; otherwise do nothing (don't touch a reused tty).
  _exists=$(osascript -e "tell application \"Terminal\"
  repeat with w in windows
    if (id of w) is $_win then return \"y\"
  end repeat
  return \"n\"
end tell" 2>/dev/null)
  [ "$_exists" = y ] || return 0
  case "$_tty" in
    /dev/tty*)
      _abbr=${_tty#/dev/}
      _i=0                       # kill the viewer, then wait for the tab to go idle
      while [ "$_i" -lt 15 ]; do
        # ONLY brief-view processes on this tty — never a process that merely
        # inherited a recycled tty.
        _pids=$(ps -t "$_abbr" -o pid=,command= 2>/dev/null | grep -F 'brief-view.sh' | awk '{print $1}')
        if [ -n "$_pids" ]; then
          kill $_pids 2>/dev/null
        else
          _b=$(osascript -e "tell application \"Terminal\"
  repeat with w in windows
    if (id of w) is $_win then return (busy of selected tab of w)
  end repeat
  return false
end tell" 2>/dev/null)
          [ "$_b" = false ] && break   # idle (no viewer left, Terminal agrees): safe to close
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
