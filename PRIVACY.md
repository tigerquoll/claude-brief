# Privacy Policy

**Effective date:** 12 June 2026
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

By default the request goes to the **same endpoint your session is already using** —
Anthropic, under your existing Claude Code / Anthropic agreement and
[Anthropic's privacy policy](https://www.anthropic.com/legal/privacy). The default
(`claude -p`) path explicitly **pins the session's effective `ANTHROPIC_BASE_URL`**
into the call, so a differently-configured global gateway cannot silently reroute the
summary somewhere your session isn't sending data anyway. If you set `$BRIEF_SUMMARIZER`
or any `BRIEF_API_*` config, the request goes to whatever endpoint you configure instead.
claude-brief adds no destination of its own.

On **API-billed sessions** the bundled API-direct summariser is **selected
automatically** — when `ANTHROPIC_AUTH_TOKEN` is set, an `ANTHROPIC_API_KEY` that you
have approved for Claude Code use is present, or you've put `BRIEF_API_*` /
`brief-summarizer.env` config in place. It sends the same request via curl to the same
destination service your session uses (explicit `BRIEF_API_BASE` →
`ANTHROPIC_BASE_URL` → Anthropic), just with fewer layers. Subscription (OAuth)
sessions are never switched. Opt out of auto-selection entirely with
`BRIEF_AUTO_API=0`.

## Local storage and retention

- Briefs and labels are written under **`~/.claude/state/`** (e.g. `<session-id>.brief.md`).
- They are created with a restrictive `umask` (private to your user account).
- They are **deleted automatically when the session ends** (a `SessionEnd` hook), with an
  age-based prune as a backstop. Nothing is retained long-term by design.

## Credentials (API-direct path only)

When the API-direct summariser runs (auto-selected as above, or forced by you), it
**reuses a credential your session already exposes** — `BRIEF_API_TOKEN` (or your
`brief-summarizer.env` file, recommended `chmod 600`), else `ANTHROPIC_AUTH_TOKEN`, else
an `ANTHROPIC_API_KEY` — and an API key is used **only if Claude Code has recorded your
approval** of it, so a key you declined for Claude Code is never charged. The token is
sent **only** as the `Authorization` header to the endpoint resolved above — it is never
logged and never transmitted anywhere else. No new credential is created or stored by
the plugin.

## The debug report (`/brief debug`)

The `debug` subcommand prints a diagnostic report designed to be **safe to paste into a
public GitHub issue**. It collects by *allowlist* — only facts that cannot leak content:

- Versions, install shape, dependency presence, and the detected terminal backend.
- State-file **ages and outcome words** (`updated` / `error` / …), never their content —
  the brief itself is never included.
- Environment variables as **presence and length only** (`set(len 47)` / `blank` /
  `unset`), never values; the API endpoint only as `default` vs `custom`.
- Summary **failure categories** (`timeout`, `auth`, `network`, …): when a real summary
  call fails, its stderr is matched against fixed signatures and then **discarded** —
  the text is never written to disk, because a live call's error output could in
  principle echo conversation fragments.
- One probe summary call with a **fixed, generic prompt** (so its output and stderr
  contain nothing of yours); the stderr shown is scrubbed of key-shaped strings.
- No window or tab titles, no pane contents, no transcript text. Paths render with
  `$HOME` as `~`; session ids are truncated.

Nothing about the report is transmitted anywhere by the plugin — it is printed in your
terminal, and sharing it is entirely your action.

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
