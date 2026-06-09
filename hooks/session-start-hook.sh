#!/usr/bin/env bash
# Plugin SessionStart hook: the one-time setup install.sh does for the clone path
# (the iTerm2 dock profile), PLUS a dependency preflight — because `/plugin install`
# runs no interactive dep-check the way `./install.sh` does, so without this a
# missing dep just yields a silently-dead dock. Cheap + idempotent; safe to run
# every session. Plugin-only: install.sh does this at install time and registers no
# SessionStart hook. bash-3.2-safe (runs via env bash) and jq-free (jq may be the
# very thing that's missing, so the warning can't depend on it).
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"   # plugin root (or ~/.claude when installed)
state="$HOME/.claude/state"
mkdir -p "$state" 2>/dev/null

# --- one-time: iTerm2 dock profile (your Default + 1.2x line spacing) -----------
# Copy if on macOS with iTerm2 and not already present. Idempotent; iTerm2 auto-loads it.
if [ "$(uname -s)" = Darwin ] && [ -f "$ROOT/iterm2/DynamicProfiles/brief.json" ]; then
  itd="$HOME/Library/Application Support/iTerm2"
  if [ -d "$itd" ] && [ ! -f "$itd/DynamicProfiles/brief.json" ]; then
    mkdir -p "$itd/DynamicProfiles" 2>/dev/null \
      && cp "$ROOT/iterm2/DynamicProfiles/brief.json" "$itd/DynamicProfiles/" 2>/dev/null
  fi
fi

# --- dependency preflight -------------------------------------------------------
# REQUIRED deps are re-checked every session (warn until installed — a one-shot
# notice is too easy to miss); the OPTIONAL glow note fires once so it never nags.
req=""; brew=""
command -v jq >/dev/null 2>&1 || { req="${req}jq, "; brew="${brew}jq "; }   # every hook parses the transcript with jq
bv=$(bash -c 'echo "${BASH_VERSINFO[0]:-0}"' 2>/dev/null)                    # dock viewer needs $EPOCHSECONDS (bash 5+; macOS ships 3.2)
[ "${bv:-0}" -ge 5 ] || { req="${req}bash 5, "; brew="${brew}bash "; }
if ! command -v osascript >/dev/null 2>&1 && ! command -v tmux >/dev/null 2>&1 \
   && ! command -v kitty >/dev/null 2>&1 && ! command -v wezterm >/dev/null 2>&1; then
  req="${req}a supported terminal (iTerm2/tmux/kitty/wezterm), "            # the dock needs one scriptable backend
fi

opt=""; glow_sentinel="$state/.brief-glow-warned"
if ! command -v glow >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
  [ -f "$glow_sentinel" ] || { opt="glow"; brew="${brew}glow "; : > "$glow_sentinel"; }
fi

# One actionable systemMessage, built with printf (NOT jq — see header). The strings
# below contain no " or \, so they're safe to interpolate into the JSON directly.
msg=""
[ -n "$req" ] && msg="claude-brief: required dep(s) missing — ${req%, } — the dock can't run until these are installed"
[ -n "$opt" ] && msg="${msg:+$msg; }optional: install ${opt} for richer rendering"
if [ -n "$brew" ] && [ "$(uname -s)" = Darwin ]; then   # Homebrew isn't guaranteed — only name it if present
  if command -v brew >/dev/null 2>&1; then msg="${msg} — run: brew install ${brew% }"
  else msg="${msg} — install ${brew% } (Homebrew: https://brew.sh)"; fi
fi
[ -n "$msg" ] && printf '{"systemMessage":"%s"}\n' "$msg"
exit 0
