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
  # Homebrew isn't guaranteed on macOS, so don't hand out `brew install …` blindly:
  # suggest it only when brew is actually present, else point at how to get it.
  brewtip() {  # $1 = space-separated package(s) -> an honest install hint
    if command -v brew >/dev/null 2>&1; then printf 'brew install %s' "$1"
    else printf 'install %s (Homebrew not found — https://brew.sh)' "$1"; fi
  }

  # Platform — the iTerm2/Apple-Terminal drivers are macOS-only (osascript, BSD
  # stat -f/ls -t); the tmux/kitty/wezterm drivers also work on Linux. So macOS is
  # recommended but no longer strictly required.
  if [ "$(uname -s)" = Darwin ]; then
    printf '  \xe2\x9c\x93 %-10s macOS\n' platform
  else
    printf '  ~ %-10s %s — iTerm2/Terminal drivers need macOS; tmux/kitty/wezterm work here\n' platform "$(uname -s)"
  fi

  # bash >= 5 — the viewer uses $EPOCHSECONDS (bash 5.0) for its timers; macOS
  # ships 3.2, so a newer bash must be on PATH (scripts use env bash). (The hooks
  # alone are 3.2-safe, so brief generation works without this — only the dock
  # viewer needs bash 5.)
  if [ "${BASH_VERSINFO[0]:-0}" -ge 5 ]; then
    printf '  \xe2\x9c\x93 %-10s %s\n' bash "$BASH_VERSION"
  else
    printf '  \xe2\x9c\x97 %-10s %s — need >= 5 for the dock viewer: %s\n' bash "${BASH_VERSION:-unknown}" "$(brewtip bash)"
    missing=1
  fi

  # Terminal backends — the dock needs ONE scriptable terminal driver. iTerm2 and
  # Apple Terminal (macOS), tmux / kitty / WezTerm (cross-platform). At least one
  # should be usable; otherwise only the generic "run the viewer yourself" fallback
  # applies.
  # None of these is individually required, so absence is advisory (~), not a fail.
  local have_term=0
  if [ -d /Applications/iTerm.app ] || [ -d "$HOME/Applications/iTerm.app" ]; then
    printf '  \xe2\x9c\x93 %-10s installed (driver: iterm2)\n' iTerm2; have_term=1
  fi
  if command -v tmux >/dev/null 2>&1; then
    printf '  \xe2\x9c\x93 %-10s %s (driver: tmux)\n' tmux "$(command -v tmux)"; have_term=1
  fi
  if command -v kitty >/dev/null 2>&1; then
    printf '  \xe2\x9c\x93 %-10s %s (driver: kitty — needs socket remote control: allow_remote_control + listen_on + restart)\n' kitty "$(command -v kitty)"; have_term=1
  fi
  if command -v wezterm >/dev/null 2>&1; then
    printf '  \xe2\x9c\x93 %-10s %s (driver: wezterm — CLI mux, no config needed)\n' WezTerm "$(command -v wezterm)"; have_term=1
  fi
  if [ -d /Applications/Ghostty.app ] || [ -d "$HOME/Applications/Ghostty.app" ]; then
    printf '  \xe2\x9c\x93 %-10s installed (driver: ghostty — AppleScript splits; one-time Automation approval)\n' Ghostty; have_term=1
  fi
  if [ -d /Applications/Tabby.app ] || [ -d "$HOME/Applications/Tabby.app" ] || command -v tabby >/dev/null 2>&1; then
    printf '  ~ %-10s installed (driver: tabby — MANUAL dock only: no scriptable split/remote-control)\n' Tabby
  fi
  if [ "$(uname -s)" = Darwin ]; then
    printf '  \xe2\x9c\x93 %-10s available (driver: terminal — companion window, no splits)\n' Terminal.app; have_term=1
  fi
  [ "$have_term" = 1 ] || printf '  ~ %-10s none detected — only the generic paste-the-viewer fallback works\n' backends
  # Which driver auto-detection picks in THIS terminal right now (also smoke-tests
  # the driver library against the repo's drivers).
  if [ -f "$root/bin/lib/terminal-driver.sh" ]; then
    local d; d=$( export BRIEF_TERM_DIR="$root/bin/term"; . "$root/bin/lib/terminal-driver.sh" >/dev/null 2>&1; tdrv_name 2>/dev/null )
    [ -n "$d" ] && printf '  \xe2\x86\x92 active driver here: %s\n' "$d"
  fi

  # Required external commands (cmd:install-hint) — needed on EVERY platform.
  for entry in \
    "jq:$(brewtip jq)" \
    "claude:Claude Code CLI — install per your usual method" \
    "perl:preinstalled on macOS — check your PATH (used for the summarizer watchdog + rendering)"
  do
    cmd=${entry%%:*}; hint=${entry#*:}
    if command -v "$cmd" >/dev/null 2>&1; then
      printf '  \xe2\x9c\x93 %-10s %s\n' "$cmd" "$(command -v "$cmd")"
    else
      printf '  \xe2\x9c\x97 %-10s MISSING — %s\n' "$cmd" "$hint"
      missing=1
    fi
  done

  # osascript is a macOS built-in used ONLY by the AppleScript drivers
  # (iterm2/ghostty/terminal) + the Apple Terminal profile — irrelevant on Linux, so
  # it is NEVER required (tmux/kitty/wezterm need none of it); just reported on macOS.
  if [ "$(uname -s)" = Darwin ]; then
    if command -v osascript >/dev/null 2>&1; then
      printf '  \xe2\x9c\x93 %-10s %s\n' osascript "$(command -v osascript)"
    else
      printf '  ~ %-10s not found — the iTerm2/ghostty/Apple-Terminal drivers need it\n' osascript
    fi
  fi

  # Optional renderer: glow preferred, bat fallback, else plain-text styling.
  if command -v glow >/dev/null 2>&1; then
    printf '  \xe2\x9c\x93 %-10s %s\n' glow "$(command -v glow)"
  elif command -v bat >/dev/null 2>&1; then
    printf '  ~ %-10s glow absent; bat fallback in use — %s for best output\n' bat "$(brewtip glow)"
  else
    printf '  ~ %-10s no glow/bat; plain-text fallback — %s recommended\n' renderer "$(brewtip glow)"
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
cp "$root"/hooks/*.sh ~/.claude/hooks/
cp "$root"/bin/*.sh ~/.claude/bin/
cp "$root"/bin/lib/*.sh ~/.claude/bin/lib/
rm -f ~/.claude/bin/term/*.sh 2>/dev/null   # migration: drop pre-subdir flat drivers
for _d in common darwin linux; do            # term/<os>/ + term/common/ (see terminal-driver.sh)
  ls "$root"/bin/term/"$_d"/*.sh >/dev/null 2>&1 || continue
  mkdir -p ~/.claude/bin/term/"$_d"
  cp "$root"/bin/term/"$_d"/*.sh ~/.claude/bin/term/"$_d"/
done
cp "$root"/commands/*.md ~/.claude/commands/
cp "$root"/glow-brief.json ~/.claude/
# iTerm2 dock profile — only on macOS, and only if present in the repo.
if [ "$(uname -s)" = Darwin ] && [ -f "$root"/iterm2/DynamicProfiles/brief.json ]; then
  mkdir -p "$HOME/Library/Application Support/iTerm2/DynamicProfiles"
  cp "$root"/iterm2/DynamicProfiles/brief.json "$HOME/Library/Application Support/iTerm2/DynamicProfiles/"
fi
chmod +x ~/.claude/hooks/*.sh ~/.claude/bin/*.sh
echo "installed brief-dock files into ~/.claude  (add the settings.json hooks per README)"

# Apple Terminal dock profile: build a 'brief' settings set from the profile THIS
# Terminal uses + 1.2x line spacing (set BRIEF_FONT_BUMP=N to also enlarge the font).
# Only when installing FROM Apple Terminal — so it reads the right profile and doesn't
# pop a Terminal window for iTerm2/tmux/kitty/wezterm users. Idempotent (skips if 'brief' exists).
if [ "$(uname -s)" = Darwin ] && [ "${TERM_PROGRAM:-}" = Apple_Terminal ]; then
  "$HOME/.claude/bin/brief-term-profile.sh" || true
fi

[ "$deps_ok" = 1 ] || { echo; echo "WARNING: required dependencies are missing (see above) — install them or the dock won't fully work."; exit 1; }
