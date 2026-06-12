#!/usr/bin/env bash
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"   # plugin root (or ~/.claude when installed)
# Open — or re-focus + reload — the docked pane showing this session's live brief.
# Singleton: re-running closes the old dock and creates a fresh one running the
# latest viewer. Terminal-agnostic via the pluggable driver layer
# (bin/lib/terminal-driver.sh): iTerm2 / tmux / kitty / Apple Terminal, plus a
# generic fallback. Run from /brief's bash (inherits the terminal's pane env).
#   usage: brief-open.sh [float|refresh|close|help]
#     (default) dock : side-by-side split in the current window (a companion
#                      window on Apple Terminal, which has no scriptable splits)
#     float          : a separate window instead
#     refresh        : regenerate the brief now (detached), then open the dock
#     close          : tear down this session's dock (no reopen)
#     help           : print usage + the in-dock keys + docs pointers; no dock action
#     debug          : print a sanitised diagnostic report (for bug reports); no dock action
arg="${1:-}"; refresh=0
case "$arg" in
  refresh) refresh=1; mode="dock" ;;
  float)   mode="float" ;;
  close)   mode="close" ;;
  help)    mode="help" ;;
  debug)   mode="debug" ;;
  *)       mode="dock" ;;
esac

# The slash command's name depends on the install path: bare /brief on a manual
# ~/.claude install, the namespaced /claude-brief:brief as a plugin (where ROOT is
# the plugin cache dir, not ~/.claude). Tab completes the prefix either way.
cmd="/claude-brief:brief"
[ "$ROOT" = "$HOME/.claude" ] && cmd="/brief"

# help: needs no session, driver, or dock — print and stop.
if [ "$mode" = help ]; then
  cat <<EOF
claude-brief — a live, auto-refreshing summary brief docked beside this session

usage: $cmd [float|refresh|close|help|debug]
       (type /brief and press Tab — autocomplete fills in the rest)
  (none)   open or re-focus the dock — a side-by-side split showing this
           session's brief (a companion window on Apple Terminal)
  float    open it as a separate window instead of a split
  refresh  regenerate the brief now, instead of waiting for the next turn
  close    tear the dock down — a clean, no-prompt close on every backend
  help     this text
  debug    print a sanitised diagnostic report to paste into a bug report
           (no env values, no brief/transcript content; runs one tiny probe
           summary call, so it can cost ~1c)

in-dock keys (click the dock pane first):
  r        refresh the brief now
  a        toggle auto-refresh at the end of each turn (default: on)
  i        toggle periodic refresh during a long turn (fires only on new activity)
  + / -    adjust the refresh interval (30s-1h)
  ?        key help
  q        close the dock

The brief updates after each turn that does real work (a small cost-gated Haiku
call; trivial turns are skipped). Force a terminal backend with
BRIEF_TERMINAL=<iterm2|tmux|kitty|wezterm|ghostty|terminal|tabby|generic>.

Full docs (README): https://github.com/tigerquoll/claude-brief#readme
EOF
  [ -f "$ROOT/README.md" ] && echo "Installed copy:      $ROOT/README.md"
  exit 0
fi

state_dir="$HOME/.claude/state"
. "$ROOT/bin/lib/terminal-driver.sh"   # provides tdrv_name/self_pane/open/close

# --- Resolve the session id of the pane we were invoked in ----------------
sid=""; via=""
# 0) AUTHORITATIVE: the session id Claude Code exports into the command's shell
#    ($CLAUDE_CODE_SESSION_ID, set since CC 2.1.132). This is the session /brief was
#    actually invoked in — correct for a FRESH or just-/clear'd session that has no
#    brief or pane/cwd map yet, where the heuristics below would otherwise fall
#    through to "newest brief" and dock SOME OTHER session. Only the env var is
#    trusted here; everything else is a fallback for older Claude Code.
if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  case "$CLAUDE_CODE_SESSION_ID" in
    *[!0-9a-fA-F-]*) : ;;                                   # not UUID-shaped -> ignore
    *) sid="$CLAUDE_CODE_SESSION_ID"; via="env" ;;
  esac
fi
# 1) terminal pane id (per-pane: correct even with two tabs in the same dir). The
#    driver already returns a value safe to use; whitelist once more for the key.
#    ALWAYS computed — $pane is also the split anchor passed to tdrv_open below.
pane=$(tdrv_self_pane); pane=$(printf '%s' "$pane" | tr -dc '0-9A-Za-z%:_-')
if [ -z "$sid" ] && [ -n "$pane" ]; then
  pf="$state_dir/panes/$pane"
  [ -f "$pf" ] && { sid=$(cat "$pf"); via="pane"; }
