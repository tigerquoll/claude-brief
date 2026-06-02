#!/usr/bin/env bash
# Fleet overview: one line per recent Claude Code session (newest first) —
# mark · age · session-id · goal · current sub-task — to decide which tab to
# jump to. Reads the per-session .task labels the prompt/summary hooks maintain.
# The session you're invoking from (resolved via this pane) is marked with ▸.
st="$HOME/.claude/state"
now=$(date +%s)
fmt_age() { local s=$1
  if   [ "$s" -lt 60 ];    then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ];  then printf '%dm' "$((s/60))"
  elif [ "$s" -lt 86400 ]; then printf '%dh' "$((s/3600))"
  else printf '%dd' "$((s/86400))"; fi; }

# Which session is THIS pane (same resolution /brief uses).
cur=""
pane=$(printf '%s' "${ITERM_SESSION_ID#*:}" | tr -dc '0-9A-Fa-f-')
[ -n "$pane" ] && [ -f "$st/panes/$pane" ] && cur=$(cat "$st/panes/$pane" 2>/dev/null)

found=0
for t in $(ls -t "$st"/*.task 2>/dev/null); do
  sid=$(basename "$t" .task)
  m=$(stat -f %m "$t" 2>/dev/null); age=$(( now - ${m:-$now} ))
  [ "$age" -gt $((7*86400)) ] && continue           # ignore ancient (prune handles them)
  goal=$(grep -m1 '^▸ goal:' "$t" 2>/dev/null | sed 's/^▸ goal:[[:space:]]*//')
  sub=$(grep  -m1 '^▸ now:'  "$t" 2>/dev/null | sed 's/^▸ now:[[:space:]]*//; s/^⏳ *//')
  mark=" "; [ "$sid" = "$cur" ] && mark="▸"
  printf '%s %4s  %s  %-42.42s  %s\n' "$mark" "$(fmt_age "$age")" "${sid:0:8}" "${goal:--}" "${sub:--}"
  found=1
done
[ "$found" = 0 ] && echo "(no sessions tracked yet)"
exit 0   # never exit non-zero just because the last test was false (it fails the /sessions command)
