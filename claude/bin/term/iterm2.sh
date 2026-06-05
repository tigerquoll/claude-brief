# iTerm2 driver (reference). The original brief-open/session-end osascript,
# relocated behind the driver contract. iTerm2 3.6: create/split take no 'command'
# param and return 'missing value', so we grab the new session and `write text`;
# AppleScript `close` bypasses the "process running?" prompt (both verified).
# Sourced by terminal-driver.sh — keep bash-3.2-safe.

tdrv_name(){ printf 'iterm2'; }

# Pane UUID = the part after the colon in $ITERM_SESSION_ID, hex+dash only. Used
# both as the pane→sid map key and as the split anchor (matches `id of session`).
tdrv_self_pane(){ printf '%s' "${ITERM_SESSION_ID#*:}" | tr -dc '0-9A-Fa-f-'; }

# tdrv_open MODE ANCHOR CMD…  -> echo the new session's id
tdrv_open(){
  _mode=$1 _anchor=$2; shift 2; _cmd="$*"
  osascript 2>/dev/null <<OSA
tell application "iTerm2"
  activate
  -- Anchor the split to the pane that ran /brief (id == \$_anchor) rather than
  -- whatever is frontmost, so a delayed /brief docks beside the right tab.
  set anchorSess to missing value
  if "$_anchor" is not "" then
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (id of s) is "$_anchor" then set anchorSess to s
        end repeat
      end repeat
    end repeat
  end if
  if "$_mode" is "float" then
    create window with profile "brief"
    set newSess to (current session of current window)
  else if anchorSess is not missing value then
    tell anchorSess
      set newSess to (split vertically with profile "brief")
    end tell
  else
    tell current session of current window
      set newSess to (split vertically with profile "brief")
    end tell
  end if
  tell newSess to write text "$_cmd"
  return (id of newSess)
end tell
OSA
}

tdrv_close(){
  _id=$1; [ -n "$_id" ] || return 0
  case "$_id" in *[!0-9a-fA-F-]*) return 0 ;; esac   # UUID-shaped only (anti-injection)
  osascript >/dev/null 2>&1 <<OSA
tell application "iTerm2"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (id of s) is "$_id" then
          try
            close s
          end try
        end if
      end repeat
    end repeat
  end repeat
end tell
OSA
}
