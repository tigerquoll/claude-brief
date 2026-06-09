# Developing claude-brief

The developer / architecture guide. To install and *use* the dock, see the
[README](README.md).

Everything is shell. The hooks and terminal drivers are kept **bash-3.2-safe**
(macOS ships bash 3.2 and the hooks run under it); only the dock viewer
(`brief-view.sh`) needs **bash 5** (it uses `$EPOCHSECONDS`).

## Architecture

Three Claude Code hooks plus the on-demand `/brief` command drive a per-session brief:

- **`UserPromptSubmit` → `task-prompt-hook.sh`** — no model call. Maps the current
  pane id and cwd → session id (`state/panes/<paneid>`, `state/cwds/<cwd>`) as a
  *fallback* resolver for `/brief`, and shifts last turn's summary into a `▸ prev:`
  line. (`/brief` prefers the authoritative `$CLAUDE_CODE_SESSION_ID` Claude Code
  exports to its shell; the pane/cwd maps plus a newest-brief last resort only cover
  older Claude Code that doesn't set it — without #0, a fresh or just-`/clear`'d tab
  would fall through to "newest brief" and dock another session.)
- **`Stop` → `task-summary-hook.sh` → `task-summary-worker.sh`** — fires once per
  completed turn (cost-gated; trivial turns are skipped). The detached worker builds
  the prompt, calls the summariser, and writes the brief — so it adds no latency.
- **`/brief` → `brief-open.sh`** — opens / refocuses the dock (a terminal split or
  window running `brief-view.sh <sid>`) through the terminal driver layer.
- **`SessionEnd` → `session-end-hook.sh`** — closes the dock and deletes all of that
  session's state. `brief-prune.sh` (opportunistic, > 3 days idle) is the backstop
  for sessions that exit without firing `SessionEnd`.

### State files (`~/.claude/state/<sid>.*`)

Flat, one-fact-per-file — atomic writes + mtime checks, the idiomatic shell IPC
between the hooks, the worker, and the viewer:

| File | Written by | Read by | Purpose |
|---|---|---|---|
| `.brief.md` | worker | viewer | the rendered brief (markdown) |
| `.task` | prompt hook + worker | status line | `goal` / `prev` / `now` labels |
| `.brief.session` | brief-open | brief-open, session-end | `"<driver> <dock-id>"` — how to close the dock |
| `.brief.done` | worker | viewer | outcome word (`updated`/`unchanged`/`timeout`/`error`) |
| `.brief.size` | viewer | worker | pane `"rows cols"`, so the brief is sized to fit |
| `.brief.noauto` | viewer (`a` key) | Stop hook | end-of-turn auto-refresh turned off |
| `.skipped` | Stop hook | viewer | trivial-turn skip counter |
| `panes/<id>`, `cwds/<cwd>` | prompt hook | brief-open | pane / cwd → sid map (fallback; `$CLAUDE_CODE_SESSION_ID` wins) |

## Layout & install modes

The **repo root is the plugin root** — one self-locating script tree, two ways to run it:

```
.claude-plugin/   plugin.json (manifest) · marketplace.json (self-hosting marketplace)
hooks/            hooks.json · task-prompt-hook.sh task-summary-hook.sh task-summary-worker.sh
                  session-end-hook.sh session-start-hook.sh
bin/              brief-open.sh brief-view.sh brief-prune.sh brief-summarize.sh brief-summarize-api.sh brief-term-profile.sh
bin/lib/          terminal-driver.sh (detect + dispatch)   portable.sh (BSD/GNU stat shim)
bin/term/common/  tmux.sh kitty.sh wezterm.sh tabby.sh generic.sh   (cross-platform drivers)
bin/term/darwin/  iterm2.sh ghostty.sh terminal.sh                  (macOS-only drivers)
bin/term/linux/   (home for Linux-specific drivers; empty by default)
commands/brief.md
glow-brief.json
iterm2/DynamicProfiles/brief.json    (iterm2 dock profile: Default + 1.2× line spacing)
```

- **Plugin** — `claude --plugin-dir .` (dev) or `/plugin install` (users). Claude Code loads
  `commands/` + `hooks/hooks.json`, so the three hooks (UserPromptSubmit/Stop/SessionEnd) **plus** a
  one-time `SessionStart` setup auto-activate — no `settings.json` editing.
- **`install.sh`** — copies the script tree (`bin/`, `hooks/*.sh`, `commands/`, `glow-brief.json`,
  the iTerm2 profile) into `~/.claude` for the clone path; you then add the three hooks to
  `settings.json` by hand. `--check` runs only the dependency check.

