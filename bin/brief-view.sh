#!/usr/bin/env bash
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"   # plugin root (or ~/.claude when installed)
# Live viewer for a session brief, run inside the docked pane that /brief opens
# (terminal-agnostic — the dock is created by the pluggable driver layer). Full-
# redraws only when the brief changes (fork-free `-nt` test)
# or the pane is resized; otherwise just reprints the footer line. The loop polls
# ~2x/s via `read -t`, which doubles as the keypress reader (r/a/i/+/-/?/q).
# Paints on the ALT SCREEN buffer (like top/less) so a brief that fits the pane
# shows no scroll bar.
#   usage: brief-view.sh <session-id>
# The live viewer uses bash-5 features ($EPOCHSECONDS for timing); macOS ships 3.2.
# A viewer launched under the wrong bash would silently mistime rather than fail —
# so check up front and show a fix instead. (Kept above any bash-4+ syntax so 3.2
# reaches it.)
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ]; then
  printf '\n  claude-brief: the dock viewer needs bash >= 5 (this is bash %s).\n' "${BASH_VERSION%%(*}"
  if command -v brew >/dev/null 2>&1; then bfix='brew install bash'; else bfix='see https://brew.sh'; fi
  printf '  Fix:  install bash >= 5  (%s)  then reopen  /claude-brief:brief\n\n' "$bfix"
  printf '  (press any key to close this pane) '
  read -rn1 _ 2>/dev/null || read -r _ 2>/dev/null
  exit 0
fi
sid="$1"
[ -z "$sid" ] && { echo "brief-view: no session id given"; exit 1; }
case "$sid" in *[!0-9a-fA-F-]*) echo "brief-view: invalid (non-UUID) session id"; exit 1 ;; esac
. "$ROOT/bin/lib/portable.sh"   # _mtime/_perm (portable BSD/GNU stat)

