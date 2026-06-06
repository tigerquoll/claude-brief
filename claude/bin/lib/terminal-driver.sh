#!/usr/bin/env bash
# Pluggable terminal "driver" layer for the brief dock. This file is SOURCED (not
# executed) by brief-open.sh and the prompt/session-end hooks. It picks ONE
# backend — by an explicit $BRIEF_TERMINAL name, else by auto-detection (the inner
# multiplexer wins) — and sources it, so exactly one definition of each tdrv_*
# function is in scope afterwards.
#
# Each backend (bin/term/<name>.sh) defines four functions:
#   tdrv_name                    -> echoes the driver's short name (iterm2/tmux/…)
#   tdrv_self_pane               -> the current pane's native id, already
#                                   filesystem-safe and usable as that driver's
#                                   split anchor; empty if the terminal has none
#   tdrv_open MODE ANCHOR CMD…   -> create the dock (MODE=dock|float) beside
#                                   ANCHOR, run CMD…, echo the new dock pane/window
#                                   id on stdout (empty on failure); human hints
#                                   go to stderr
#   tdrv_close PANEID            -> close that dock pane/window (validates the id)
#
# Kept bash-3.2-safe: the hooks source it, and macOS ships bash 3.2. No arrays,
# no [[ ]], no $EPOCHSECONDS — only [ ], case, printf, tr.
#
# $BRIEF_TERMINAL is a NAME (iterm2|tmux|kitty|terminal|generic|auto), never a
# path — it selects bin/term/<name>.sh from the trusted install dir. Restricting
# it to a whitelisted name (vs the summariser's arbitrary-path model) means we
# never source code from outside that dir, even on a hostile value.

_BRIEF_TERM_DIR="${BRIEF_TERM_DIR:-$HOME/.claude/bin/term}"
# OS bucket = lowercased `uname -s` (darwin/linux/…); sanitised so it can only ever
# be a plain dir component. Drivers live in term/<os>/ (OS-specific) and term/common/
# (cross-platform); see _brief_driver_file. This is what lets macOS + Linux drivers
# ship together WITHOUT interfering — a macOS-only driver sits in term/darwin/ and is
# simply not on Linux's search path, so it can never be sourced there.
_BRIEF_OS=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')
case "$_BRIEF_OS" in *[!a-z]*|'') _BRIEF_OS=unknown ;; esac

# Resolve a driver NAME to its file: an OS-specific override (term/<os>/NAME.sh)
# beats the cross-platform term/common/NAME.sh. Echoes the path, or nothing if no
# such driver exists for this OS.
_brief_driver_file() {
  if   [ -f "$_BRIEF_TERM_DIR/$_BRIEF_OS/$1.sh" ]; then printf '%s' "$_BRIEF_TERM_DIR/$_BRIEF_OS/$1.sh"
  elif [ -f "$_BRIEF_TERM_DIR/common/$1.sh" ];     then printf '%s' "$_BRIEF_TERM_DIR/common/$1.sh"
  fi
}

# Auto-detect a DROP-IN driver — the extension point for porters / custom terminals.
# A driver that defines tdrv_detect() (returns 0 when it recognises the current
# terminal) is picked up here with NO edit to this file. We scan term/<os>/ then
# term/common/ and the FIRST driver whose tdrv_detect succeeds wins — never looking
# in the OTHER OS's dir, so wrong-OS drivers are never even sourced. A name found in
# term/<os>/ shadows the same name in term/common/. The built-in chain below is
# consulted FIRST (shipped drivers keep their tested precedence); this only runs for
# an otherwise-unknown terminal, returning 'generic' if nothing claims it. Each
# candidate is sourced in a SUBSHELL. Kept bash-3.2-safe.
_brief_autodetect_extra() {
  _seen=" "
  for _d in "$_BRIEF_TERM_DIR/$_BRIEF_OS" "$_BRIEF_TERM_DIR/common"; do
    [ -d "$_d" ] || continue
    for _f in "$_d"/*.sh; do
      [ -f "$_f" ] || continue
      _bn=${_f##*/}; _bn=${_bn%.sh}
      case "$_seen" in *" $_bn "*) continue ;; esac   # an <os>/ driver shadows the common one
      _seen="$_seen$_bn "
      _nm=$(
        . "$_f" >/dev/null 2>&1 || exit 0
        command -v tdrv_detect >/dev/null 2>&1 || exit 0
        tdrv_detect >/dev/null 2>&1 || exit 0
        printf '%s' "$(tdrv_name 2>/dev/null)"
      )
      case "$_nm" in ''|*[!a-z0-9]*) continue ;; esac
      printf '%s' "$_nm"; return 0
    done
  done
  printf 'generic'
}

_brief_pick_driver() {
  _n="${BRIEF_TERMINAL:-auto}"
  case "$_n" in
    auto|'')
      if   [ -n "${TMUX:-}" ];                            then _n=tmux
      elif [ -n "${KITTY_WINDOW_ID:-}" ];                 then _n=kitty
      elif [ "${TERM_PROGRAM:-}" = WezTerm ] \
        || [ -n "${WEZTERM_PANE:-}" ];                     then _n=wezterm
      elif [ "${TERM_PROGRAM:-}" = Tabby ] \
        || [ -n "${TABBY_CONFIG_DIRECTORY:-}" ];           then _n=tabby
      elif [ "${TERM_PROGRAM:-}" = ghostty ] \
        || [ -n "${GHOSTTY_RESOURCES_DIR:-}" ];           then _n=ghostty
      elif [ "${TERM_PROGRAM:-}" = iTerm.app ] \
        || [ -n "${ITERM_SESSION_ID:-}" ];                then _n=iterm2
      elif [ "${TERM_PROGRAM:-}" = Apple_Terminal ];      then _n=terminal
      else                                                     _n=$(_brief_autodetect_extra)
      fi ;;
  esac
  # Name whitelist: lowercase alnum only. Anything else (a path, traversal, empty,
  # unknown) collapses to generic and can never resolve outside term/.
  case "$_n" in *[!a-z0-9]*|'') _n=generic ;; esac
  # Resolve to a real file (OS-specific > common); a built-in name with no driver for
  # THIS OS (e.g. ghostty on Linux, before a linux/ghostty.sh exists) falls back to
  # generic rather than failing.
  _file=$(_brief_driver_file "$_n"); [ -n "$_file" ] || _file=$(_brief_driver_file generic)
  [ -n "$_file" ] && . "$_file"
}
_brief_pick_driver