The scripts are **self-locating**: each computes `ROOT` (the parent of its own dir, via
`BASH_SOURCE`) and resolves siblings as `$ROOT/bin/…`, `$ROOT/hooks/…`, `$ROOT/glow-brief.json` — so
the identical tree works whether `ROOT` is the plugin dir or `~/.claude`. **State always lives in
`~/.claude/state`** (never under the plugin), shared across both modes. Use one mode, not both, or
the `settings.json` hooks and the plugin hooks double-fire.

Dev loop: edit in the repo → test with `claude --plugin-dir .` (or `./install.sh` then `./test.sh`).

## Terminal drivers

The windowing — split the pane, run the viewer, close on exit — lives behind a tiny
driver contract. `bin/lib/terminal-driver.sh` resolves a driver *name* to a file and
sources it; exactly one set of `tdrv_*` functions is then in scope.

### The contract

A driver (`bin/term/{common,<os>}/<name>.sh`) defines:

```sh
tdrv_name                  # echo the driver's short name (MUST equal the filename stem)
tdrv_detect                # return 0 if it recognises the CURRENT terminal (auto-detection)
tdrv_self_pane             # echo the current pane's native id (fs-safe; '' if none)
tdrv_open MODE ANCHOR CMD… # create the dock (MODE=dock|float) beside ANCHOR, run CMD…,
                           #   echo the new pane/window id ('' on failure; hints to stderr)
tdrv_close PANEID          # close that dock by id (validate the id shape first)
```

and MAY define:

```sh
tdrv_rank                  # detection precedence 0-99 (default 50); a multiplexer
                           #   (tmux) returns a higher rank so the inner mux wins
```

`generic` is the fallback: it defines no `tdrv_detect`, and its `tdrv_open` is a
no-op — `brief-open` then prints the `brief-view.sh <sid>` command for the user to
run in a split they make themselves.

### Detection

Detection lives entirely in the drivers — there is **no hardcoded chain**.
`_brief_detect` probes every driver on the OS search path (`term/<os>/` then
`term/common/`, each sourced in a subshell) and the **highest-`tdrv_rank` match
wins**. tmux declares rank 90 so that inside a tmux pane — where the host terminal's
env vars are also visible — the inner multiplexer wins. Force a specific driver with
`BRIEF_TERMINAL=<name>` (a whitelisted lowercase-alnum name, never a path); point
`BRIEF_TERM_DIR` at a custom driver directory (which must use the same
`common/` + `<os>/` structure).

### Layout & OS isolation

- `term/common/` — cross-platform drivers (tmux, kitty, wezterm, tabby, generic).
- `term/<os>/` — OS-specific, `<os>` = lowercased `uname -s` (`darwin`, `linux`).
  The AppleScript drivers (iterm2, ghostty, terminal) live in `term/darwin/`.
- Resolution (`_brief_driver_file`): `term/<os>/<name>.sh` wins over
  `term/common/<name>.sh`. A macOS-only driver in `darwin/` is **simply not on
  Linux's search path**, so it can never be sourced there — that's how macOS + Linux
  drivers coexist with no per-driver OS guard. A built-in name with no driver for the
  current OS (e.g. `ghostty` on Linux) falls back to `generic`.

### Writing a driver

1. Create `term/common/<name>.sh` (cross-platform) or `term/<os>/<name>.sh`
   (OS-specific). The filename stem is the driver name.
2. Implement the contract (template below).
3. `./install.sh` (or `cp` it into `~/.claude/bin/term/...`). Test with
   `BRIEF_TERMINAL=<name>` then `/brief`; auto-detection follows from `tdrv_detect`.

```sh
# term/common/foo.sh — a terminal driver for Foo
tdrv_name(){ printf 'foo'; }
tdrv_detect(){ [ "${TERM_PROGRAM:-}" = Foo ]; }      # 0 = this is Foo
# tdrv_rank(){ printf 90; }                           # only if Foo is a multiplexer
tdrv_self_pane(){ printf '%s' "${FOO_PANE:-}"; }      # fs-safe per-pane id, or empty
tdrv_open(){
  _mode=$1 _anchor=$2; shift 2                         # CMD… = absolute brief-view.sh <sid>
  # … create a split (dock) or window (float) running "$@", keep focus on $_anchor …
  # … echo the new pane/window id; print a human hint to stderr on failure …
}
tdrv_close(){
  _id=$1; [ -n "$_id" ] || return 0
  case "$_id" in *[!0-9]*) return 0 ;; esac            # validate the id shape
  # … close the dock identified by $_id …
}
```

**Gotchas — hard-won; every existing driver hit at least one:**

- **No controlling tty.** `/brief` runs via Claude Code's Bash tool with **no tty**,
  so your open path can't need one. (kitty's `kitty @` needed a unix socket; WezTerm's
  `wezterm cli` and AppleScript both work tty-free.)
