#!/usr/bin/env bash
# Detached worker. Summarizes the session into ~/.claude/state/<sid>.task as:
#   ▸ goal: <overarching objective>   (free, from Claude Code's auto title)
#   ▸ now:  <most recent sub-task>     (Haiku-summarized)
# and maintains a richer living brief in ~/.claude/state/<sid>.brief.md
# (State / Tried / Gotchas / Decisions / Next) produced by the SAME Haiku call,
# so tabbing back into a session can re-brief you on demand (see /brief).
#
# Triggered by the Stop hook (once per completed agent turn), so the labels are
# fresh whenever you tab back to this terminal. Uses `claude -p` with Haiku to
# reuse existing Claude auth (OAuth; no API keys to manage), run as lean as
# possible to minimize cost:
#   - MCP disabled + built-in tools disabled -> ~9k fewer prefix tokens
#   - fixed neutral working dir (no CLAUDE.md) -> byte-stable prefix, so the
#     5-min prompt cache is reused across turns and across projects
sid="$1"; tpath="$2"
[ -z "$sid" ] && exit 0
umask 077   # briefs/labels can contain sensitive session content -> create them private

state_dir="$HOME/.claude/state"
sumcwd="$state_dir/.sumcwd"   # neutral, CLAUDE.md-free dir => stable cache key
mkdir -p "$state_dir" "$sumcwd"
out="$state_dir/$sid.task"
brief_out="$state_dir/$sid.brief.md"
done_stamp="$state_dir/$sid.brief.done"   # bumped at the end of EVERY attempt so a live dock can clear its "refreshing…" indicator, even on UNCHANGED

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

# Built-in tools we strip from the request (we never use them for summarizing).
NOTOOLS='Bash,Read,Edit,Write,Glob,Grep,Task,WebFetch,WebSearch,TodoWrite,NotebookEdit,BashOutput,KillShell,ExitPlanMode,SlashCommand'

sys='You maintain the live state of a coding session. Output TWO parts.

PART 1 — a 2-line status label. Output EXACTLY two lines, lowercase keys, no markdown, no quotes, no trailing punctuation:
goal: <overarching objective of the session, <=9 words>
now: <the most recent sub-task just worked on, <=9 words>
Be concrete — name files, tools, or components. Prefer specifics over generic verbs.

Then a line containing ONLY: ===BRIEF===

PART 2 — a living session brief in GitHub markdown that re-briefs a developer who just tabbed back in. UPDATE the previous brief (given below) with what changed this turn; do NOT regenerate from scratch. Preserve durable knowledge; drop resolved or stale items from State and Next. Be concrete: name files, errors, commands, line numbers. Keep it tight: at most 40 lines, terse bullets. Use EXACTLY these sections, in order, each always present (use a single "—" when a section is empty):
# <one-line goal>
## State
## Tried
## Gotchas
## Decisions
## Next / Open
If nothing material changed since the previous brief, output ONLY the word UNCHANGED after the marker.'

usr="Session title hint: ${title:-none}

Previous brief (update this; <none> means this is the first turn):
${prevbrief:-<none>}

Recent conversation (oldest to newest), turns separated by ---:
$hist

Most recent user request:
$prompt

Produce PART 1, then the ===BRIEF=== marker line, then PART 2."

# 90s watchdog via perl (already a dependency; macOS built-in) instead of GNU
# `timeout` (coreutils, not on a stock macOS): the alarm survives exec, and
# SIGALRM's default action kills the claude call if it hangs.
res=$( cd "$sumcwd" 2>/dev/null && CLAUDE_TASK_SUMMARY=1 \
        MAX_THINKING_TOKENS=0 DISABLE_INTERLEAVED_THINKING=1 \
        perl -e 'alarm shift @ARGV; exec @ARGV' 90 claude -p "$usr" \
        --append-system-prompt "$sys" \
        --model "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-claude-haiku-4-5}" \
        --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
        --disallowedTools "$NOTOOLS" \
        </dev/null 2>/dev/null )

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
case "$trimmed" in
  ''|UNCHANGED) : ;;                                                    # keep the previous brief
  *) printf '%s\n' "$brieftext" > "$brief_out.tmp" && mv "$brief_out.tmp" "$brief_out" ;;
esac
: > "$done_stamp"   # tell watchers (the /brief dock) this refresh attempt finished — even if UNCHANGED

[ -z "$goal" ] && [ -z "$now" ] && exit 0
{
  printf '▸ goal: %s\n' "$goal"
  [ -n "$prev_line" ] && printf '%s\n' "$prev_line"
  printf '▸ now:  %s\n' "$now"
} > "$out.tmp" && mv "$out.tmp" "$out"
