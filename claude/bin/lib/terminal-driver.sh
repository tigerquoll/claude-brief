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

# Auto-detect a DROP-IN driver — the extension point for porters / custom terminals.
# Any term/<name>.sh that defines tdrv_detect() (returns 0 when it recognises the
# current terminal) is picked up here with NO edit to this file. An optional
# tdrv_priority() (a 0-99 number, default 0; highest wins) breaks ties between
# several matching drop-ins. The built-in chain below is consulted FIRST (so the
# shipped drivers keep their exact, tested precedence — incl. inner-mux-wins); this
# only runs when none of them claimed the terminal, and returns 'generic' if no
# drop-in claims it either. Each candidate is sourced in a SUBSHELL so probing can't
# disturb the real load. Built-in drivers define no tdrv_detect, so they're skipped
# here harmlessly. Kept bash-3.2-safe.
_brief_autodetect_extra() {
  _best=generic _bestpri=-1
  for _f in "$_BRIEF_TERM_DIR"/*.sh; do
    [ -f "$_f" ] || continue
    _cand=$(
      . "$_f" >/dev/null 2>&1 || exit 0
      command -v tdrv_detect >/dev/null 2>&1 || exit 0
      tdrv_detect >/dev/null 2>&1 || exit 0
      _p=0; command -v tdrv_priority >/dev/null 2>&1 && _p=$(tdrv_priority 2>/dev/null)
      printf '%s %s' "${_p:-0}" "$(tdrv_name 2>/dev/null)"
    )
    [ -n "$_cand" ] || continue
    _pri=${_cand%% *} _nm=${_cand#* }
    case "$_pri" in ''|*[!0-9]*) _pri=0 ;; esac
    case "$_nm"  in ''|*[!a-z0-9]*) continue ;; esac
    [ "$_pri" -gt "$_bestpri" ] && { _best=$_nm _bestpri=$_pri; }
  done
  printf '%s' "$_best"
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
  # unknown) collapses to generic and can never source outside term/.
  case "$_n" in *[!a-z0-9]*|'') _n=generic ;; esac
  [ -f "$_BRIEF_TERM_DIR/$_n.sh" ] || _n=generic
  . "$_BRIEF_TERM_DIR/$_n.sh"
}
_brief_pick_driver