- **Minimal PATH.** A GUI-launched terminal spawns the dock with a minimal PATH, so
  the viewer's `#!/usr/bin/env bash` finds macOS bash 3.2 (not the bash 5 it needs)
  and `glow` is missing. **Inject the caller's `$PATH`** (kitty/WezTerm via `--env` /
  `/usr/bin/env PATH=…`; ghostty via the surface config's environment variables).
- **CMD is argv, not a shell line** — it's exec'd directly, so it must be an absolute
  path (no `PATH` search, no quoting).
- **The id round-trip.** brief-open writes `"<name> <dock-id>"` to
  `state/<sid>.brief.session`; at close time (possibly from a *different* terminal) it
  re-sources *your* driver and calls `tdrv_close` with that id. Encode whatever close
  needs INTO the id you return — ghostty/terminal pack `"<native-id>:<sid>"`.
- **Close-safety.** If you kill processes, scope the kill to the exact
  `brief-view.sh <sid>` (script + session). **Never blanket-kill a tty** — ttys/pids
  get recycled (a blanket kill once SIGTERM'd a live `claude`). Iterate pids in a
  `printf | while read; kill` loop so it's correct under any shell's word-splitting.
- **Refocus.** If your split/spawn steals keyboard focus, hand it back to the anchor
  so the user keeps typing in the session pane.

Cover it in `test.sh`: a hermetic stub-on-PATH test (stub the terminal's CLI on
`PATH`, assert the commands the driver emits) and — if the terminal is scriptable
headless — a real end-to-end check (see the kitty / wezterm / tmux / ghostty /
terminal blocks for both patterns).

## Portability

`bin/lib/portable.sh` is the one place the core reads file mtime/perms (`_mtime` /
`_perm`), detecting BSD (`stat -f`) vs GNU (`stat -c`) once — no other core script
calls `stat` directly. The hooks + drivers are bash-3.2-safe; only `brief-view.sh`
needs bash 5. The osascript drivers and `brief-term-profile.sh` are macOS-only and
self-gate (they no-op when `osascript` is absent).

## The summariser contract

`task-summary-worker.sh` builds the prompts, then delegates to `$BRIEF_SUMMARIZER`
(default `bin/brief-summarize.sh`, a lean Haiku `claude -p`). To swap models, point
it at your own script **under `~/.claude/`** — it's *executed*, so it's honoured only
from that trusted dir and must be a user-owned, non-world-writable executable.

The contract: read `$BRIEF_SYS` / `$BRIEF_USR`, write the model response to stdout
(`goal:` / `now:` + `===BRIEF===` + markdown, or just `UNCHANGED`); empty output or a
non-zero exit ⇒ a failure. The worker wraps the call in a `${BRIEF_SUMMARY_TIMEOUT:-90}`s
watchdog and backs off after repeated failures. `bin/brief-summarize-api.sh` is a
ready-made alternative that calls the Anthropic Messages API directly (~5× cheaper
than the CLI; see the README for the user-facing opt-in).

## Testing & linting

- `./test.sh` — integration-style regression tests against the LIVE `~/.claude`
  scripts, with throwaway hex-UUID sessions + fake summarisers (no real model calls).
  Exit status = number of failures. Includes hermetic driver-wiring tests and real
  headless end-to-end checks for tmux and WezTerm.
- **ShellCheck** — the tree is clean:
  ```
  shellcheck -s bash bin/*.sh bin/lib/*.sh bin/term/*/*.sh hooks/*.sh install.sh test.sh
  ```
  `.shellcheckrc` carries the project-wide disables (with reasons); narrow cases have
  inline `# shellcheck disable=` directives. Run it as a pre-commit gate.

## Releases & metrics

**Cut a release** by pushing a version tag — the [`release` workflow](.github/workflows/release.yml)
builds `claude-brief.tar.gz` and attaches it to a GitHub Release:
```
git tag -a v0.4.0 -m "claude-brief v0.4.0" && git push origin v0.4.0
```
The *attached asset* (not the auto-generated "Source code" archive) is what GitHub
counts in `download_count`, which drives the README downloads badge and the stable
`releases/latest/download/claude-brief.tar.gz` install URL.

**Clone/view traffic** is snapshotted daily by the [`traffic` workflow](.github/workflows/traffic.yml)
onto the orphan `traffic` branch, so the history outlives GitHub's 14-day window.
One-time `TRAFFIC_TOKEN` setup: [traffic/README.md](traffic/README.md).

## Design notes

Deeper gotchas — iTerm2 / Apple Terminal AppleScript quirks, headless-render traps,
the summary cost model — live in this project's Claude memory: `brief-dock-system`,
`iterm2-36-scripting-gotchas`, `terminal-headless-render-gotchas`, `brief-summary-cost`.
