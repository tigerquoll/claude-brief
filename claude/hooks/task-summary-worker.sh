#!/usr/bin/env bash
# Detached worker. Summarizes the session into ~/.claude/state/<sid>.task as:
#   ▸ goal: <overarching objective>   (free, from Claude Code's auto title)
#   ▸ now:  <most recent sub-task>     (model-summarized)
# and maintains a richer living brief in ~/.claude/state/<sid>.brief.md
# (State / Tried / Gotchas / Decisions / Next) from the same summariser call,
# so tabbing back into a session can re-brief you on demand (see /brief).
#
# Triggered by the Stop hook (once per completed agent turn) and on demand by the
# /brief dock (its 'r' key and interval refresh call this directly), so the labels
# are fresh whenever you tab back to this terminal.
#
# The MODEL CALL is PLUGGABLE: this worker builds the system+user prompts, then
# delegates to $BRIEF_SUMMARIZER (default ~/.claude/bin/brief-summarize.sh, a lean
# Haiku `claude -p`) under a ${BRIEF_SUMMARY_TIMEOUT:-90}s watchdog, and parses
# the response. Swap in another model/backend by pointing $BRIEF_SUMMARIZER at
# your own script (contract documented in brief-summarize.sh).
sid="$1"; tpath="$2"
[ -z "$sid" ] && exit 0
umask 077   # briefs/labels can contain sensitive session content -> create them private
. "$HOME/.claude/bin/lib/portable.sh"   # _mtime/_perm (portable BSD/GNU stat)

state_dir="$HOME/.claude/state"
mkdir -p "$state_dir"

# Coalesce concurrent runs: a manual/interval dock refresh can race the end-of-turn
# auto one (separate processes), each a ~2c Haiku call + a redraw. Take a per-session
# lock (mkdir is atomic); if another summariser for this sid is already running, skip.
# Reclaim a stale lock — a run can't outlive the 90s watchdog, so >3min => it crashed.
lock="$state_dir/$sid.brief.lock"
if ! mkdir "$lock" 2>/dev/null; then
  [ -n "$(find "$lock" -maxdepth 0 -mmin +3 2>/dev/null)" ] && rmdir "$lock" 2>/dev/null
  mkdir "$lock" 2>/dev/null || exit 0
fi
trap 'rmdir "$lock" 2>/dev/null' EXIT

out="$state_dir/$sid.task"
brief_out="$state_dir/$sid.brief.md"
done_stamp="$state_dir/$sid.brief.done"   # outcome word written here at the end of EVERY attempt (updated/unchanged/timeout/error); the dock watches it
failf="$state_dir/$sid.brief.fail"        # "<consecutive-failures> <last-fail-epoch>", for backoff

# Backoff: after repeated summariser failures (e.g. the gateway is down), stop
# hammering it (and paying) every turn — retry at most once per COOLDOWN. Still
# write outcome=error so the dock shows it's failing (no model call made).
MAXFAIL=3; COOLDOWN=600
if [ -f "$failf" ]; then
  read -r fc ft _ < "$failf" 2>/dev/null
  case "$fc" in ''|*[!0-9]*) fc=0 ;; esac; case "$ft" in ''|*[!0-9]*) ft=0 ;; esac
  if [ "$fc" -ge "$MAXFAIL" ] && [ "$(( $(date +%s) - ft ))" -lt "$COOLDOWN" ]; then
    printf 'error\n' > "$done_stamp.tmp" && mv "$done_stamp.tmp" "$done_stamp"
    exit 0
  fi
fi

# Previous living brief, fed back so the model UPDATES it instead of starting over.
prevbrief=""
[ -f "$brief_out" ] && prevbrief=$(tail -c 4000 "$brief_out")

# Keep the "prev:" line the submit hook shifted in (previous turn's summary).
prev_line=""
[ -f "$out" ] && prev_line=$(grep -m1 '^▸ prev:' "$out")

