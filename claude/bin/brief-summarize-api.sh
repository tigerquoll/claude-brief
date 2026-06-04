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
# Reads from the environment (set them in Claude Code's settings.json "env"):
#   ANTHROPIC_BASE_URL            gateway base URL (sends to <base>/v1/messages)
#   ANTHROPIC_AUTH_TOKEN          bearer token (sent as: Authorization: Bearer …)
#   ANTHROPIC_DEFAULT_HAIKU_MODEL model name registered at the gateway
base=${ANTHROPIC_BASE_URL:-https://ai-gateway.cloudops.cloudera.com}
model=${ANTHROPIC_DEFAULT_HAIKU_MODEL:-claude-haiku-4-5}
[ -n "$ANTHROPIC_AUTH_TOKEN" ] || { echo "brief-summarize-api: ANTHROPIC_AUTH_TOKEN not set" >&2; exit 1; }

# Build the request body with jq so the prompts are safely JSON-escaped.
body=$(jq -n --arg m "$model" --arg s "$BRIEF_SYS" --arg u "$BRIEF_USR" \
  '{model:$m, max_tokens:2000, system:$s, messages:[{role:"user", content:$u}]}') || exit 1

resp=$(curl -sS --max-time "${BRIEF_SUMMARY_TIMEOUT:-90}" \
  -H "authorization: Bearer $ANTHROPIC_AUTH_TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "$body" \
  "${base%/}/v1/messages") || exit 1

# Anthropic Messages response: { content: [ {type:"text", text:"…"}, … ], … }.
# On an error response there's no .content[].text, so $text is empty -> exit 1.
text=$(printf '%s' "$resp" | jq -r '[.content[]? | select(.type=="text") | .text] | join("")' 2>/dev/null)
[ -n "$text" ] || exit 1
printf '%s\n' "$text"
