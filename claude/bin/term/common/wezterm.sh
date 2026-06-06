# wezterm driver. Drives WezTerm's CLI (`wezterm cli`), which talks to the running
# GUI's multiplexer over a unix socket — NO controlling tty needed and NO config to
# enable (the mux is always on), so /brief's tty-less Bash context works out of the
# box. This is the EASY case next to kitty (which needs `listen_on` + a restart): the
# socket is found via $WEZTERM_UNIX_SOCKET, exported by WezTerm into every pane, so
# Claude Code — and thus brief-open — inherit it automatically. Verified end-to-end
# (split/render/close, headless, no tty) on wezterm 20240203. Sourced by
# terminal-driver.sh — bash-3.2-safe.
#
# STYLING LIMITATION — no per-pane profiles. WezTerm has ONE global config: no
# per-pane font / colorscheme / line-spacing, and the CLI's split-pane/spawn has no
# --config/--font flag. So the dock CANNOT be given a distinct `brief` look the way
# iTerm2/Apple Terminal can (only those two get a dedicated profile). The lone lever
# is GLOBAL — `config.line_height = 1.2` in ~/.wezterm.lua — which also widens the
# session pane. (A gui-startup Lua `set_config_overrides` event could special-case
# the dock per-WINDOW, but not per-pane, and it's fiddly — not pursued.) Same class
# as tmux/kitty/ghostty; $BRIEF_PROFILE does not apply.

tdrv_name(){ printf 'wezterm'; }
tdrv_detect(){ [ "${TERM_PROGRAM:-}" = WezTerm ] || [ -n "${WEZTERM_PANE:-}" ]; }

# $WEZTERM_PANE is the current pane's integer id, exported per-pane by WezTerm — so
# the prompt hook (which runs inside the session's pane) and /brief's bash compute
# the same pane->sid map key, and it doubles as the split anchor (--pane-id).
tdrv_self_pane(){ printf '%s' "${WEZTERM_PANE:-}"; }

# tdrv_open MODE ANCHOR CMD…  -> echo the new pane id (integer)
# dock  = `split-pane --right` (side-by-side, vertical divider); float = `spawn
# --new-window`. Both print the new pane id on stdout. CMD is run DIRECTLY (no
# shell), so it must be an absolute path.
#
# PATH: WezTerm has no per-spawn --env flag, and a GUI-launched (Dock/Spotlight)
# WezTerm runs its mux with a minimal PATH — the same bash-5/glow trap kitty and
# ghostty hit (a mux started from a shell carries the rich PATH, but we can't rely
# on how it was launched). So wrap CMD in `/usr/bin/env PATH="$PATH" …`: the
# absolute /usr/bin/env resolves under any PATH, then runs the absolute viewer with
# the caller's full interactive PATH so its `#!/usr/bin/env bash` finds bash 5.
#
# FOCUS: split-pane/spawn FOCUS the new pane, which would route the user's keystrokes
# into the dock viewer (r/a/i/q…); so after a successful open we activate-pane back
# to the anchor, keeping focus on the session like the tmux/kitty drivers do.
tdrv_open(){
  _mode=$1 _anchor=$2; shift 2
  _err="${TMPDIR:-/tmp}/brief-wezterm.$$"
  if [ "$_mode" = float ]; then
    _id=$(wezterm cli spawn --new-window -- /usr/bin/env PATH="$PATH" "$@" 2>"$_err")
  elif [ -n "$_anchor" ]; then
    _id=$(wezterm cli split-pane --right --pane-id "$_anchor" -- /usr/bin/env PATH="$PATH" "$@" 2>"$_err")
  else
    _id=$(wezterm cli split-pane --right -- /usr/bin/env PATH="$PATH" "$@" 2>"$_err")
  fi
  _id=$(printf '%s' "$_id" | tr -dc '0-9')   # the bare integer id only
  if [ -n "$_id" ]; then
    [ -n "$_anchor" ] && wezterm cli activate-pane --pane-id "$_anchor" 2>/dev/null
  else
    {
      printf 'brief: wezterm dock could not open — is this a running WezTerm GUI with\n'
      printf '       its CLI reachable ($WEZTERM_UNIX_SOCKET)? No kitty/listen_on-style\n'
      printf '       setup is needed; the mux is on by default.\n'
      _msg=$(tr '\n' ' ' <"$_err" 2>/dev/null)
      [ -n "$_msg" ] && printf '       [wezterm said: %s]\n' "$_msg"
    } >&2
  fi
  rm -f "$_err" 2>/dev/null
  printf '%s' "$_id"
}

# kill-pane removes the pane (and its window if it was the last one), terminating the
# viewer regardless of its traps — no husk, no confirm prompt. Integer id only.
tdrv_close(){
  _id=$1; [ -n "$_id" ] || return 0
  case "$_id" in *[!0-9]*) return 0 ;; esac   # integer id only
  wezterm cli kill-pane --pane-id "$_id" 2>/dev/null || true
}
