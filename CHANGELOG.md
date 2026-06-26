# Changelog

All notable changes to **claude-brief** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

A note on tags vs. this file: releases are cut by tagging the feature commit
(`git tag -a vX.Y.Z … && git push origin vX.Y.Z`). The release workflow then stamps
that version into the tarball's `plugin.json` and commits the bump to `main` — so the
bump commit always lands one commit *after* the tag. The dates below are the release
dates.

## [1.6.6] — 2026-06-26

### Fixed
- The SessionStart dependency preflight now also checks for `perl`. The summariser
  worker bounds each `claude -p` call with a `perl` watchdog (`alarm`/`exec`), but the
  preflight only warned about a missing `jq`, `bash 5`, or terminal — so on a minimal
  Linux box without `perl` (it's a macOS built-in, so this never bites on macOS) the
  brief would silently fail to generate with no actionable message. `perl` now appears
  in the same "required dep(s) missing" warning as the others.

## [1.6.5] — 2026-06-19

### Fixed
- Brief no longer renders "hard-wrapped" at a fixed width that ignores the pane (so
  it wouldn't reflow when you resized). The summariser prompt told the model to keep
  lines under the pane width, which baked manual line breaks into the markdown — and
  glow preserves soft (single-newline) breaks instead of reflowing them, so those
  briefs stayed wrapped at the summariser's width regardless of the pane. The prompt
  now tells the model to write each bullet on ONE line and let the dock wrap.
  Existing briefs fix themselves on their next refresh.

## [1.6.4] — 2026-06-19

### Added
- Update notice: on a version bump, the SessionStart hook shows a one-time message
  with a `file://` link to the installed `CHANGELOG.md` — Claude Code has no built-in
  plugin-changelog surface (no manifest field, the `/plugin` update flow shows none).
  Silent on first install and when unchanged, so it appears exactly once per update —
  starting with the update *after* this one (this update just records the baseline).

### Changed
- The release tarball now ships `CHANGELOG.md` (previously `export-ignore`d as
  dev-only), so the update notice can link to it on tarball installs too, not just
  the plugin-clone path.

## [1.6.3] — 2026-06-19

### Fixed
- The iTerm2 dock no longer shows a scroll bar. 1.6.2 stopped *renders* piling up
  via `\033[3J`, but iTerm2 doesn't act on that erase-scrollback escape here, and
  the alternate screen doesn't zero the pane's underlying main-buffer scrollback —
  so the login noise printed before the viewer started (plus accumulating renders)
  kept a scroll bar, and resizing could reflow that stale history into view. The
  `brief` dock profile now sets `Scrollback Lines: 0`, giving the pane no scrollback
  buffer at all — nothing to accumulate, nothing for the scroll bar to show. The
  viewer also wipes the screen + scrollback once at startup (before `smcup`) for
  backends that honor it.
- The session-start hook now **resyncs** `brief.json` into iTerm2's DynamicProfiles
  when the shipped copy differs, not only when it's missing — otherwise shipped
  profile fixes (like the one above) never reach users who already have an older
  profile.

## [1.6.2] — 2026-06-19

### Fixed
- The dock no longer looks frozen at the old width when you resize the pane. The
  viewer renders on the alt-screen and clears with `\033[2J`, but some terminals
  (notably iTerm2 with default settings) copy each alt-screen clear into the
  scrollback — so renders at different widths piled up there, and on a resize the
  terminal reflowed that stale scrollback back into view, looking exactly like the
  brief never re-wrapped (the *newest* render was always correct). The full redraw
  now also erases the scrollback (`\033[3J`), so the dock shows only the current
  render. A `WINCH` trap also makes a resize redraw immediately instead of waiting
  up to the ~0.5s poll.
- When the dock was open for a session with no brief yet (fresh / just-cleared
  session, or every turn so far trivial), it showed a bare "No brief yet" screen
  with **no footer/menu** — so `r` (refresh now) and the `i`/interval refresh gave
  no feedback and looked dead. The no-brief screen now carries the same menu footer
  and live refresh state (spinner + outcome), so a manual or interval refresh can
  be triggered and its progress is visible.

## [1.6.1] — 2026-06-15

### Fixed
- Summariser no longer emits a "restore project context" brief instead of a
  summary. The default CLI summariser runs `claude -p` from an empty neutral
  working dir (`.sumcwd`), and Claude Code injects that environment (cwd, "not a
  git repository") into the system prompt; the model could treat it as ground
  truth, see it conflict with a transcript about a real git project, and report a
  context mismatch. The system prompt now fences the summariser off from its own
  runtime environment — the transcript is its sole source of truth.

## [1.6.0] — 2026-06-15

### Added
- `latest release:` line in the debug `[install]` section — an anonymous,
  fail-soft (5s) check against the GitHub releases API, so stale-version bug
  reports identify themselves. Disclosed in PRIVACY.md.
- Manual-install docs now list the optional `SessionStart` hook line — it's what
  surfaces missing-dep and rejected-`BRIEF_SUMMARIZER` warnings at session start;
  the plugin wires it automatically, but manual installs previously had those
  warnings written to state and never shown.

## [1.5.0] — 2026-06-12

### Added
- `/brief debug` — a sanitised, copy-pasteable diagnostic report for bug reports.
  Collects by allowlist (versions, state-file ages, the last outcome and backoff
  status, summariser resolution incl. why an override was rejected, env-var
  *presence and length* only — never values — and one 20s-capped probe summary
  call with scrubbed stderr). `$HOME` renders as `~`; key-shaped strings are
  masked. When an auto-selected API probe fails, the CLI fallback is probed too —
  mirroring the worker — so a failing-but-recovering setup reads as exactly that.
  Safe to paste into a public GitHub issue.
- `[dock]` section in the debug report: detection signals (presence only), the
  detected driver vs any override, self-pane resolution, the dock session's
  driver vs the currently-detected one (mismatch flagged), a per-backend
  `tdrv_preflight` probe (tmux server ping, `kitty @ ls` over the socket,
  `wezterm cli`, osascript Automation checks with TCC `-1743` called out — new
  OPTIONAL driver-contract hook, see DEVELOPING.md), and the **last dock error**:
  a failed `tdrv_open`'s stderr is now persisted to `state/.brief-dock-err`
  (cleared on the next successful open) instead of being discarded.

- **Privacy-preserving failure classification**: each failed summary attempt's
  stderr is matched against fixed signatures and reduced to an enum (`timeout`,
  `auth`, `network`, `permission-rule`, `api-error:<type>`, …) persisted to
  `state/<sid>.brief.err`; the stderr **text is discarded, never written to
  disk** — a live call's error output could echo conversation fragments. The
  debug report shows it as `last failure:`; cleared on the next success.
- **Backoff countdown in the dock footer** — during the 10-minute failure
  backoff the footer now shows *"summary failing — auto-retry in ~Nm"* instead
  of a stale "summary failed".
- `login-shell bash:` probe in the debug `[dock]` section — the dock pane runs
  the viewer under a login-shell PATH, where bash 3.2 makes the pane open and
  instantly die.
- README **Troubleshooting** section (the two looks-broken-but-isn't cases:
  cost-gated trivial turns, failure backoff) + a GitHub issue template that asks
  for the `/brief debug` output; PRIVACY.md now documents exactly what the debug
  report does and does not collect.

### Fixed
- The API summariser now reports the error response's `type`/`message` fields on
  stderr (length-capped, never the raw response) instead of exiting silently.

## [1.4.0] — 2026-06-12

### Added
- `/brief help` subcommand — usage, the in-dock keys, and docs pointers; needs no
  session or dock. A one-time first-run hint after the first dock open points at
  the dock's `?` key and `help`.

### Fixed
- **CLI summariser pins the session's effective endpoint** via a `--settings` env
  override. Claude Code applies settings-file env over process env, so from the
  summariser's neutral cwd a global settings-env `ANTHROPIC_BASE_URL` (e.g. a
  corporate gateway) re-pointed the inner `claude -p` even when the session's own
  project settings had blanked it — and the unauthenticated gateway call hung
  until the watchdog killed it, so no brief was ever produced.
- A rejected `BRIEF_SUMMARIZER` override is no longer silent: the reason (no such
  file, literal `~`, outside `~/.claude`, bad perms…) is written to
  `state/.brief-summarizer-warn` and surfaced at session start — and a rejected
  override now counts as unset, so summariser auto-selection still applies.
- Dropped the removed `SlashCommand` tool from the inner claude's disallowed-tools
  list (Claude Code ≥2.1.x warned on it); `Skill` is disallowed instead.

## [1.3.0] — 2026-06-11

### Added
- **Auto-select the direct-API summariser on API-billed sessions** — when the session
  authenticates via `ANTHROPIC_AUTH_TOKEN`, an approved `ANTHROPIC_API_KEY`, or any
  `BRIEF_API_*` / `brief-summarizer.env` config, the brief is generated by a direct
  Messages-API call (~5× cheaper than the `claude -p` CLI path). Subscription (OAuth)
  sessions are never switched. Opt out with `BRIEF_AUTO_API=0`.

### CI / docs
- Guard against internal hostnames in tracked files.
- Cache the downloads badge; surface the summariser auto-selection in the privacy
  blurb and comparison table.

## [1.2.1] — 2026-06-09

### Security
- Address security-review findings F1–F7: argv hygiene in the dock drivers,
  AppleScript string escaping, a safe default API base URL, and session-id
  validation. The repo history was also scrubbed as part of this release.

### Added
- `PRIVACY.md` — what each summary call sends, local storage, and retention.
- Plugin manifest keywords for directory/search indexing.

### CI / docs
- Run the full regression suite on macOS in CI (real-terminal e2e skips under CI).
- Command and in-dock-key tables in the README; plugin command
  (`/claude-brief:brief`) used consistently throughout.

## 1.2.0 — 2026-06-09

*(The v1.2.0 and earlier tags/releases were withdrawn during the v1.2.1 history scrub.)*

### Fixed
- Harden the plugin dependency preflight: fail loud on missing required deps and
  stop assuming Homebrew is installed when printing install hints.

## 1.1.0 — 2026-06-09

### Added
- **Claude Code plugin packaging** — install via
  `/plugin marketplace add tigerquoll/claude-brief`: self-hosting
  `marketplace.json`, auto-wired hooks (`hooks.json`), and a SessionStart hook for
  fresh-user setup (iTerm2 profile + dependency check).
- Tag-triggered release workflow that stamps `plugin.json` from the release tag and
  syncs the bump back to `main`.

### Changed
- Unified layout: the repo root is the plugin root; `install.sh` deploys the same
  self-locating tree to `~/.claude` for the manual path.

## 1.0.1 — 2026-06-09

Initial public release (pre-plugin): the per-session brief generated by a cost-gated
Haiku call on the `Stop` hook, docked beside the session with pluggable terminal
backends (iTerm2, tmux, kitty, WezTerm, ghostty, Apple Terminal, generic fallback),
manual `~/.claude` install via `install.sh`, and release tarballs.

[1.6.1]: https://github.com/tigerquoll/claude-brief/releases/tag/v1.6.1
[1.6.0]: https://github.com/tigerquoll/claude-brief/releases/tag/v1.6.0
[1.5.0]: https://github.com/tigerquoll/claude-brief/releases/tag/v1.5.0
[1.4.0]: https://github.com/tigerquoll/claude-brief/releases/tag/v1.4.0
[1.3.0]: https://github.com/tigerquoll/claude-brief/releases/tag/v1.3.0
[1.2.1]: https://github.com/tigerquoll/claude-brief/releases/tag/v1.2.1
