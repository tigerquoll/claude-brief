#!/usr/bin/env bash
# Remove stale brief state: per-session files for sessions untouched in
# > BRIEF_PRUNE_AGE_DAYS (default 3), plus orphaned pane/cwd map entries. Purely
# age-based, so an active (recently-written) session is never touched. Run by
# hand or called opportunistically (<=1x/day) from the Stop hook. Safe to re-run.
st="$HOME/.claude/state"
[ -d "$st" ] || exit 0
. "$HOME/.claude/bin/lib/portable.sh"   # _mtime/_perm (portable BSD/GNU stat)
days=${BRIEF_PRUNE_AGE_DAYS:-3}
now=$(date +%s); age=$((days * 24 * 3600))

# Per-session file groups (<sid>.task / .brief.md / .brief.* / .skipped / .tlines):
# drop the whole group if the newest file in it is older than the age threshold.
ls "$st"/*.task "$st"/*.brief.md 2>/dev/null \
  | sed -E 's#.*/##; s/\.(task|brief\.md)$//' | sort -u | while read -r sid; do
  [ -n "$sid" ] || continue
  newest=0
  for f in "$st/$sid".*; do
    [ -e "$f" ] || continue
    m=$(_mtime "$f"); [ "${m:-0}" -gt "$newest" ] && newest=$m
  done
  [ "$newest" -gt 0 ] && [ $((now - newest)) -gt "$age" ] && rm -f "$st/$sid".*
done

# Orphaned pane->sid and cwd->sid map entries older than the threshold.
find "$st/panes" "$st/cwds" -type f -mtime +"$days" -delete 2>/dev/null

# The summariser's inner `claude -p` leaves a throwaway transcript per call in the
# neutral sumcwd project dir. They're never reused (each summary is independent),
# so keep only ~2 days (enough to inspect a recent bad summary) regardless of the
# session-state $days — else they grow unbounded. Dir name = the sumcwd path with
# '/' and '.' turned into '-' (Claude's project-dir munge).
sumproj="$HOME/.claude/projects/$(printf '%s' "$HOME/.claude/state/.sumcwd" | tr '/.' '-')"
[ -d "$sumproj" ] && find "$sumproj" -type f -mtime +1 -delete 2>/dev/null

exit 0
