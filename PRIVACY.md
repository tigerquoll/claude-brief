# Privacy Policy

**Effective date:** 9 June 2026
**Plugin:** claude-brief &middot; **Maintainer:** Dale (tigerquoll@outlook.com) &middot; **Source:** <https://github.com/tigerquoll/claude-brief>

## Summary

claude-brief is a **local** tool. It runs entirely on your machine, contains **no**
telemetry, analytics, or tracking, never "phones home," and the maintainer **receives no
data** from your use of it. The only data that leaves your machine is the per-session
summary request — and that goes to the **same model endpoint your Claude Code is already
configured to use** (or an endpoint you explicitly configure), exactly like your own
Claude Code requests.

## What the plugin does

Each completed turn, a `Stop` hook makes a small summary call so the docked pane can show
a live brief of your session (State &middot; Tried &middot; Gotchas &middot; Decisions
&middot; Next). To produce that summary it sends a **bounded slice** of the current
session to a model.

### What is sent to the model

- a display-size directive (the dock's dimensions),
- the conversation title,
- the previous brief,
- your latest prompt, and
- the recent conversation — the last ~14 user/assistant message **text** blocks, truncated
  to a few KB.

### What is NOT sent

- **Tool calls and their outputs are stripped** — raw file contents and command output are
  not transmitted. (The assistant's own prose may still quote paths, code, or error text,
  since that is part of the conversation.)
- No filesystem scans, environment variables, credentials, or system information are
  collected or sent.

### Where it goes

By default the request goes to the **same gateway Claude Code already uses** — Anthropic,
under your existing Claude Code / Anthropic agreement and
[Anthropic's privacy policy](https://www.anthropic.com/legal/privacy). If you set
`$BRIEF_SUMMARIZER` (or use the bundled API-direct summariser), the request goes to whatever
endpoint you configure instead. claude-brief adds no destination of its own.

For API-billed sessions (when `ANTHROPIC_AUTH_TOKEN` or an approved `ANTHROPIC_API_KEY` is
set), the summary request may be sent directly to your configured `ANTHROPIC_BASE_URL`
endpoint via curl rather than through the `claude` CLI — same destination service, fewer
layers.

## Local storage and retention

- Briefs and labels are written under **`~/.claude/state/`** (e.g. `<session-id>.brief.md`).
- They are created with a restrictive `umask` (private to your user account).
- They are **deleted automatically when the session ends** (a `SessionEnd` hook), with an
  age-based prune as a backstop. Nothing is retained long-term by design.

## Credentials (API-direct path only)

If you opt into the API-direct summariser, your API token is read from an environment
variable or a file you create (recommended `chmod 600`). The token is sent **only** as the
`Authorization` header to the endpoint you configured — it is never logged and never
transmitted anywhere else.

## What the plugin does NOT do

- No telemetry, analytics, usage tracking, or crash reporting.
- No "phone home" to the maintainer or any third party.
- No selling, sharing, or monetisation of your data.
- The maintainer receives **no data** from your use of the plugin.

## Third parties

The only third party involved is the **model provider** that answers the summary request —
Anthropic by default, or an endpoint you configure. Your data is handled under that
provider's terms and privacy policy, not by claude-brief.

## The project itself

This is open-source software (BSD-3-Clause). The maintainer sees only GitHub's standard
**aggregate** repository statistics (clone/view counts), which are not tied to plugin users
or their sessions. The plugin's runtime sends nothing to the project.

## Changes

Material changes to this policy will be reflected in this file in the repository, with an
updated effective date.

## Contact

Questions: **tigerquoll@outlook.com** &middot; <https://github.com/tigerquoll/claude-brief>
