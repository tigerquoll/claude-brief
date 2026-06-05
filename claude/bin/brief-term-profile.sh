#!/usr/bin/env bash
# Create the Apple Terminal "brief" settings set the dock uses — a copy of the
# profile YOUR Terminal currently uses, plus 1.2× line spacing (and an optional font
# bump via $BRIEF_FONT_BUMP). Run it FROM Terminal: it reads the front window's
# profile, so the dock matches what you actually use. It imports the profile via
# `open` (which flashes one Terminal window — just close it) ONLY if "brief" isn't
# already present, so it's safe/idempotent to re-run. To rebuild from a different
# profile, delete the "brief" profile first (Settings ▸ Profiles ▸ brief ▸ –), then
# re-run. The driver (bin/term/terminal.sh) applies "brief" to the dock if it exists,
# else inherits the session profile — so this is optional; it only adds the spacing.
#
# Why a static, install-time profile (not created live on /brief): line spacing
# (FontHeightSpacing) is only settable by importing a .terminal, and that import
# opens a login-shell window Terminal won't let us close cleanly. Doing it once at
# install keeps that one transient window out of the per-/brief path.
set -u
[ "$(uname -s)" = Darwin ] || { echo "brief: the Terminal 'brief' profile is macOS-only."; exit 0; }
command -v osascript >/dev/null 2>&1 || { echo "brief: osascript not found."; exit 0; }

p="${BRIEF_PROFILE:-brief}"; case "$p" in ''|*[!A-Za-z0-9_-]*) p=brief ;; esac
out="$HOME/.claude/brief.terminal"

# Idempotent: AppleScript matches settings-set names case-insensitively.
if osascript -e "tell application \"Terminal\" to return (exists settings set \"$p\")" 2>/dev/null | grep -qi true; then
  echo "brief: Terminal profile '$p' already exists — delete it to rebuild from a different profile."
  exit 0
fi

# The profile your Terminal uses right now (front window), else the new-window default.
src=$(osascript -e 'tell application "Terminal" to return name of current settings of front window' 2>/dev/null)
[ -n "$src" ] || src=$(defaults read com.apple.Terminal "Default Window Settings" 2>/dev/null)
[ -n "$src" ] || { echo "brief: couldn't determine the current Terminal profile (run me from Terminal)."; exit 1; }

stamp(){   # set name + 1.2× line spacing on $out
  plutil -convert xml1 "$out" >/dev/null 2>&1
  /usr/libexec/PlistBuddy -c "Set :name $p" "$out" >/dev/null 2>&1 || /usr/libexec/PlistBuddy -c "Add :name string $p" "$out" >/dev/null 2>&1
  /usr/libexec/PlistBuddy -c "Set :FontHeightSpacing 1.2" "$out" >/dev/null 2>&1 || /usr/libexec/PlistBuddy -c "Add :FontHeightSpacing real 1.2" "$out" >/dev/null 2>&1
}
import_check(){   # open $out, wait for the profile to register; echo true/false
  open "$out" 2>/dev/null
  _i=0; while [ "$_i" -lt 20 ]; do
    osascript -e "tell application \"Terminal\" to return (exists settings set \"$p\")" 2>/dev/null | grep -qi true && { echo true; return; }
    perl -e 'select(undef,undef,undef,0.25)'; _i=$((_i+1))
  done
  echo false
}

ok=false
# 1) Prefer the user's ACTUAL profile from prefs (keeps any customizations).
if defaults export com.apple.Terminal - 2>/dev/null | plutil -extract "Window Settings.$src" xml1 -o "$out" - 2>/dev/null; then
  stamp; ok=$(import_check)
fi
# 2) Fall back to the COMPLETE bundled built-in — a minimally-customized prefs dict
#    opens a window on import but doesn't register as a saved profile; bundled does.
if [ "$ok" != true ]; then
  for b in "/System/Applications/Utilities/Terminal.app/Contents/Resources/Initial Settings/$src.terminal" \
           "/Applications/Utilities/Terminal.app/Contents/Resources/Initial Settings/$src.terminal"; do
    [ -f "$b" ] && { cp "$b" "$out"; stamp; ok=$(import_check); break; }
  done
fi
if [ "$ok" != true ]; then
  echo "brief: couldn't register a '$p' profile from '$src' — the dock will inherit your session profile (no extra spacing)."
  exit 1
fi

# Optional font bump on the now-registered profile (windowless). Default off.
bump="${BRIEF_FONT_BUMP:-0}"; case "$bump" in ''|*[!0-9]*) bump=0 ;; esac
if [ "$bump" -gt 0 ]; then
  osascript >/dev/null 2>&1 <<OSA
tell application "Terminal"
  try
    set font size of settings set "$p" to ((font size of settings set "$p") + $bump)
  end try
end tell
OSA
fi

extra=""; [ "$bump" -gt 0 ] && extra=" + ${bump}pt font"
echo "brief: Terminal profile '$p' ready — based on '$src' + 1.2× line spacing$extra. Close the extra window that opened during import."
