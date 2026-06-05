# Ghostty driver. Ghostty ships a rich AppleScript dictionary (Ghostty.sdef), so —
# unlike Apple Terminal — it does TRUE scriptable splits: the dock is a real
# side-by-side split in the current window (a separate window for `float`), created
# from a `surface configuration` whose `command` runs the viewer. Stable per-surface
# UUIDs let us target and close precisely. First use triggers the one-time macOS
# Automation (TCC) approval (osascript error -1743 until granted). Sourced — 3.2-safe.
#
# Two ghostty quirks shape this driver:
#  1. No per-surface env var (no TERM_SESSION_ID equivalent), and hooks have no
#     controlling tty here — so the only stable per-pane id is the AppleScript
#     terminal UUID. tdrv_self_pane fetches it via `focused terminal of selected tab
#     of front window` (~0.1s round-trip; the front window IS the session's window
#     whenever a prompt is submitted or /brief is run, so it resolves the caller).
#  2. A surface launched via `command` runs with a GUI-minimal PATH (no Homebrew),
#     so `#!/usr/bin/env bash` would find macOS bash 3.2, not the bash 5 the viewer
#     needs. We inject the caller's full PATH via the config's `environment
#     variables` (which MERGE with the inherited env, so HOME etc. survive).
#
# CLOSING: `close <terminal>` on a surface with a LIVE process pops Ghostty's
# `confirm-close-surface` modal (the same wedge trap as Apple Terminal). So we never
# do that — instead we kill THIS dock's viewer first, then `close` the now
# process-free surface (which is silent). The kill is scoped to `brief-view.sh <sid>`
# (fixed-string match on the script name + the exact session UUID), so it can never
# hit any other process even if ttys/pids were recycled. To carry the sid to close
# time, tdrv_open encodes the pane id as "<terminal-uuid>:<sid>".

tdrv_name(){ printf 'ghostty'; }

# Per-pane id = the focused terminal's AppleScript UUID (hex+dash). Empty on any
# error (no Ghostty / not authorized yet) -> brief-open falls back to cwd.
tdrv_self_pane(){
  osascript 2>/dev/null <<'OSA' | tr -dc '0-9A-Fa-f-'
tell application "Ghostty"
  try
    return (id of (focused terminal of selected tab of front window) as string)
  end try
  return ""
end tell
OSA
}

# tdrv_open MODE ANCHOR CMD…  -> echo "<terminal-uuid>:<sid>" (empty on failure)
# ANCHOR is the terminal UUID to split (from tdrv_self_pane); if empty/stale we fall
# back to the front window's focused terminal. The dock inherits the user's Ghostty
# theme/spacing (the surface-configuration record exposes no line-spacing key, only
# font size), like the tmux/kitty docks — so $BRIEF_PROFILE does not apply here.
#
# SUGGESTED ghostty config (optional; we do NOT set these — ghostty has no per-surface
# override, so they're GLOBAL and affect your main sessions too). In ~/.config/ghostty/config:
#   unfocused-split-opacity = 1   # don't dim the dock split while you're in the session pane
#   adjust-cell-height = 20%      # ~1.2× line spacing, like the iTerm2 brief profile
tdrv_open(){
  _mode=$1 _anchor=$2; shift 2; _cmd="$*"
  # sid = the last CMD arg (brief-view.sh <sid>); carried into the pane id for close.
  _sid=""; for _a in "$@"; do _sid="$_a"; done
  case "$_anchor" in *[!0-9A-Fa-f-]*) _anchor="" ;; esac   # UUID-shaped anchor only
  # Inject the caller's PATH so the viewer's `env bash` resolves bash 5, not 3.2.
  _path=$(printf '%s' "$PATH" | sed 's/\\/\\\\/g; s/"/\\"/g')
  _err="${TMPDIR:-/tmp}/brief-ghostty.$$"
  _tid=$(osascript 2>"$_err" <<OSA
tell application "Ghostty"
  set cfg to new surface configuration
  set command of cfg to "$_cmd"
  set wait after command of cfg to false
  set environment variables of cfg to {"PATH=$_path"}
  if "$_mode" is "float" then
    set win to (new window with configuration cfg)
    set newT to (focused terminal of selected tab of win)
  else
    set anchorT to missing value
    if "$_anchor" is not "" then
      try
        set anchorT to (first terminal whose id is "$_anchor")
      end try
    end if
    if anchorT is missing value then
      set anchorT to (focused terminal of selected tab of front window)
    end if
    set newT to (split anchorT direction right with configuration cfg)
    -- The split grabs keyboard focus; hand it back so typing stays in the session.
    try
      focus anchorT
    end try
  end if
  return (id of newT as string)
end tell
OSA
)
  _tid=$(printf '%s' "$_tid" | tr -dc '0-9A-Fa-f-')
  if [ -z "$_tid" ]; then
    case "$(cat "$_err" 2>/dev/null)" in
      *-1743*|*[Nn]ot\ authorized*)
        printf 'brief: Ghostty automation not authorized — approve it in System Settings ▸ Privacy & Security ▸ Automation, then retry /brief.\n' >&2 ;;
    esac
    rm -f "$_err" 2>/dev/null; return 0
  fi
  rm -f "$_err" 2>/dev/null
  printf '%s:%s' "$_tid" "$_sid"
}

# tdrv_close "<terminal-uuid>:<sid>" — kill this dock's viewer (so the surface has no
# live process), then close the surface by id (silent; no confirm modal).
# SAFETY: the kill matches `brief-view.sh <sid>` as a fixed string, so it only ever
# hits this dock's viewer — never a process that reused its pid/tty.
# We SIGKILL: Ghostty launches the surface command under `/usr/bin/login … bash …`,
# and that login wrapper ignores SIGTERM (the chain survives it), while Ghostty's
# `close` does not terminate the command. SIGKILL is uncatchable, so it's the
# reliable teardown; the viewer's screen-restore (cleanup) is moot since the surface
# is destroyed immediately after.
tdrv_close(){
  _id=$1; [ -n "$_id" ] || return 0
  case "$_id" in *:*) ;; *) return 0 ;; esac           # need both halves; bail otherwise
  _tid=${_id%%:*}; _sid=${_id#*:}
  case "$_tid" in ''|*[!0-9A-Fa-f-]*) return 0 ;; esac # UUID-shaped terminal id
  case "$_sid" in ''|*[!0-9A-Fa-f-]*) return 0 ;; esac # UUID-shaped session id
  _i=0                       # SIGKILL the viewer; loop until it's gone (or ~3s)
  while [ "$_i" -lt 15 ]; do
    _pids=$(ps -ax -o pid=,command= 2>/dev/null | grep -F "brief-view.sh $_sid" | grep -v grep | awk '{print $1}')
    [ -z "$_pids" ] && break
    # One pid per line; a read loop kills each regardless of the sourcing shell's
    # word-splitting rules (bash splits unquoted $_pids, zsh does not).
    printf '%s\n' "$_pids" | while IFS= read -r _p; do kill -KILL "$_p" 2>/dev/null; done
    perl -e 'select(undef,undef,undef,0.2)'
    _i=$((_i+1))
  done
  # Now process-free -> closing by id is silent. No-ops if the surface is already gone.
  osascript >/dev/null 2>&1 <<OSA
tell application "Ghostty"
  repeat with tm in terminals
    try
      if (id of tm as string) is "$_tid" then close tm
    end try
  end repeat
end tell
OSA
}