title=""; hist=""; prompt=""
if [ -f "$tpath" ]; then
  # Claude Code auto-generates a conversation title — a free, solid "goal".
  title=$(jq -rs 'map(select(.type=="ai-title").aiTitle) | last // empty' "$tpath" 2>/dev/null)
  # Latest user prompt (Stop payload has no .prompt field, so read it here).
  prompt=$(jq -rs 'map(select(.type=="last-prompt").lastPrompt) | last // empty' "$tpath" 2>/dev/null)
  # Recent user/assistant text, tool-call noise stripped.
  hist=$(jq -rs '
    [ .[]
      | select(.message.role=="user" or .message.role=="assistant")
      | .message.content
      | if type=="string" then .
        elif type=="array" then (map(select(.type=="text").text) | join(" "))
        else empty end ]
    | map(select(length>0))
    | .[-14:] | join("\n---\n")
  ' "$tpath" 2>/dev/null)
fi
hist=$(printf '%s' "$hist" | tail -c 5000)

# Size the brief to the dock pane: the viewer publishes "rows cols" to $sizef.
# Default to a roomy 42x80 (≈ the old "40 lines") when the dock isn't open / the
# size is unknown. $avail = rendered lines the brief should fit within.
rows=42; cols=80
sizef="$state_dir/$sid.brief.size"
if [ -f "$sizef" ]; then
  read -r sr sc _ < "$sizef" 2>/dev/null
  case "$sr" in ''|*[!0-9]*) ;; *) rows=$sr ;; esac
  case "$sc" in ''|*[!0-9]*) ;; *) cols=$sc ;; esac
fi
avail=$(( rows - 2 )); [ "$avail" -lt 6 ] && avail=6
# Pick an explicit composition directive from the budget (more reliable than
# asking the model to interpret a line count — it scales BOTH ways).
if   [ "$avail" -lt 16 ]; then budget_note="This is a SMALL pane (~${avail} display lines): output ONLY the '# <goal>' title, '## State', and '## Next / Open' — 1-2 terse bullets each; OMIT the other sections."
elif [ "$avail" -lt 32 ]; then budget_note="This is a MEDIUM pane (~${avail} display lines): include all sections but stay compact — a few short bullets each (a single '—' when a section is empty)."
else                           budget_note="This is a ROOMY pane (~${avail} display lines): include all sections with full, concrete detail; use the space."
fi

sys='You maintain the live state of a coding session. Output TWO parts.

PART 1 — a 2-line status label. Output EXACTLY two lines, lowercase keys, no markdown, no quotes, no trailing punctuation:
goal: <overarching objective of the session, <=9 words>
now: <the most recent sub-task just worked on, <=9 words>
Be concrete — name files, tools, or components. Prefer specifics over generic verbs.

Then a line containing ONLY: ===BRIEF===

PART 2 — a living session brief in GitHub markdown that re-briefs a developer who just tabbed back in. UPDATE the previous brief (given below) with what changed this turn; do NOT regenerate from scratch. Preserve durable knowledge; drop resolved or stale items from State and Next. Be concrete: name files, errors, commands, line numbers. Start with a `# <one-line goal>` title, then these sections in this order: ## State, ## Tried, ## Gotchas, ## Decisions, ## Next / Open. FOLLOW THE DISPLAY-SIZE DIRECTIVE in the user message — it says exactly which sections to include and how much detail; fitting the pane takes priority over completeness.
If nothing material changed since the previous brief, output ONLY the word UNCHANGED after the marker.'

usr="Display-size directive (the dock pane is ${rows} rows x ${cols} cols): ${budget_note} Keep lines under ~${cols} chars (longer lines wrap and cost extra display rows). Don't exceed ~${avail} display lines.

Session title hint: ${title:-none}

Previous brief (update this; <none> means this is the first turn):
${prevbrief:-<none>}

Recent conversation (oldest to newest), turns separated by ---:
$hist

Most recent user request:
$prompt

Produce PART 1, then the ===BRIEF=== marker line, then PART 2."