fi
# 2) working directory
if [ -z "$sid" ]; then
  cf="$state_dir/cwds/$(printf '%s' "$PWD" | tr '/ ' '__')"
  [ -f "$cf" ] && { sid=$(cat "$cf"); via="cwd"; }
fi
# 3) last resort: most recently updated brief (only reliable when single-session)
if [ -z "$sid" ]; then
  newest=$(ls -t "$state_dir"/*.brief.md 2>/dev/null | head -1)
  [ -n "$newest" ] && { sid=$(basename "$newest" .brief.md); via="newest"; }
fi

if [ -z "$sid" ] && [ "$mode" != debug ]; then   # debug still reports without a sid
  echo "brief: couldn't determine the current session id (no pane/cwd map, no briefs yet)"; exit 1
fi
# Defense-in-depth: sid is interpolated into the driver's launch command, so
# require a UUID-shaped value (hex + dashes only) and refuse anything else.
case "$sid" in *[!0-9a-fA-F-]*)
  if [ "$mode" = debug ]; then sid=""
  else echo "brief: refusing — session id is not UUID-shaped"; exit 1; fi ;;
esac

# /brief debug: a copy-pasteable diagnostic report — no dock action. SANITISED BY
# ALLOWLIST: only presence/shape/enum facts are collected (env VALUES are never
# read into the report — lengths only), $HOME renders as ~, and the one
# free-text field (probe stderr) is scrubbed of key-shaped strings and capped.
# Safe to paste into a public GitHub issue.
if [ "$mode" = debug ]; then
  . "$ROOT/bin/lib/portable.sh"          # _mtime/_perm
  now=$(date +%s)
  scrub(){ # free text -> printable ASCII, $HOME->~, key-shaped strings masked, capped
    printf '%s' "${1//$HOME/\~}" | LC_ALL=C tr -cd ' -~' \
      | sed -E -e 's/sk-ant-[A-Za-z0-9_-]+/sk-ant-.../g' -e 's/[Bb]earer +[^ ]+/Bearer .../g' \
      | cut -c1-200; }
  shape(){ # env var NAME -> "set(len N)" | blank | unset — never the value
    if eval "[ -z \"\${$1+x}\" ]"; then echo unset
    elif eval "[ -z \"\$$1\" ]"; then echo blank
    else eval "echo \"set(len \${#$1})\""; fi; }
  agef(){ local m; m=$(_mtime "$1"); [ "$m" = 0 ] && { echo absent; return; }; echo "$((now - m))s ago"; }

  echo "claude-brief debug report ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo
  echo "[install]"
  inst="plugin"; [ "$ROOT" = "$HOME/.claude" ] && inst="manual"
  echo "root:             ${ROOT//$HOME/\~}  [$inst install]"
  pv="unknown"
  [ -f "$ROOT/.claude-plugin/plugin.json" ] && command -v jq >/dev/null 2>&1 \
    && pv=$(jq -r '.version // "unset"' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null)
  echo "plugin version:   $pv"
  if [ "$inst" = plugin ] && [ -f "$HOME/.claude/hooks/task-summary-hook.sh" ]; then
    echo "WARNING:          a manual ~/.claude install is ALSO present — hooks may double-fire"
  fi
  echo "claude CLI:       $(perl -e 'alarm shift @ARGV; exec @ARGV' 8 claude --version 2>/dev/null | head -1 || echo not-found)"
  echo "bash:             $BASH_VERSION   os: $(uname -sr)"
  deps=""; for d in jq glow bat perl; do
    command -v "$d" >/dev/null 2>&1 && deps="$deps$d " || deps="$deps$d(MISSING) "; done
  echo "deps:             $deps"
  echo "terminal:         $(tdrv_name)   TERM_PROGRAM: ${TERM_PROGRAM:-unset}"
  echo
  echo "[session]"
  if [ -n "$sid" ]; then
    echo "sid:              ${sid:0:8} (via=$via)"
    f="$state_dir/$sid.brief.md"
    echo "brief.md:         $([ -f "$f" ] && echo "present ($(agef "$f"))" || echo absent)"
    f="$state_dir/$sid.brief.done"
    echo "last outcome:     $([ -f "$f" ] && echo "$(cat "$f" | head -1 | cut -c1-20) ($(agef "$f"))" || echo "none recorded")"
    f="$state_dir/$sid.brief.fail"
    if [ -f "$f" ]; then
      read -r fc ft _ < "$f" 2>/dev/null
      case "$fc" in ''|*[!0-9]*) fc=0 ;; esac; case "$ft" in ''|*[!0-9]*) ft=0 ;; esac
      left=$((600 - (now - ft))); bk="inactive"
      [ "$fc" -ge 3 ] && [ "$left" -gt 0 ] && bk="ACTIVE, ${left}s left"
      echo "failures:         $fc consecutive, last $((now - ft))s ago (backoff: $bk)"
    else
      echo "failures:         none recorded"
    fi
    f="$state_dir/$sid.brief.err"
    echo "last failure:     $([ -f "$f" ] && scrub "$(cat "$f")" || echo "none recorded")"
    f="$state_dir/$sid.skipped"
    echo "last turn gated:  $([ -f "$f" ] && echo "yes ($(agef "$f"))" || echo no)"
    f="$state_dir/$sid.brief.session"
    echo "dock open:        $([ -f "$f" ] && echo "yes ($(agef "$f"))" || echo no)"
  else
    echo "sid:              UNRESOLVED — no \$CLAUDE_CODE_SESSION_ID, pane/cwd map, or briefs"
  fi
  w="$state_dir/.brief-summarizer-warn"
  echo "warn:             $([ -f "$w" ] && scrub "$(cat "$w")" || echo none)"
  echo
  echo "[dock]"
  echo "driver:           $(tdrv_name)   override: ${BRIEF_TERMINAL:-none}"
  sig=""
  [ -n "${TMUX:-}" ]             && sig="${sig}TMUX "
  [ -n "${TERM_PROGRAM:-}" ]     && sig="${sig}TERM_PROGRAM=${TERM_PROGRAM} "
  [ -n "${KITTY_WINDOW_ID:-}" ]  && sig="${sig}KITTY_WINDOW_ID "
  [ -n "${WEZTERM_PANE:-}" ]     && sig="${sig}WEZTERM_PANE "
  [ -n "${ITERM_SESSION_ID:-}" ] && sig="${sig}ITERM_SESSION_ID "
  [ -n "${TERM_SESSION_ID:-}" ]  && sig="${sig}TERM_SESSION_ID "
  echo "signals:          ${sig:-none}"
  echo "self pane:        $([ -n "$pane" ] && echo "resolved ($(printf '%s' "$pane" | cut -c1-12))" || echo "EMPTY - split anchoring and pane->sid mapping unavailable")"
  sf="$state_dir/$sid.brief.session"
  if [ -n "$sid" ] && [ -f "$sf" ]; then
    sold=$(cat "$sf"); sdrv=${sold%% *}; spid=${sold#* }   # MIRROR of the reload parse above
    [ "$sdrv" = "$spid" ] && sdrv=iterm2                   # legacy single-token => iterm2
    mm=""; [ "$sdrv" != "$(tdrv_name)" ] && mm="  MISMATCH vs detected driver"
    echo "dock session:     driver=$sdrv pane=$(printf '%s' "$spid" | cut -c1-12)$mm"
  else
    echo "dock session:     none recorded"
  fi
  if type tdrv_preflight >/dev/null 2>&1; then
    # The osascript-based preflights can pop the one-time Automation approval.
    tdrv_preflight 2>&1 | head -6 | while IFS= read -r l; do
      printf 'preflight:        %s\n' "$(scrub "$l")"
    done
  else
    echo "preflight:        none for this backend"
  fi
  # The dock pane runs the viewer under a LOGIN-shell PATH (not this session's),
  # so bash 3.2 there means the pane opens and instantly dies. tail -1 keeps only
  # our echo, not anything the user's login rc prints.
  lb=$(perl -e 'alarm shift @ARGV; exec @ARGV' 8 bash -lc 'echo "$BASH_VERSION"' 2>/dev/null | tail -1)
  lbnote=""; case "${lb%%.*}" in ''|*[!0-9]*|[0-4]) lbnote="  (dock viewer needs bash >= 5 on the login-shell PATH)" ;; esac
  echo "login-shell bash: ${lb:-unknown}$lbnote"
  de="$state_dir/.brief-dock-err"
  echo "last dock error:  $([ -f "$de" ] && scrub "$(cat "$de")" || echo none)"
  echo
  echo "[summariser]"
  bs="${BRIEF_SUMMARIZER-}"
  verdict="honoured"
  if [ -z "$bs" ]; then
    echo "BRIEF_SUMMARIZER: unset"
  else
    # MIRROR of task-summary-worker.sh validation — keep in sync
    case "$bs" in
      *..*) verdict="REJECTED: path contains .." ;;
      "$HOME"/.claude/*|"$ROOT"/*)
        perm=$(_perm "$bs")
        if   [ ! -f "$bs" ]; then verdict="REJECTED: no such file"
        elif [ ! -x "$bs" ]; then verdict="REJECTED: not executable"
        elif [ ! -O "$bs" ]; then verdict="REJECTED: not owned by you"
        elif (( 8#$perm & 0022 )); then verdict="REJECTED: group/other-writable"
        fi ;;
      "~"*) verdict="REJECTED: literal ~ (unexpanded; use \$HOME)" ;;
      *)    verdict="REJECTED: outside ~/.claude and the plugin root" ;;
    esac
    echo "BRIEF_SUMMARIZER: ${bs//$HOME/\~} -> $verdict"
  fi
  echo "BRIEF_AUTO_API:   ${BRIEF_AUTO_API:-unset}"
  src=$("$ROOT/bin/brief-summarize-api.sh" --check 2>/dev/null) || src=""
  echo "api --check:      ${src:-no credentials resolved}"
  for v in ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY \
           ANTHROPIC_DEFAULT_HAIKU_MODEL BRIEF_API_BASE BRIEF_API_TOKEN \
           BRIEF_API_MODEL BRIEF_SUMMARY_TIMEOUT; do
    printf '%-30s %s\n' "$v:" "$(shape "$v")"
  done
  echo "endpoint:         $([ -n "${ANTHROPIC_BASE_URL:-}" ] && echo custom || echo default)  (values never included)"
  f="$HOME/.claude/brief-summarizer.env"
  echo "summarizer.env:   $([ -f "$f" ] && echo "present (perms $(_perm "$f"))" || echo absent)"
  echo
  echo "[probe] one tiny summary call, 20s cap"
  # What the worker would pick (MIRROR, simplified — the api-key approval check
  # happens at worker runtime, so an unapproved key probes the CLI default here).
  probe="$ROOT/bin/brief-summarize.sh"; which_p="cli-default"
  if [ -n "$bs" ] && [ "$verdict" = honoured ]; then
    probe="$bs"; which_p="explicit override"
  else
    case "${BRIEF_AUTO_API:-}" in
      0|false) ;;
      *) case "$src" in brief|auth-token) probe="$ROOT/bin/brief-summarize-api.sh"; which_p="api-direct (auto)" ;; esac ;;
    esac
  fi
  run_probe(){ # $1=script $2=label — prints result/stderr lines for one probe call
    local perr t0 pout prc pdur pres el
    perr=$(mktemp "${TMPDIR:-/tmp}/brief-dbg.XXXXXX")
    t0=$(date +%s)
    pout=$(BRIEF_SYS="Reply with the single word OK." BRIEF_USR="OK?" CLAUDE_TASK_SUMMARY=1 \
           perl -e 'alarm shift @ARGV; exec @ARGV' 20 "$1" 2>"$perr")
    prc=$?
    pdur=$(( $(date +%s) - t0 ))
    pres="rc=$prc in ${pdur}s, output: $([ -n "$(printf '%s' "$pout" | tr -d '[:space:]')" ] && echo yes || echo EMPTY)"
    case "$prc" in 124|142) pres="$pres (TIMEOUT — the call hung)" ;; esac
    printf '%-18s%s\n' "$2" "$pres"
    el=$(head -1 "$perr" 2>/dev/null); rm -f "$perr"
    [ -n "$el" ] && printf '%-18s%s\n' "  stderr:" "$(scrub "$el")"
    return "$prc"
  }
  echo "summariser:       $which_p"
  if ! run_probe "$probe" "result:"; then
    # Mirror the worker: an auto-selected API path that fails fast falls back to
    # the CLI default — probe that too, so "probe failed but briefs still work"
    # reads as the fallback saving the turn, not a contradiction.
    if [ "$which_p" = "api-direct (auto)" ]; then
      run_probe "$ROOT/bin/brief-summarize.sh" "cli fallback:" || true
    fi
  fi
  exit 0
fi

# /brief refresh: regenerate the brief NOW (detached); the dock picks up the new
# brief.md via its mtime watch a few seconds later. Otherwise the brief refreshes
# only on the next completed turn.
if [ "$refresh" = 1 ]; then
  tp=$(ls -t "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)
  [ -n "$tp" ] && nohup "$ROOT/hooks/task-summary-worker.sh" "$sid" "$tp" >/dev/null 2>&1 &
fi

sess_file="$state_dir/$sid.brief.session"   # "<driver> <dock-pane-id>"

# Reload model: CLOSE the previous dock first (via whichever driver opened it —
# possibly different from the current one), then open a fresh one. Two steps rather
# than one atomic script, but the close completes before the open begins.
if [ -f "$sess_file" ]; then
  old=$(cat "$sess_file")
  oldname=${old%% *}; oldid=${old#* }
  [ "$oldname" = "$oldid" ] && oldname=iterm2        # legacy single-token => iterm2
  case "$oldname" in *[!a-z0-9]*) oldname="" ;; esac  # only honour a clean driver name
  if [ -n "$oldname" ] && [ -n "$oldid" ]; then
    # shellcheck disable=SC2034  # BRIEF_TERMINAL is read by the sourced terminal-driver.sh
    ( BRIEF_TERMINAL="$oldname"; . "$ROOT/bin/lib/terminal-driver.sh"; tdrv_close "$oldid" )
  fi
fi

# /brief close: the dock (if any) is now torn down — drop the session file and stop,
# no reopen. (The close above ran via whichever driver opened it.)
if [ "$mode" = close ]; then
  if [ -f "$sess_file" ]; then rm -f "$sess_file"; echo "brief: dock closed for ${sid:0:8}"
  else echo "brief: no dock open for ${sid:0:8}"; fi
  exit 0
fi

# Capture the driver's stderr so a failed open leaves evidence: drivers explain
# themselves there (osascript errors, `kitty @` refusals, setup hints), and that
# was previously discarded. It still flows through to OUR stderr (the hints are
# user-facing); on failure it's also persisted to .brief-dock-err for /brief
# debug, and any earlier error is cleared on success.
dock_errf="$state_dir/.brief-dock-err"
derr=$(mktemp "${TMPDIR:-/tmp}/brief-dock.XXXXXX")
new_id=$(tdrv_open "$mode" "$pane" "$ROOT/bin/brief-view.sh" "$sid" 2>"$derr"); open_rc=$?
cat "$derr" >&2
if [ -n "$new_id" ]; then
  rm -f "$dock_errf"
elif [ "$(tdrv_name)" != generic ] && [ "$(tdrv_name)" != tabby ]; then   # those two can't auto-dock by design
  { printf '%s %s (rc=%s): ' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(tdrv_name)" "$open_rc"
    if [ -s "$derr" ]; then tr '\n' ' ' < "$derr" | cut -c1-300; else printf 'no stderr from the driver'; fi
    echo; } > "$dock_errf"
fi
rm -f "$derr"

if [ -n "$new_id" ]; then
  printf '%s %s\n' "$(tdrv_name)" "$new_id" > "$sess_file"
  echo "brief: dock ready for ${sid:0:8} (via=$via, term=$(tdrv_name), mode=$mode)"
  # One-time first-run hint (sentinel-gated, like the glow note in session-start):
  # point at the dock's own help key and the fuller /brief help.
  hint_sentinel="$state_dir/.brief-help-hinted"
  if [ ! -f "$hint_sentinel" ]; then
    : > "$hint_sentinel"
    echo "brief: first dock — click the dock pane and press ? for its keys; $cmd help has the full rundown (README: https://github.com/tigerquoll/claude-brief#readme)"
  fi
elif [ "$(tdrv_name)" = generic ] || [ "$(tdrv_name)" = tabby ]; then
  # generic + tabby can't script a dock; the driver may have printed a terminal-
  # specific hint to stderr — print the exact viewer command to run by hand.
  echo "brief: no auto-dock for this terminal — open the viewer in a split/window you create:"
  echo "       $ROOT/bin/brief-view.sh $sid"
  exit 0
else
  echo "brief: couldn't open the dock (term=$(tdrv_name), sid=${sid:0:8}, via=$via, mode=$mode)"
  exit 1
fi
