#!/usr/bin/env bash
# Plugin SessionStart hook: the one-time setup install.sh does for the clone path —
# but for plugin users (who never run install.sh). Sentinel-gated so it's ~free after
# the first run, and idempotent. Plugin-only: the install.sh path performs this at
# install time and registers no SessionStart hook. bash-3.2-safe (runs via env bash).
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"   # plugin root (or ~/.claude when installed)
state="$HOME/.claude/state"
sentinel="$state/.brief-plugin-setup"
[ -f "$sentinel" ] && exit 0                  # already set up — do nothing
mkdir -p "$state" 2>/dev/null

warn=""
# bash >= 5 — the dock VIEWER needs $EPOCHSECONDS (macOS ships 3.2). The hooks/brief
# generation are 3.2-safe, so only the live dock needs this.
bv=$(bash -c 'echo "${BASH_VERSINFO[0]:-0}"' 2>/dev/null)
[ "${bv:-0}" -ge 5 ] || warn="${warn}bash 5 for the dock viewer (brew install bash); "
# glow (preferred) or bat — rich markdown rendering; else a plain-text fallback.
command -v glow >/dev/null 2>&1 || command -v bat >/dev/null 2>&1 \
  || warn="${warn}glow for rich rendering (brew install glow); "

# iTerm2 dock profile (the 'brief' DynamicProfile = your Default + 1.2x line spacing).
# Copy if on macOS with iTerm2 and it isn't already installed. iTerm2 auto-loads it.
if [ "$(uname -s)" = Darwin ] && [ -f "$ROOT/iterm2/DynamicProfiles/brief.json" ]; then
  itd="$HOME/Library/Application Support/iTerm2"
  if [ -d "$itd" ] && [ ! -f "$itd/DynamicProfiles/brief.json" ]; then
    mkdir -p "$itd/DynamicProfiles" 2>/dev/null \
      && cp "$ROOT/iterm2/DynamicProfiles/brief.json" "$itd/DynamicProfiles/" 2>/dev/null
  fi
fi

: > "$sentinel"   # mark setup done so this never runs again (delete it to re-run)

# Surface any missing optional deps ONCE (the dock still works without them).
[ -n "$warn" ] && printf '{"systemMessage":"claude-brief: optional deps missing — %s"}\n' "${warn%; }"
exit 0