# Resolve the summariser. $BRIEF_SUMMARIZER swaps the model, but it's EXECUTED, so
# only honour it if it lives UNDER ~/.claude/ (a dir untrusted repos can't write
# to), has no '..' escape, and is a regular, user-owned, non-world-writable
# executable — else fall back to the shipped default. It runs as you (like
# $EDITOR); the ~/.claude/ confinement + ownership/perm checks mean an override
# you didn't set yourself (e.g. injected by an untrusted repo's project env, or a
# relative / in-repo script) is ignored. Put a custom summariser in ~/.claude/bin/.
summariser="$HOME/.claude/bin/brief-summarize.sh"
if [ -n "$BRIEF_SUMMARIZER" ]; then
  perm=$(_perm "$BRIEF_SUMMARIZER")
  case "$BRIEF_SUMMARIZER" in
    *..*) ;;                                            # reject path-traversal escapes
    "$HOME"/.claude/*)
      [ -f "$BRIEF_SUMMARIZER" ] && [ -x "$BRIEF_SUMMARIZER" ] && [ -O "$BRIEF_SUMMARIZER" ] \
        && ! (( 8#$perm & 0002 )) && summariser="$BRIEF_SUMMARIZER" ;;
  esac
fi
# Prompts go via env ($BRIEF_SYS/$BRIEF_USR); CLAUDE_TASK_SUMMARY guards recursion
# if the summariser calls claude. Bound it with a perl watchdog (perl is a dep +
# macOS built-in; the alarm survives exec, SIGALRM kills a hung call). Retry ONCE
# on a fast failure (transient 5xx/network), but NOT on a watchdog timeout.
res=""; rc=0
for attempt in 1 2; do
  res=$( BRIEF_SYS="$sys" BRIEF_USR="$usr" CLAUDE_TASK_SUMMARY=1 \
          perl -e 'alarm shift @ARGV; exec @ARGV' "${BRIEF_SUMMARY_TIMEOUT:-90}" "$summariser" \
          2>/dev/null )
  rc=$?   # 0 ok · 124/142 = watchdog timeout · other non-zero = summariser failure
  [ -n "$(printf '%s' "$res" | tr -d '[:space:]')" ] && break   # got a result
  case "$rc" in 124|142) break ;; esac                          # timed out -> a retry would just wait again
  [ "$attempt" = 1 ] && perl -e 'select(undef,undef,undef,1)'   # ~1s pause (perl, already a dep), then the single retry
done

# Clean up the summariser's byproduct ASAP, whichever summariser ran: the default
# (claude -p) leaves an inner-claude transcript per call in the neutral sumcwd
# project dir. Age-based (older than the 90s watchdog) so an in-flight run's
# transcript is never deleted; a no-op when there's nothing (e.g. the API plug-in).
sumproj="$HOME/.claude/projects/$(printf '%s' "$HOME/.claude/state/.sumcwd" | tr '/.' '-')"
[ -d "$sumproj" ] && find "$sumproj" -type f -mmin +2 -delete 2>/dev/null

# Split the response into the 2-line label and the brief (after the marker).
case "$res" in
  *"===BRIEF==="*) label_part=${res%%===BRIEF===*}; brief_part=${res#*===BRIEF===} ;;
  *)              label_part=$res;                  brief_part="" ;;
esac

goal=$(printf '%s\n' "$label_part" | sed -n 's/^[[:space:]]*goal:[[:space:]]*//p' | head -1)
now=$(printf '%s\n' "$label_part"  | sed -n 's/^[[:space:]]*now:[[:space:]]*//p'  | head -1)

# Fallbacks if the model didn't follow the format or the call failed.
[ -z "$goal" ] && goal="$title"
[ -z "$now" ] && now=$(printf '%s' "$prompt" | tr '\n' ' ' | cut -c1-60)

# Update the living brief unless the model said UNCHANGED or returned nothing.
brieftext=$(printf '%s\n' "$brief_part" | awk 'NF{seen=1} seen')   # strip leading blank lines
trimmed=$(printf '%s' "$brieftext" | tr -d '[:space:]')
wrote_brief=0
case "$trimmed" in
  ''|UNCHANGED) : ;;                                                    # keep the previous brief
  *) printf '%s\n' "$brieftext" > "$brief_out.tmp" && mv "$brief_out.tmp" "$brief_out"; wrote_brief=1 ;;
esac

# Record the attempt's OUTCOME (not just an mtime bump) so the dock can show it
# and a failure can't masquerade as "no change". Empty result => the call failed;
# split watchdog timeout from a comms/CLI error by exit code. Written atomically.
if [ -z "$(printf '%s' "$res" | tr -d '[:space:]')" ]; then
  case "$rc" in 124|142) outcome=timeout ;; *) outcome=error ;; esac
elif [ "$wrote_brief" = 1 ]; then outcome=updated
else                              outcome=unchanged
fi
printf '%s\n' "$outcome" > "$done_stamp.tmp" && mv "$done_stamp.tmp" "$done_stamp"

# Track consecutive failures for the backoff above (reset on any success).
case "$outcome" in
  timeout|error) fc=0; [ -f "$failf" ] && { read -r fc _ < "$failf" 2>/dev/null; case "$fc" in ''|*[!0-9]*) fc=0 ;; esac; }
                 printf '%s %s\n' "$((fc + 1))" "$(date +%s)" > "$failf" ;;
  *)             rm -f "$failf" ;;
esac

# Update the status label — but on a FAILED call keep the last-good one rather
# than clobbering goal/now with the prompt-echo fallbacks.
case "$outcome" in
  timeout|error) : ;;
  *)
    [ -z "$goal" ] && [ -z "$now" ] && exit 0
    {
      printf '▸ goal: %s\n' "$goal"
      [ -n "$prev_line" ] && printf '%s\n' "$prev_line"
      printf '▸ now:  %s\n' "$now"
    } > "$out.tmp" && mv "$out.tmp" "$out" ;;
esac
