# tmux driver. Works on macOS + Linux, no AppleScript. The dock is a real split;
# closing the session kills the pane. Sourced by terminal-driver.sh — bash-3.2-safe.
#
# Host-terminal-agnostic: tmux draws its own panes inside whatever host terminal it
# runs in (Apple Terminal, iTerm2, kitty, …), so the driver behaves identically
# regardless of host — detection makes the inner multiplexer win ($TMUX => tmux,
# ahead of the host). MAIN DISADVANTAGE vs the iTerm2/Apple-Terminal drivers: tmux
# has no per-pane font control (every pane shares the host terminal's one font), so
# the dock CANNOT have a different font size / line spacing from the session — it
# just inherits the host font, and $BRIEF_PROFILE does not apply.

tdrv_name(){ printf 'tmux'; }

# $TMUX_PANE is the current pane id (form %N) — fs-safe and usable as a -t anchor.
# Set per-pane by tmux, so the prompt hook (which runs inside the session's pane)
# and /brief's bash compute the same pane->sid map key.
tdrv_self_pane(){ printf '%s' "${TMUX_PANE:-}"; }

# tdrv_open MODE ANCHOR CMD…  -> echo the new pane id (%N)
# -h = side-by-side (split along a horizontal axis -> vertical divider), -d = keep
# focus on the session pane, -P -F prints the new pane id. float has no stock-tmux
# equivalent (display-popup is transient), so it's a background new-window.
#
# The command is passed as MULTIPLE args, so tmux execvp's it DIRECTLY (no /bin/sh,
# no quoting pitfalls) — hence CMD must be an absolute path (direct exec does no
# PATH search for the command itself). The new pane inherits the environment of the
# CLIENT that runs split-window — i.e. brief-open, launched from the session's own
# shell — NOT the tmux server's env. So it carries the full interactive PATH, and
# that is how the bash-5 viewer (#!/usr/bin/env bash) + glow + claude are resolved
# even when the server was started from a minimal GUI/login PATH. (Verified on tmux
# 3.6: a `-e PATH=…` does NOT override the inherited client PATH, so it's neither
# used nor needed here.)
tdrv_open(){
  _mode=$1 _anchor=$2; shift 2
  if [ "$_mode" = float ]; then
    tmux new-window -d -P -F '#{pane_id}' "$@" 2>/dev/null
  elif [ -n "$_anchor" ]; then
    tmux split-window -h -d -P -F '#{pane_id}' -t "$_anchor" "$@" 2>/dev/null
  else
    tmux split-window -h -d -P -F '#{pane_id}' "$@" 2>/dev/null
  fi
}

# kill-pane is clean: it removes the pane (and its window if it was the last pane),
# terminating the viewer regardless of its signal traps — no husk, no confirm
# prompt (the easy case next to ghostty/Apple Terminal). The id is %N-shaped only.
tdrv_close(){
  _id=$1; [ -n "$_id" ] || return 0
  case "$_id" in *[!%0-9]*) return 0 ;; esac   # %N only
  tmux kill-pane -t "$_id" 2>/dev/null || true
}
