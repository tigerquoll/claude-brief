#!/usr/bin/env bash
# Deploy repo -> ~/.claude (+ the iTerm2 dock profile). Use to restore/recover or
# set up a new machine. Does NOT touch settings.json — add the hook entries by
# hand (see README).
#   ./install.sh           check deps, then install
#   ./install.sh --check   only run the dependency check (installs nothing)
set -e
root="$(cd "$(dirname "$0")" && pwd)"

# --- dependency check -------------------------------------------------------
# REQUIRED = the dock/brief won't function without it; OPTIONAL = graceful
# fallback. Several of these are NOT on a stock macOS (modern bash, jq, GNU
# timeout from coreutils), so check before the user wonders why nothing updates.
# Returns non-zero if any REQUIRED dependency is missing.
check_deps() {
  local missing=0 entry cmd hint

  # Platform — the iTerm2/Apple-Terminal drivers are macOS-only (osascript, BSD
  # stat -f/ls -t); the tmux/kitty drivers also work on Linux. So macOS is
  # recommended but no longer strictly required.
  if [ "$(uname -s)" = Darwin ]; then
    printf '  \xe2\x9c\x93 %-10s macOS\n' platform
  else
    printf '  ~ %-10s %s — iTerm2/Terminal drivers need macOS; tmux/kitty work here\n' platform "$(uname -s)"
  fi

  # bash >= 5 — the viewer uses $EPOCHSECONDS (bash 5.0) for its timers; macOS
  # ships 3.2, so a newer bash must be on PATH (scripts use env bash). (The hooks
  # alone are 3.2-safe, so brief generation works without this — only the dock
  # viewer needs bash 5.)
  if [ "${BASH_VERSINFO[0]:-0}" -ge 5 ]; then
    printf '  \xe2\x9c\x93 %-10s %s\n' bash "$BASH_VERSION"
  else
    printf '  \xe2\x9c\x97 %-10s %s — need >= 5 for the dock viewer: brew install bash\n' bash "${BASH_VERSION:-unknown}"
    missing=1
  fi

  # Terminal backends — the dock needs ONE scriptable terminal driver. iTerm2 and
  # Apple Terminal (macOS), tmux and kitty (cross-platform). At least one should be
  # usable; otherwise only the generic "run the viewer yourself" fallback applies.
  # None of these is individually required, so absence is advisory (~), not a fail.
  local have_term=0
  if [ -d /Applications/iTerm.app ] || [ -d "$HOME/Applications/iTerm.app" ]; then
    printf '  \xe2\x9c\x93 %-10s installed (driver: iterm2)\n' iTerm2; have_term=1
  fi
  if command -v tmux >/dev/null 2>&1; then
    printf '  \xe2\x9c\x93 %-10s %s (driver: tmux)\n' tmux "$(command -v tmux)"; have_term=1
  fi
  if command -v kitty >/dev/null 2>&1; then
    printf '  \xe2\x9c\x93 %-10s %s (driver: kitty — needs allow_remote_control + splits layout)\n' kitty "$(command -v kitty)"; have_term=1
  fi
  if [ "$(uname -s)" = Darwin ]; then
    printf '  \xe2\x9c\x93 %-10s available (driver: terminal — companion window, no splits)\n' Terminal.app; have_term=1
  fi
  [ "$have_term" = 1 ] || printf '  ~ %-10s none detected — only the generic paste-the-viewer fallback works\n' backends
  # Which driver auto-detection picks in THIS terminal right now (also smoke-tests
  # the driver library against the repo's drivers).
  if [ -f "$root/claude/bin/lib/terminal-driver.sh" ]; then
    local d; d=$( BRIEF_TERM_DIR="$root/claude/bin/term"; . "$root/claude/bin/lib/terminal-driver.sh" >/dev/null 2>&1; tdrv_name 2>/dev/null )
    [ -n "$d" ] && printf '  \xe2\x86\x92 active driver here: %s\n' "$d"
  fi

  # Required external commands (cmd:install-hint).
  for entry in \
    "jq:brew install jq" \
    "claude:Claude Code CLI — install per your usual method" \
    "perl:preinstalled on macOS — check your PATH (used for the summarizer watchdog + rendering)" \
    "osascript:macOS built-in — are you on macOS?"
  do
    cmd=${entry%%:*}; hint=${entry#*:}
    if command -v "$cmd" >/dev/null 2>&1; then
      printf '  \xe2\x9c\x93 %-10s %s\n' "$cmd" "$(command -v "$cmd")"
    else
      printf '  \xe2\x9c\x97 %-10s MISSING — %s\n' "$cmd" "$hint"
      missing=1
    fi
  done

  # Optional renderer: glow preferred, bat fallback, else plain-text styling.
  if command -v glow >/dev/null 2>&1; then
    printf '  \xe2\x9c\x93 %-10s %s\n' glow "$(command -v glow)"
  elif command -v bat >/dev/null 2>&1; then
    printf '  ~ %-10s glow absent; using bat fallback (brew install glow for best output)\n' bat
  else
    printf '  ~ %-10s no glow/bat; plain-text fallback (brew install glow recommended)\n' renderer
  fi

  return $missing
}

echo "brief-dock dependency check:"
deps_ok=1; check_deps || deps_ok=0

if [ "${1:-}" = --check ]; then
  echo
  if [ "$deps_ok" = 1 ]; then echo "all required dependencies present"; exit 0
  else echo "missing required dependencies (see above)"; exit 1; fi
fi

# --- install ----------------------------------------------------------------
echo
mkdir -p ~/.claude/hooks ~/.claude/bin ~/.claude/bin/lib ~/.claude/bin/term ~/.claude/commands
cp "$root"/claude/hooks/*.sh ~/.claude/hooks/
cp "$root"/claude/bin/*.sh ~/.claude/bin/
cp "$root"/claude/bin/lib/*.sh ~/.claude/bin/lib/
cp "$root"/claude/bin/term/*.sh ~/.claude/bin/term/
cp "$root"/claude/commands/*.md ~/.claude/commands/
cp "$root"/claude/glow-brief.json ~/.claude/
# iTerm2 dock profile — only on macOS, and only if present in the repo.
if [ "$(uname -s)" = Darwin ] && [ -f "$root"/iterm2/DynamicProfiles/brief.json ]; then
  mkdir -p "$HOME/Library/Application Support/iTerm2/DynamicProfiles"
  cp "$root"/iterm2/DynamicProfiles/brief.json "$HOME/Library/Application Support/iTerm2/DynamicProfiles/"
fi
# (The Apple Terminal 'brief' settings set is created lazily on first /brief — a
# windowless AppleScript clone of your session profile with a bumped font size — and
# auto-deleted when the last dock closes. See claude/bin/term/terminal.sh. Nothing
# to install here.)
chmod +x ~/.claude/hooks/*.sh ~/.claude/bin/*.sh
echo "installed brief-dock files into ~/.claude  (add the settings.json hooks per README)"

[ "$deps_ok" = 1 ] || { echo; echo "WARNING: required dependencies are missing (see above) — install them or the dock won't fully work."; exit 1; }
