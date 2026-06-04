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

  # Platform — the dock is macOS + iTerm2 specific (osascript, BSD stat -f/ls -t).
  if [ "$(uname -s)" = Darwin ]; then
    printf '  \xe2\x9c\x93 %-10s macOS\n' platform
  else
    printf '  \xe2\x9c\x97 %-10s %s — built for macOS (osascript, BSD stat/ls)\n' platform "$(uname -s)"
    missing=1
  fi

  # bash >= 4 — the viewer uses $EPOCHSECONDS and fractional `read -t` (bash 5);
  # macOS ships 3.2, so a newer bash must be on PATH (scripts use env bash).
  if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
    printf '  \xe2\x9c\x93 %-10s %s\n' bash "$BASH_VERSION"
  else
    printf '  \xe2\x9c\x97 %-10s %s — need >= 4: brew install bash\n' bash "${BASH_VERSION:-unknown}"
    missing=1
  fi

  # iTerm2 app — the dock splits iTerm2 panes; brief generation works without it,
  # but `/brief` does not.
  if [ -d /Applications/iTerm.app ] || [ -d "$HOME/Applications/iTerm.app" ] \
     || osascript -e 'id of application "iTerm2"' >/dev/null 2>&1; then
    printf '  \xe2\x9c\x93 %-10s installed\n' iTerm2
  else
    printf '  \xe2\x9c\x97 %-10s not found — the dock needs iTerm2 (https://iterm2.com)\n' iTerm2
    missing=1
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
mkdir -p ~/.claude/hooks ~/.claude/bin ~/.claude/commands "$HOME/Library/Application Support/iTerm2/DynamicProfiles"
cp "$root"/claude/hooks/*.sh ~/.claude/hooks/
cp "$root"/claude/bin/*.sh ~/.claude/bin/
cp "$root"/claude/commands/*.md ~/.claude/commands/
cp "$root"/claude/glow-brief.json ~/.claude/
cp "$root"/iterm2/DynamicProfiles/brief.json "$HOME/Library/Application Support/iTerm2/DynamicProfiles/"
chmod +x ~/.claude/hooks/*.sh ~/.claude/bin/*.sh
echo "installed brief-dock files into ~/.claude  (add the settings.json hooks per README)"

[ "$deps_ok" = 1 ] || { echo; echo "WARNING: required dependencies are missing (see above) — install them or the dock won't fully work."; exit 1; }
