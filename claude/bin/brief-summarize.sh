#!/usr/bin/env bash
# Default brief summariser — a lean Haiku `claude -p` call. The worker
# (task-summary-worker.sh) builds the prompts and calls THIS (or whatever
# $BRIEF_SUMMARIZER points to) under a watchdog, so the MODEL IS PLUGGABLE.
#
# CONTRACT (write your own and point $BRIEF_SUMMARIZER at it — e.g. an OpenAI,
# Ollama, or different-Claude-model backend). For security it's only honoured if
# it lives UNDER ~/.claude/ (e.g. ~/.claude/bin/), with no '..', and is an
# executable, user-owned, non-world-writable file — else the worker uses this
# default. Interface:
#   in:   $BRIEF_SYS   system prompt (the static format/instructions)
#         $BRIEF_USR   user prompt — contains, as context: a display-size
#                      directive, the session title, the previous brief, the
#                      latest user prompt, and the recent conversation (last ~14
#                      user/assistant TEXT blocks; tool calls + their outputs are
#                      stripped, so no raw file contents / command output), each
#                      truncated to a few KB.
#   out:  the raw response on STDOUT — two lines "goal: …" / "now: …", then a
#         line "===BRIEF===", then the brief markdown (or just "UNCHANGED" after
#         the marker if nothing changed). Exit 0; empty output (or non-zero exit)
#         is treated as a failure by the worker.
#   note: the caller wraps this in a ${BRIEF_SUMMARY_TIMEOUT:-90}s watchdog and
#         sets CLAUDE_TASK_SUMMARY=1 (recursion guard). `exec` your tool so the
#         watchdog can kill it directly if it hangs.
#
# This default runs claude as lean as possible to minimize cost:
#   - reuses existing Claude auth (OAuth; no API keys to manage)
#   - MCP + built-in tools disabled  -> ~9k fewer prefix tokens
#   - fixed neutral working dir (no CLAUDE.md) -> byte-stable prefix, so the
#     5-min prompt cache is reused across turns and across projects
#   - Haiku model, no thinking
NOTOOLS='Bash,Read,Edit,Write,Glob,Grep,Task,WebFetch,WebSearch,TodoWrite,NotebookEdit,BashOutput,KillShell,ExitPlanMode,SlashCommand'
sumcwd="$HOME/.claude/state/.sumcwd"; mkdir -p "$sumcwd"
cd "$sumcwd" 2>/dev/null || exit 1
export CLAUDE_TASK_SUMMARY=1            # so the inner claude's own hooks bail (the worker sets this too)
export MAX_THINKING_TOKENS=0 DISABLE_INTERLEAVED_THINKING=1
exec claude -p "$BRIEF_USR" \
  --append-system-prompt "$BRIEF_SYS" \
  --model "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-claude-haiku-4-5}" \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --disallowedTools "$NOTOOLS" \
  </dev/null
