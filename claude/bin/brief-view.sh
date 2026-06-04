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
donef="$state_dir/$sid.brief.done"     # bumped by the worker when a refresh attempt finishes (even if UNCHANGED)
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

# Relative-age bucket -> sets $AGE (pure arithmetic, no fork). Coarse buckets, so
# the footer only changes at 15/30/45s, 1/2/5/10/20/30m, 1/2/3/5/10h.
agebucket() {
  local a=$1
  if   [ "$a" -lt 15 ];    then AGE="just now"
  elif [ "$a" -lt 30 ];    then AGE="15s ago"
  elif [ "$a" -lt 45 ];    then AGE="30s ago"
  elif [ "$a" -lt 60 ];    then AGE="45s ago"
  elif [ "$a" -lt 120 ];   then AGE="1m ago"
  elif [ "$a" -lt 300 ];   then AGE="2m ago"
  elif [ "$a" -lt 600 ];   then AGE="5m ago"
  elif [ "$a" -lt 1200 ];  then AGE="10m ago"
  elif [ "$a" -lt 1800 ];  then AGE="20m ago"
  elif [ "$a" -lt 2700 ];  then AGE="30m ago"
  elif [ "$a" -lt 3600 ];  then AGE="45m ago"
  elif [ "$a" -lt 7200 ];  then AGE="1h ago"
  elif [ "$a" -lt 10800 ]; then AGE="2h ago"
  elif [ "$a" -lt 18000 ]; then AGE="3h ago"
  elif [ "$a" -lt 36000 ]; then AGE="5h ago"
  else                          AGE="10h+ ago"
  fi
}

# On-demand refresh: spawn the same Haiku summarizer the Stop hook uses,
# detached, for THIS session. Resolves the transcript path the way brief-open.sh
# does. Returns non-zero (doing nothing) if no transcript exists yet.
do_refresh() {
  local tp
  tp=$(ls -t "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)
  [ -n "$tp" ] || return 1
  nohup "$HOME/.claude/hooks/task-summary-worker.sh" "$sid" "$tp" >/dev/null 2>&1 &
  return 0
}

# Print the footer line (no leading newline) from $AGE, $sk, $more, $rtail.
footer() {
  if [ "$sk" -gt 0 ]; then
    local u=updates; [ "$sk" -eq 1 ] && u=update
    printf '\033[2m— generated %s · %s %s skipped%s%s\033[0m' "$AGE" "$sk" "$u" "$more" "$rtail"
  else
    printf '\033[2m— generated %s%s%s\033[0m' "$AGE" "$more" "$rtail"
  fi
}

printf '\033]0;brief %s\007' "${sid:0:8}"    # name the pane
cols=""; rows=""
# Manual-refresh state. $rtail is the dim segment appended to the footer: a
# standing "r → refresh" hint, or a transient "⟳ refreshing…" / "✓ no change".
HINT=' · r → refresh'; rtail="$HINT"; last_rtail=""
refreshing=0; refresh_start=0; refresh_done0=0; rtail_until=0
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
      more=""; [ "$over" -gt 0 ] && more=" · +${over} below"
      sk=$(cat "$skipf" 2>/dev/null); case "$sk" in ''|*[!0-9]*) sk=0 ;; esac
      gen_epoch=$(stat -f %m "$brief" 2>/dev/null); [ -n "$gen_epoch" ] || gen_epoch=$EPOCHSECONDS
      footer_row=$(( (total < maxrows ? total : maxrows) + 1 ))   # content rows + the blank line
      agebucket $(( EPOCHSECONDS - gen_epoch )); last_age="$AGE"
      refreshing=0; rtail="$HINT"; rtail_until=0   # fresh content shown => any manual refresh is done
      printf '\n'; footer; last_rtail="$rtail"
      : > "$marker"                            # mark "rendered as of now" (builtin, no fork)
    elif [ -n "$gen_epoch" ]; then
      # No content change. Tick the relative age, reconcile manual-refresh state,
      # and reprint ONLY the footer line when something there changed. No glow.
      agebucket $(( EPOCHSECONDS - gen_epoch ))
      if [ "$refreshing" = 1 ]; then
        # An UNCHANGED refresh writes no brief, so watch the done-stamp to learn
        # the attempt finished; the timeout is a backstop if the worker died.
        dm=$(stat -f %m "$donef" 2>/dev/null || echo 0)
        if [ "$dm" != "$refresh_done0" ]; then
          refreshing=0; rtail=' · ✓ no change'; rtail_until=$(( EPOCHSECONDS + 4 ))
        elif [ "$(( EPOCHSECONDS - refresh_start ))" -gt 95 ]; then
          refreshing=0; rtail=' · ⚠ timed out'; rtail_until=$(( EPOCHSECONDS + 4 ))
        fi
      elif [ "$rtail_until" -gt 0 ] && [ "$EPOCHSECONDS" -ge "$rtail_until" ]; then
        rtail="$HINT"; rtail_until=0                 # transient message expired -> back to hint
      fi
      if [ "$AGE" != "$last_age" ] || [ "$rtail" != "$last_rtail" ]; then
        tput cup "$footer_row" 0 2>/dev/null; footer; tput el 2>/dev/null
        last_age="$AGE"; last_rtail="$rtail"
      fi
    fi
  elif [ "$redraw" = 1 ]; then
    { tput clear 2>/dev/null || printf '\033[H\033[2J'; }
    printf 'No brief yet for %s.\nIt appears after the next completed turn.' "${sid:0:8}"
  fi
  # Idle pacing AND input in one wait: up to 0.5s for a keypress (the poll
  # interval) — 'r' forces a refresh now, 'q' closes the dock. Fractional -t
  # needs bash 4+, already required here ($EPOCHSECONDS is bash 5+).
  read -rsn1 -t 0.5 key || key=""
  case "$key" in
    r|R)
      if [ "$refreshing" = 0 ]; then
        refresh_done0=$(stat -f %m "$donef" 2>/dev/null || echo 0)
        if do_refresh; then
          refreshing=1; refresh_start=$EPOCHSECONDS; rtail=' · ⟳ refreshing…'
        else
          rtail=' · ⚠ no transcript'; rtail_until=$(( EPOCHSECONDS + 4 ))
        fi
        # paint the indicator now, don't wait for the next age tick
        if [ -n "$gen_epoch" ]; then
          tput cup "$footer_row" 0 2>/dev/null; footer; tput el 2>/dev/null; last_rtail="$rtail"
        fi
      fi
      ;;
    q|Q) exit 0 ;;
  esac
done
