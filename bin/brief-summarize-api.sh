#!/usr/bin/env bash
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"   # plugin root (or ~/.claude when installed)
# Alternative brief summariser — calls the Anthropic Messages API DIRECTLY through
# the LiteLLM / Anthropic gateway, skipping the `claude -p` CLI's ~30k-token prefix
# (MCP schemas, system prompt, tool defs) → roughly ~5x cheaper per summary.
#
# AUTO-SELECTED by the worker when the session is API-billed (ANTHROPIC_AUTH_TOKEN
# set, an approved ANTHROPIC_API_KEY, or any BRIEF_API_* / brief-summarizer.env
# config present). Force it with BRIEF_SUMMARIZER; disable auto-selection with
# BRIEF_AUTO_API=0 (subscription / OAuth sessions that never need it).
#
# Contract (same as bin/brief-summarize.sh): reads $BRIEF_SYS / $BRIEF_USR, writes
# the raw model response to stdout (goal:/now: + ===BRIEF=== + markdown, or just
# UNCHANGED). Empty output / non-zero exit ⇒ the worker records a failure. The
# worker wraps this in a ${BRIEF_SUMMARY_TIMEOUT:-90}s watchdog.
#
# --check mode (first argv):
#   Resolves credentials (same config-file sourcing as the normal path) and prints
#   ONE word to stdout indicating the credential source, then exits 0:
#     brief       — BRIEF_API_TOKEN (whether from env or brief-summarizer.env)
#     auth-token  — ANTHROPIC_AUTH_TOKEN
#     api-key     — ANTHROPIC_API_KEY
#   Exits 1 with no output when no credential is available. No network call is made.
#   The credential VALUE is never printed.
#
# Config — lets the summariser use a DIFFERENT endpoint/token/model than, and
# never affect, the MAIN Claude Code session. For each setting: a summariser-only
# $BRIEF_API_* var wins; otherwise the shared $ANTHROPIC_* the main session uses:
#   base : $BRIEF_API_BASE  | $ANTHROPIC_BASE_URL              -> <base>/v1/messages
#   token: $BRIEF_API_TOKEN | $ANTHROPIC_AUTH_TOKEN            -> Authorization: Bearer …
#         | $ANTHROPIC_API_KEY                                  -> x-api-key: …
#   model: $BRIEF_API_MODEL | $ANTHROPIC_DEFAULT_HAIKU_MODEL
# Any of these may instead live in ~/.claude/brief-summarizer.env (sourced if it's
# yours and not group/other-writable) — handy to keep the token out of settings.json,
# and out of the main session's environment entirely.
. "$ROOT/bin/lib/portable.sh"   # _mtime/_perm (portable BSD/GNU stat)
cfg="$HOME/.claude/brief-summarizer.env"
if [ -f "$cfg" ] && [ -O "$cfg" ]; then
  cperm=$(_perm "$cfg")
  (( 8#$cperm & 0022 )) || . "$cfg"   # source only if not group/other-writable
fi
base=${BRIEF_API_BASE:-${ANTHROPIC_BASE_URL:-https://api.anthropic.com}}
model=${BRIEF_API_MODEL:-${ANTHROPIC_DEFAULT_HAIKU_MODEL:-claude-haiku-4-5}}

# Credential ladder: BRIEF_API_TOKEN (Bearer) > ANTHROPIC_AUTH_TOKEN (Bearer) >
# ANTHROPIC_API_KEY (x-api-key header). Source is tracked for --check mode.
token_source=""
token=""
if [ -n "${BRIEF_API_TOKEN:-}" ]; then
  token="$BRIEF_API_TOKEN"; token_source="brief"
elif [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
  token="$ANTHROPIC_AUTH_TOKEN"; token_source="auth-token"
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  token="$ANTHROPIC_API_KEY"; token_source="api-key"
fi

# --check: print the source word and exit; never print the credential value.
if [ "${1:-}" = "--check" ]; then
  [ -n "$token_source" ] || exit 1
  printf '%s\n' "$token_source"
  exit 0
fi

[ -n "$token" ] || { echo "brief-summarize-api: no credential — set BRIEF_API_TOKEN, ANTHROPIC_AUTH_TOKEN, or ANTHROPIC_API_KEY (or put it in ~/.claude/brief-summarizer.env)" >&2; exit 1; }

# Build the request body with jq so the prompts are safely JSON-escaped. Write it to a
# PRIVATE temp file (umask 077) and POST with -d @file, so the conversation text never
# lands on curl's argv (visible in `ps`).
umask 077
body=$(jq -n --arg m "$model" --arg s "$BRIEF_SYS" --arg u "$BRIEF_USR" \
  '{model:$m, max_tokens:2000, system:$s, messages:[{role:"user", content:$u}]}') || exit 1
bodyf=$(mktemp "${TMPDIR:-/tmp}/brief-body.XXXXXX") || exit 1
trap 'rm -f "$bodyf"' EXIT
printf '%s' "$body" > "$bodyf"

# Auth header via a stdin curl-config (-K -), NOT -H on the command line, so the
# credential never appears in the process table. printf is a shell builtin, so the
# token isn't on any forked process's argv either.
# For ANTHROPIC_API_KEY the wire format requires x-api-key (not Authorization: Bearer).
if [ "$token_source" = "api-key" ]; then
  auth_header_line="header = \"x-api-key: ${token}\""
else
  auth_header_line="header = \"authorization: Bearer ${token}\""
fi
resp=$(printf '%s\n' "$auth_header_line" \
  | curl -sS --max-time "${BRIEF_SUMMARY_TIMEOUT:-90}" -K - \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d @"$bodyf" \
      "${base%/}/v1/messages") || exit 1

# Anthropic Messages response: { content: [ {type:"text", text:"…"}, … ], … }.
# On an error response there's no .content[].text, so $text is empty -> exit 1.
text=$(printf '%s' "$resp" | jq -r '[.content[]? | select(.type=="text") | .text] | join("")' 2>/dev/null)
[ -n "$text" ] || exit 1
printf '%s\n' "$text"
