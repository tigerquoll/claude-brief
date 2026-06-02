#!/usr/bin/env bash
# Live viewer for a session brief, run inside the docked iTerm2 pane that
# /brief opens. Redraws ONLY when the brief changes (fork-free `-nt` test) or
# the width changes; the idle loop forks just `tput`+`sleep`. Paints on the ALT
# SCREEN buffer (like top/less) so a brief that fits the pane shows no scroll bar.
#   usage: brief-view.sh <session-id>
sid="$1"
[ -z "$sid" ] && { echo "brief-view: no session id given"; exit 1; }
case "$sid" in *[!0-9a-fA-F-]*) echo "brief-view: invalid (non-UUID) session id"; exit 1 ;; esac

state_dir="$HOME/.claude/state"
brief="$state_dir/$sid.brief.md"
pidf="$state_dir/$sid.brief.pid"
marker="$state_dir/$sid.brief.seen"   # mtime bumped after each render -> fork-free change detect
skipf="$state_dir/$sid.skipped"        # trivial-turn skip counter (written by the Stop hook)
echo $$ > "$pidf"

cleanup() { tput rmcup 2>/dev/null; tput cnorm 2>/dev/null; rm -f "$pidf" "$marker"; exit 0; }
trap cleanup INT TERM EXIT
tput smcup 2>/dev/null   # enter alternate screen (no scrollback => no scroll bar)
tput civis 2>/dev/null   # hide cursor for a clean dashboard look
unset COLUMNS LINES      # else tput honors a stale inherited COLUMNS and never sees resizes

# Post-process glow output into indent levels: headings at col 2, bullets nested
# at col 4, wrapped continuations deeper (col 8 under a bullet, col 4 under a
# heading); plus a dimmed bullet glyph and blank-line runs collapsed to one.
# Leading spaces don't disturb glow's embedded ANSI, so this is safe.
_ifmt() {
  perl -CSDA -ne '
    chomp;
    if (/^\s*$/)                { print "\n" unless $pb; $pb=1; $ind=0; next }
    $pb=0;
    if (/^\x{2022} (.*)$/)      { $ind=8; print "    \e[90m\x{2022}\e[0m $1\n"; next }  # bullet @col4, cont @8
    if (/^[\x{25b8}\x{258c}] /) { $ind=4; print "  $_\n"; next }                        # ▸/▌ heading @col2, cont @4
    if (/^  \S/)                { $ind=4; print "  $_\n"; next }                         # h3
    if ($ind)                   { print " " x $ind, "$_\n"; next }                       # wrapped continuation
    print "  $_\n";
  '
}

render() {
  local W wrapw gs
  W=${cols:-80}                               # full pane width (cached $cols) — fills the pane, reflows on resize
  wrapw=$(( W - 8 ))                          # room for the deepest indent (8-col continuation hang)
  [ "$wrapw" -lt 20 ] && wrapw=20
  if command -v glow >/dev/null 2>&1; then
    # glow word-wraps at wrapw (breaks at spaces -> identifiers stay whole); _ifmt
    # adds the gutter/hang indent. render() re-runs on resize, so it reflows.
    gs="$HOME/.claude/glow-brief.json"
    # CLICOLOR_FORCE: glow strips color when its stdout is a pipe (it is -> _ifmt)
    # </dev/null so glow never blocks reading stdin (it does when stdin is a pipe)
    if [ -f "$gs" ]; then CLICOLOR_FORCE=1 glow -s "$gs" -w "$wrapw" "$brief" </dev/null | _ifmt
    else CLICOLOR_FORCE=1 glow -w "$wrapw" "$brief" </dev/null | _ifmt; fi
  elif command -v bat >/dev/null 2>&1; then
    bat --style=plain --color=always --paging=never -l md "$brief"
  else
    # No renderer installed — light ANSI styling so it still reads well.
    local B C R; B=$'\033[1m'; C=$'\033[36m'; R=$'\033[0m'
    sed -E \
      -e "s/^# (.+)/${B}${C}\1${R}/" \
      -e "s/^#{2,6} (.+)/${B}\1${R}/" \
      -e "s/^([[:space:]]*)[-*] (.+)/\1${C}•${R} \2/" \
      -e "s/\*\*([^*]+)\*\*/${B}\1${R}/g" \
      "$brief"
  fi
}

printf '\033]0;brief %s\007' "${sid:0:8}"    # name the pane
cols=""; rows=""
while :; do
  redraw=0
  # Poll the LIVE pane size every tick. stty does a direct TIOCGWINSZ ioctl, so
  # it sees resizes immediately and ignores any stale COLUMNS env that makes
  # tput lie. tput is the fallback if stdin isn't the tty. Reflows on W or H change.
  sz=$(stty size 2>/dev/null); r=${sz%% *}; c=${sz##* }
  [ "$c" -gt 0 ] 2>/dev/null || c=$(tput cols 2>/dev/null || echo 80)
  [ "$r" -gt 0 ] 2>/dev/null || r=$(tput lines 2>/dev/null || echo 40)
  if [ "$c" != "$cols" ] || [ "$r" != "$rows" ]; then cols="$c"; rows="$r"; redraw=1; fi
  if [ -f "$brief" ]; then
    [[ "$brief" -nt "$marker" ]] && redraw=1   # fork-free change detection (replaces stat)
    [[ "$skipf" -nt "$marker" ]] && redraw=1   # also repaint when the skip counter changes
    if [ "$redraw" = 1 ]; then
      # Full wipe, then render CLIPPED to the pane height: keeps the TOP (title/
      # state) visible and stops content scrolling off the top of the alt screen
      # on a short/narrow pane. clear() adds no scrollback on the alt screen.
      maxrows=$(( rows - 2 )); [ "$maxrows" -lt 3 ] && maxrows=3
      { tput clear 2>/dev/null || printf '\033[H\033[2J'; }
      out=$(render 2>/dev/null)
      total=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
      printf '%s\n' "$out" | head -n "$maxrows"
      over=$(( total - maxrows )); [ "$over" -lt 0 ] && over=0
      gen=$(stat -f '%Sm' -t '%H:%M:%S' "$brief" 2>/dev/null)
      sk=$(cat "$skipf" 2>/dev/null); case "$sk" in ''|*[!0-9]*) sk=0 ;; esac
      more=""; [ "$over" -gt 0 ] && more=" · +${over} below"
      if [ "$sk" -gt 0 ]; then
        u=updates; [ "$sk" -eq 1 ] && u=update
        printf '\n\033[2m— %s %s skipped since generated %s%s\033[0m' "$sk" "$u" "${gen:-?}" "$more"
      else
        printf '\n\033[2m— generated %s · live%s\033[0m' "${gen:-?}" "$more"
      fi
      : > "$marker"                            # mark "rendered as of now" (builtin, no fork)
    fi
  elif [ "$redraw" = 1 ]; then
    { tput clear 2>/dev/null || printf '\033[H\033[2J'; }
    printf 'No brief yet for %s.\nIt appears after the next completed turn.' "${sid:0:8}"
  fi
  sleep 0.5                                    # the one fork per idle tick
done