state_dir="$HOME/.claude/state"
brief="$state_dir/$sid.brief.md"
pidf="$state_dir/$sid.brief.pid"
marker="$state_dir/$sid.brief.seen"   # mtime bumped after each render -> fork-free change detect
skipf="$state_dir/$sid.skipped"        # trivial-turn skip counter (written by the Stop hook)
donef="$state_dir/$sid.brief.done"     # outcome word the worker writes at the end of each attempt: updated/unchanged/timeout/error
sizef="$state_dir/$sid.brief.size"     # viewer publishes "rows cols" here so the summariser can size the brief to the pane
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
    gs="$ROOT/glow-brief.json"
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
# the footer only changes at 15/30/45s, 1/2/5/10/20/30/45m, 1/2/3/5/10h.
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
# detached, for THIS session. Uses the cached transcript path ($tp, resolved at
# startup the way brief-open.sh does; re-resolved here if it went missing).
# Returns non-zero (doing nothing) if no transcript exists yet.
do_refresh() {
  [ -n "$tp" ] || tp=$(ls -t "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)
  [ -n "$tp" ] || return 1
  nohup "$ROOT/hooks/task-summary-worker.sh" "$sid" "$tp" >/dev/null 2>&1 &
  return 0
}

# Kick off a refresh and arm the in-flight state: spawn the worker and mark
# $refreshing. The loop's done-stamp watcher (which tracks $done_mt) detects when
# the attempt finishes and with what outcome. Returns non-zero if nothing started
# (no transcript). Used by both the 'r' key and interval refresh.
begin_refresh() {
  do_refresh || return 1
  refreshing=1; refresh_start=$EPOCHSECONDS; spin=0; spinframe=${SPIN[0]}; rtail=""
}

# Reprint ONLY the footer line in place (no glow, no full redraw). Safe to call
# any time after the first render has set $footer_row/$gen_epoch.
repaint_footer() {
  [ -n "$gen_epoch" ] || return 0
  tput cup "$footer_row" 0 2>/dev/null; footer; tput el 2>/dev/null
  last_rtail="$rtail"; last_spin="$spinframe"
}

# Print the footer line. Normally a dim "— generated <age> …" line; while a
# refresh is in flight ($spinframe set) it LEADS with an animated spinner (dim
# grey, like the rest — the motion + leading position carry the signal), and the
# age reads "previously generated <age>" since the shown content is the prior gen.
# Builds the body with printf -v (no subshell) since this can repaint every tick.
footer() {
  local body u=updates
  [ "$sk" -eq 1 ] && u=update
  if [ "$sk" -gt 0 ]; then
    printf -v body '%s · %s %s skipped%s%s' "$AGE" "$sk" "$u" "$more" "$rtail"
  else
    printf -v body '%s%s%s' "$AGE" "$more" "$rtail"
  fi
  if [ -n "$spinframe" ]; then
    printf '\033[2m%s updating… · previously generated %s\033[0m' "$spinframe" "$body"
  else
    printf '\033[2m— generated %s\033[0m' "$body"
  fi
}

printf '\033]0;brief %s\007' "${sid:0:8}"    # name the pane
cols=""; rows=""
tp=$(ls -t "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)   # transcript, cached
# Two independent refresh modes, shown in the footer and toggled by keys:
#   auto     — refresh at the END OF EACH TURN (the Stop hook's default). Toggling
#              it OFF (key 'a') drops a <sid>.brief.noauto flag the Stop hook
#              honors, so the brief then updates ON DEMAND only. Persisted (file).
#   interval — refresh PERIODICALLY DURING a long turn (key 'i', default OFF; +/-
#              set the period). Fires only when the transcript advanced since the
#              last attempt, so an idle session never spends. In-memory.
# $rtail is the dim footer tail: the standing hint (set_hint) or a transient
# status ("✓ no change" / "⚠ summary failed"). An in-flight refresh instead shows
# the animated $spinframe LEADING the line (dim grey) — see footer().
noautof="$state_dir/$sid.brief.noauto"
auto=1; [ -f "$noautof" ] && auto=0      # end-of-turn refresh; default ON, OFF persisted by the flag
intv=0; last_intv=0                       # periodic during-turn refresh; default OFF
fmt_int() { local s=$1   # seconds -> 30s / 5m / 1h
  if   [ "$s" -lt 60 ];   then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%dm' "$(( s / 60 ))"
  else                         printf '%dh' "$(( s / 3600 ))"; fi
}
LADDER=(30 60 120 300 600 1200 1800 3600)      # +/- step the interval through these
intv_int=${BRIEF_INTERVAL:-300}; case "$intv_int" in ''|*[!0-9]*) intv_int=300 ;; esac
intv_idx=3; best=2147483647                     # snap the configured interval to the nearest step
for i in "${!LADDER[@]}"; do
  v=${LADDER[i]}; d=$(( v > intv_int ? v - intv_int : intv_int - v ))
  [ "$d" -lt "$best" ] && { best=$d; intv_idx=$i; }
done
intv_int=${LADDER[intv_idx]}; intv_label=$(fmt_int "$intv_int")
refreshing=0; refresh_start=0; rtail_until=0
# shellcheck disable=SC1003  # '\' is a literal backslash spinner frame, not an escape
SPIN=('|' '/' '-' '\'); spin=0; spinframe=""; last_spin=""   # in-flight spinner (rotating bar): leads the footer, animated while refreshing
done_mt=$(_mtime "$donef")   # last-seen done-stamp mtime (outcome watcher)
REFRESH_TIMEOUT=95   # viewer backstop for a stuck refresh (the worker's own 90s watchdog + margin)
MSG_SECS=4           # how long a transient footer message lingers before reverting to the hint
HELP_SECS=6          # how long the '?' cheatsheet shows
set_hint() {   # standing footer hint, reflecting both modes
  local as='auto off' is='interval off'
  [ "$auto" = 1 ] && as='auto on'
  [ "$intv" = 1 ] && is="interval ${intv_label}"
  HINT=" · ${as} · ${is} · ?"
}
# Move the interval one rung along $LADDER ($1 = +1 / -1), clamped, and show it.
step_interval() {
  local n=$(( intv_idx + $1 ))
  [ "$n" -ge 0 ] && [ "$n" -lt "${#LADDER[@]}" ] && intv_idx=$n
  intv_int=${LADDER[intv_idx]}; intv_label=$(fmt_int "$intv_int"); set_hint
  rtail=" · interval ${intv_label}"; [ "$intv" = 0 ] && rtail="${rtail} (off)"
  rtail_until=$(( EPOCHSECONDS + MSG_SECS )); repaint_footer
}
set_hint; rtail="$HINT"; last_rtail=""
# Timing below uses $EPOCHSECONDS (the reason for the bash-5 requirement), NOT
# $(date +%s): it's a dynamic var returning time(0) in-process (vDSO/commpage
# read, no kernel trap, no fork) — `date` would fork+exec every 0.5s tick. Don't
# "simplify" it to `date`.
while :; do
  redraw=0
  # Poll the LIVE pane size every tick. stty does a direct TIOCGWINSZ ioctl, so it
  # sees resizes immediately and ignores any stale COLUMNS env that makes tput lie.
  # tput is the fallback if stty gave nothing. Reflows on a real W/H change.
  sz=$(stty size 2>/dev/null); r=${sz%% *}; c=${sz##* }
  case "$c" in ''|*[!0-9]*) c=$(tput cols  2>/dev/null) ;; esac
  case "$r" in ''|*[!0-9]*) r=$(tput lines 2>/dev/null) ;; esac
  case "$c" in ''|*[!0-9]*) c= ;; esac; case "$r" in ''|*[!0-9]*) r= ;; esac
  # If we couldn't read a VALID size this tick (transient stty/tput failure), keep
  # the cached size — never redraw on a bad read (that caused spurious resize
  # redraws). 80x40 only at bootstrap, when there's no cached size yet.
  if [ -z "$c" ] || [ -z "$r" ]; then
    if [ -z "$cols" ]; then c=80; r=40; else c=$cols; r=$rows; fi
  fi
  if [ "$c" != "$cols" ] || [ "$r" != "$rows" ]; then
    cols="$c"; rows="$r"; redraw=1
    printf '%s %s\n' "$rows" "$cols" > "$sizef"   # publish pane size for the summariser to fit the next brief to
  fi
  if [ -f "$brief" ]; then
    [[ "$brief" -nt "$marker" ]] && redraw=1   # brief CONTENT changed -> full re-render (fork-free -nt)
    # NOTE: a .skipped change is handled as a footer-only reprint below — it must
    # NOT force a full md re-render (that caused a spurious second redraw per turn).
    if [ "$redraw" = 1 ]; then
      # Full wipe, then render CLIPPED to the pane height: keeps the TOP (title/
      # state) visible. The summariser sizes the brief to the pane (see $sizef), so
      # overflow is rare — "+N below" is just a backstop. No scrollback on alt screen.
      maxrows=$(( rows - 2 )); [ "$maxrows" -lt 3 ] && maxrows=3
      { tput clear 2>/dev/null || printf '\033[H\033[2J'; }
      out=$(render 2>/dev/null)
      total=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
      printf '%s\n' "$out" | head -n "$maxrows"
      over=$(( total - maxrows )); [ "$over" -lt 0 ] && over=0
      more=""; [ "$over" -gt 0 ] && more=" · +${over} below"
      sk=$(cat "$skipf" 2>/dev/null); case "$sk" in ''|*[!0-9]*) sk=0 ;; esac
      gen_epoch=$(_mtime "$brief"); [ "$gen_epoch" = 0 ] && gen_epoch=$EPOCHSECONDS
      footer_row=$(( (total < maxrows ? total : maxrows) + 1 ))   # content rows + the blank line
      agebucket $(( EPOCHSECONDS - gen_epoch )); last_age="$AGE"
      refreshing=0; spinframe=""; rtail="$HINT"; rtail_until=0   # fresh content shown => any in-flight refresh is done
      last_intv=$EPOCHSECONDS   # a refresh just landed -> reset interval timer so it can't re-fire right on top (the double redraw)
      printf '\n'; footer; last_rtail="$rtail"; last_spin="$spinframe"
      : > "$marker"                            # mark "rendered as of now" (builtin, no fork)
    elif [ -n "$gen_epoch" ]; then
      # No content change. Tick the relative age, reconcile in-flight refresh
      # state, and reprint ONLY the footer line when something changed. No glow.
      agebucket $(( EPOCHSECONDS - gen_epoch ))
      [ "$refreshing" = 1 ] && { spin=$(( (spin + 1) % ${#SPIN[@]} )); spinframe=${SPIN[spin]}; }   # animate the in-flight spinner
      # Done-stamp watcher: the worker writes an OUTCOME word there at the end of
      # every attempt — ours (r/interval) or the auto end-of-turn one — so a
      # failure surfaces instead of masquerading as "no change". 'updated' means
      # the brief changed and the redraw above already showed it; 'no change' is
      # only worth announcing when WE asked for the refresh.
      dm=$(_mtime "$donef")
      if [ "$dm" != "$done_mt" ]; then
        done_mt=$dm; was_ours=$refreshing; refreshing=0; spinframe=""; last_intv=$EPOCHSECONDS   # any completed refresh (incl. UNCHANGED) resets the interval timer
        case "$(cat "$donef" 2>/dev/null)" in
          timeout)   rtail=' · ⚠ summary timed out'; rtail_until=$(( EPOCHSECONDS + MSG_SECS )) ;;
          error)     rtail=' · ⚠ summary failed';    rtail_until=$(( EPOCHSECONDS + MSG_SECS )) ;;
          unchanged) [ "$was_ours" = 1 ] && { rtail=' · ✓ no change'; rtail_until=$(( EPOCHSECONDS + MSG_SECS )); } ;;
          *)         : ;;   # updated/unknown -> the content redraw speaks for itself
        esac
      elif [ "$refreshing" = 1 ] && [ "$(( EPOCHSECONDS - refresh_start ))" -gt "$REFRESH_TIMEOUT" ]; then
        refreshing=0; spinframe=""; rtail=' · ⚠ no response'; rtail_until=$(( EPOCHSECONDS + MSG_SECS ))   # worker never reported back
      elif [ "$rtail_until" -gt 0 ] && [ "$EPOCHSECONDS" -ge "$rtail_until" ]; then
        rtail="$HINT"; rtail_until=0                 # transient message expired -> back to hint
      fi
      if [[ "$skipf" -nt "$marker" ]]; then          # skip count is a FOOTER field -> reprint footer, NOT a full md re-render
        sk=$(cat "$skipf" 2>/dev/null); case "$sk" in ''|*[!0-9]*) sk=0 ;; esac
        : > "$marker"                                # mark skipf seen (fork-free) so it won't re-fire
        repaint_footer
      fi
      if [ "$AGE" != "$last_age" ] || [ "$rtail" != "$last_rtail" ] || [ "$spinframe" != "$last_spin" ]; then
        repaint_footer; last_age="$AGE"   # repaint_footer also sets last_rtail/last_spin
      fi
    fi
  elif [ "$redraw" = 1 ]; then
    { tput clear 2>/dev/null || printf '\033[H\033[2J'; }
    printf 'No brief yet for %s.\nIt appears after the next completed turn.' "${sid:0:8}"
  fi
  # Interval refresh: while ON, re-run the summarizer every $intv_int seconds —
  # but only if the transcript advanced since the last attempt (fork-free -nt
  # test), so an idle session never spends. last_intv advances even when we skip,
  # so we re-check at most once per interval.
  if [ "$intv" = 1 ] && [ "$refreshing" = 0 ] && [ "$(( EPOCHSECONDS - last_intv ))" -ge "$intv_int" ]; then
    last_intv=$EPOCHSECONDS
    if [ -n "$tp" ] && [[ "$tp" -nt "$donef" ]] && begin_refresh; then
      repaint_footer   # begin_refresh armed the leading spinner
    fi
  fi
  # Idle pacing AND input in one wait: 0.5s normally, 0.2s while a refresh is in
  # flight so the spinner animates at ~5 frames/s (it advances one frame per tick).
  # r refresh · a auto · i interval · +/- period · ? help · q quit. Fractional -t
  # needs bash 4+ (already required here: $EPOCHSECONDS is bash 5+).
  poll=0.5; [ "$refreshing" = 1 ] && poll=0.2
  read -rsn1 -t "$poll" key || key=""
  case "$key" in
    r|R)
      if [ "$refreshing" = 0 ]; then
        begin_refresh || { rtail=' · ⚠ no transcript'; rtail_until=$(( EPOCHSECONDS + MSG_SECS )); }
        repaint_footer   # show the spinner (or the error) now, don't wait for the next tick
      fi
      ;;
    a|A)       # toggle auto = refresh at the end of each turn (persisted via the noauto flag)
      if [ "$auto" = 1 ]; then
        auto=0; : > "$noautof"; rtail=' · auto off — on-demand only'
      else
        auto=1; rm -f "$noautof"; rtail=' · auto on — refresh each turn'
      fi
      set_hint; rtail_until=$(( EPOCHSECONDS + MSG_SECS )); repaint_footer
      ;;
    i|I)       # toggle interval = refresh periodically during a long turn
      if [ "$intv" = 1 ]; then
        intv=0; rtail=' · interval off'
      else
        intv=1; last_intv=0; rtail=" · interval ${intv_label}"   # last_intv=0 => evaluate next tick
      fi
      set_hint; rtail_until=$(( EPOCHSECONDS + MSG_SECS )); repaint_footer
      ;;
    '+'|'=') step_interval 1 ;;    # raise the interval period ('=' is the unshifted '+' key)
    '-'|'_') step_interval -1 ;;   # lower the interval period
    '?')       # transient key cheatsheet
      rtail=' · r refresh · a auto · i interval · ± period · q quit'; rtail_until=$(( EPOCHSECONDS + HELP_SECS )); repaint_footer
      ;;
    q|Q) exit 0 ;;
  esac
done
