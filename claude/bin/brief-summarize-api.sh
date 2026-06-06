#!/usr/bin/env bash
# Alternative brief summariser — calls the Anthropic Messages API DIRECTLY through
# the LiteLLM / Anthropic gateway, skipping the `claude -p` CLI's ~30k-token prefix
# (MCP schemas, system prompt, tool defs) → roughly ~5x cheaper per summary.
#
# Opt in (it's not the default):
#   export BRIEF_SUMMARIZER="$HOME/.claude/bin/brief-summarize-api.sh"
#
# Contract (same as bin/brief-summarize.sh): reads $BRIEF_SYS / $BRIEF_USR, writes
# the raw model response to stdout (goal:/now: + ===BRIEF=== + markdown, or just
# UNCHANGED). Empty output / non-zero exit ⇒ the worker records a failure. The
# worker wraps this in a ${BRIEF_SUMMARY_TIMEOUT:-90}s watchdog.
#
# Config — lets the summariser use a DIFFERENT endpoint/token/model than, and
# never affect, the MAIN Claude Code session. For each setting: a summariser-only
# $BRIEF_API_* var wins; otherwise the shared $ANTHROPIC_* the main session uses:
#   base : $BRIEF_API_BASE  | $ANTHROPIC_BASE_URL              -> <base>/v1/messages
#   token: $BRIEF_API_TOKEN | $ANTHROPIC_AUTH_TOKEN            -> Authorization: Bearer …
#   model: $BRIEF_API_MODEL | $ANTHROPIC_DEFAULT_HAIKU_MODEL
# Any of these may instead live in ~/.claude/brief-summarizer.env (sourced if it's
# yours and not group/other-writable) — handy to keep the token out of settings.json,
# and out of the main session's environment entirely.
. "$HOME/.claude/bin/lib/portable.sh"   # _mtime/_perm (portable BSD/GNU stat)
cfg="$HOME/.claude/brief-summarizer.env"
if [ -f "$cfg" ] && [ -O "$cfg" ]; then
  cperm=$(_perm "$cfg")
  (( 8#$cperm & 0022 )) || . "$cfg"   # source only if not group/other-writable
fi
base=${BRIEF_API_BASE:-${ANTHROPIC_BASE_URL:-https://ai-gateway.cloudops.cloudera.com}}
model=${BRIEF_API_MODEL:-${ANTHROPIC_DEFAULT_HAIKU_MODEL:-claude-haiku-4-5}}
token=${BRIEF_API_TOKEN:-$ANTHROPIC_AUTH_TOKEN}
[ -n "$token" ] || { echo "brief-summarize-api: no token — set BRIEF_API_TOKEN or ANTHROPIC_AUTH_TOKEN (or put it in ~/.claude/brief-summarizer.env)" >&2; exit 1; }

# Build the request body with jq so the prompts are safely JSON-escaped.
body=$(jq -n --arg m "$model" --arg s "$BRIEF_SYS" --arg u "$BRIEF_USR" \
  '{model:$m, max_tokens:2000, system:$s, messages:[{role:"user", content:$u}]}') || exit 1

resp=$(curl -sS --max-time "${BRIEF_SUMMARY_TIMEOUT:-90}" \
  -H "authorization: Bearer $token" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "$body" \
  "${base%/}/v1/messages") || exit 1

# Anthropic Messages response: { content: [ {type:"text", text:"…"}, … ], … }.
# On an error response there's no .content[].text, so $text is empty -> exit 1.
text=$(printf '%s' "$resp" | jq -r '[.content[]? | select(.type=="text") | .text] | join("")' 2>/dev/null)
[ -n "$text" ] || exit 1
printf '%s\n' "$text"
