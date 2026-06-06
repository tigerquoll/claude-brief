#!/usr/bin/env bash
# Pluggable terminal "driver" layer for the brief dock. This file is SOURCED (not
# executed) by brief-open.sh and the prompt/session-end hooks. It picks ONE
# backend — by an explicit $BRIEF_TERMINAL name, else by auto-detection (the inner
# multiplexer wins) — and sources it, so exactly one definition of each tdrv_*
# function is in scope afterwards.
#
# Each backend (bin/term/{common,<os>}/<name>.sh) defines:
#   tdrv_name                    -> echoes the driver's short name (iterm2/tmux/…)
#   tdrv_detect                  -> returns 0 if it recognises the CURRENT terminal;
#                                   THIS is auto-detection (see _brief_detect). A pure
#                                   fallback (generic) omits it and never matches.
#   tdrv_self_pane               -> the current pane's native id, already
#                                   filesystem-safe and usable as that driver's
#                                   split anchor; empty if the terminal has none
#   tdrv_open MODE ANCHOR CMD…   -> create the dock (MODE=dock|float) beside
#                                   ANCHOR, run CMD…, echo the new dock pane/window
#                                   id on stdout (empty on failure); human hints
#                                   go to stderr
#   tdrv_close PANEID            -> close that dock pane/window (validates the id)
# and MAY define tdrv_rank -> detection precedence 0-99 (default 50); a multiplexer
# (tmux) uses a higher rank so an INNER MULTIPLEXER WINS over the host terminal.
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

# Auto-detect the driver — the SINGLE detection mechanism. Each driver owns its own
# recognition in tdrv_detect(); this probes them and the HIGHEST-RANKED match wins
# (tdrv_rank default 50; tmux's 90 makes the inner multiplexer beat the host terminal
# whose env vars are also visible inside a tmux pane). We scan term/<os>/ then
# term/common/ (an <os>/ driver shadows the common one of the same name) and NEVER the
# other OS's dir, so wrong-OS drivers are never even sourced. 'generic' if nothing
# matches. Each candidate is sourced in a SUBSHELL so it can't disturb the probe. So
# adding a terminal — built-in or third-party — needs NO edit to this file. 3.2-safe.
_brief_detect() {
  _best=generic _bestrank=-1 _seen=" "
  for _d in "$_BRIEF_TERM_DIR/$_BRIEF_OS" "$_BRIEF_TERM_DIR/common"; do
    [ -d "$_d" ] || continue
    for _f in "$_d"/*.sh; do
      [ -f "$_f" ] || continue
      _bn=${_f##*/}; _bn=${_bn%.sh}
      case "$_seen" in *" $_bn "*) continue ;; esac   # an <os>/ driver shadows the common one
      _seen="$_seen$_bn "
      _cand=$(
        . "$_f" >/dev/null 2>&1 || exit 0
        command -v tdrv_detect >/dev/null 2>&1 || exit 0
        tdrv_detect >/dev/null 2>&1 || exit 0
        _r=50; command -v tdrv_rank >/dev/null 2>&1 && _r=$(tdrv_rank 2>/dev/null)
        printf '%s %s' "${_r:-50}" "$(tdrv_name 2>/dev/null)"
      )
      [ -n "$_cand" ] || continue
      _r=${_cand%% *} _nm=${_cand#* }
      case "$_r"  in ''|*[!0-9]*) _r=50 ;; esac
      case "$_nm" in ''|*[!a-z0-9]*) continue ;; esac
      [ "$_r" -gt "$_bestrank" ] && { _best=$_nm _bestrank=$_r; }
    done
  done
  printf '%s' "$_best"
}

_brief_pick_driver() {
  _n="${BRIEF_TERMINAL:-auto}"
  case "$_n" in auto|'') _n=$(_brief_detect) ;; esac
  # Name whitelist: lowercase alnum only. Anything else (a path, traversal, empty,
  # unknown) collapses to generic and can never resolve outside term/.
  case "$_n" in *[!a-z0-9]*|'') _n=generic ;; esac
  # Resolve to a real file (OS-specific > common); a name with no driver for THIS OS
  # (e.g. ghostty on Linux, before a linux/ghostty.sh exists) falls back to generic.
  _file=$(_brief_driver_file "$_n"); [ -n "$_file" ] || _file=$(_brief_driver_file generic)
  [ -n "$_file" ] && . "$_file"
}
_brief_pick_driver
