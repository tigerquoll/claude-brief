#!/usr/bin/env bash
# Regression tests for the brief-dock scripts. Run after ./install.sh (or ./sync.sh)
# — it exercises the LIVE ~/.claude scripts. Integration-style: drives the real
# worker/hooks with throwaway (hex-UUID) session ids and FAKE summarisers placed
# under ~/.claude/bin (so they pass the path confinement), checking outcomes/state.
# A few pure bits (summariser-path validation, viewer math) are REPLICATED here and
# marked "MIRROR" — keep them in sync with the source if that logic changes.
# Safe to re-run; cleans up its own sids/fakes. Exit status = number of failures.
set -u
H="$HOME/.claude"; HOOKS="$H/hooks"; BIN="$H/bin"; ST="$H/state"; TP=/nonexistent.jsonl
W="$HOOKS/task-summary-worker.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s — got [%s] want [%s]\n' "$1" "$2" "$3"; }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "$2" "$3"; }
mkfake(){ printf '%s' "$2" > "$BIN/$1"; chmod 755 "$BIN/$1"; }

S=feed0000-0000-0000-0000-000000000000          # throwaway, UUID-shaped
wipe(){ rm -f "$ST/$S".* 2>/dev/null; rmdir "$ST/$S.brief.lock" 2>/dev/null; }
trap 'wipe; rm -f "$BIN"/t-*.sh "$BIN/term/common/fake.sh" /tmp/t-* 2>/dev/null' EXIT

mkfake t-ok.sh   $'#!/usr/bin/env bash\nprintf "goal: g\\nnow: GOOD\\n===BRIEF===\\n# T\\n## State\\n- s\\n## Tried\\n—\\n## Gotchas\\n—\\n## Decisions\\n—\\n## Next / Open\\n- n\\n"\n'
mkfake t-unch.sh $'#!/usr/bin/env bash\nprintf "goal: g\\nnow: n\\n===BRIEF===\\nUNCHANGED\\n"\n'
mkfake t-fail.sh $'#!/usr/bin/env bash\nexit 1\n'

echo "WORKER — outcomes"
wipe; BRIEF_SUMMARIZER="$BIN/t-ok.sh"   "$W" "$S" "$TP";              is "updated"   "$(cat "$ST/$S.brief.done")" updated
      BRIEF_SUMMARIZER="$BIN/t-unch.sh" "$W" "$S" "$TP";              is "unchanged" "$(cat "$ST/$S.brief.done")" unchanged
wipe; BRIEF_SUMMARIZER="$BIN/t-fail.sh" "$W" "$S" "$TP";              is "error"     "$(cat "$ST/$S.brief.done")" error

echo "WORKER — last-good label kept on failure"
wipe; BRIEF_SUMMARIZER="$BIN/t-ok.sh"   "$W" "$S" "$TP" >/dev/null
      BRIEF_SUMMARIZER="$BIN/t-fail.sh" "$W" "$S" "$TP"
      is "now stays GOOD" "$(sed -n 's/^▸ now:  //p' "$ST/$S.task")" GOOD

echo "WORKER — retry (fail then succeed in one invocation)"
wipe; rm -f /tmp/t-rc
mkfake t-retry.sh $'#!/usr/bin/env bash\nc=/tmp/t-rc;n=$(cat "$c" 2>/dev/null||echo 0);n=$((n+1));echo "$n">"$c"\n[ "$n" -ge 2 ] && printf "goal: g\\nnow: n\\n===BRIEF===\\n# R\\n## State\\n- s\\n## Next / Open\\n- n\\n"\n'
      BRIEF_SUMMARIZER="$BIN/t-retry.sh" "$W" "$S" "$TP"
      is "ran twice"      "$(cat /tmp/t-rc)" 2
      is "retry -> updated" "$(cat "$ST/$S.brief.done")" updated

echo "WORKER — failure backoff"
mkfake t-mark.sh $'#!/usr/bin/env bash\necho ran >>/tmp/t-ran\nprintf "goal: g\\nnow: n\\n===BRIEF===\\n# x\\n## State\\n- s\\n## Next / Open\\n- n\\n"\n'
wipe; printf '3 %s\n' "$(date +%s)" > "$ST/$S.brief.fail"; rm -f /tmp/t-ran
      BRIEF_SUMMARIZER="$BIN/t-mark.sh" "$W" "$S" "$TP"
      is "3 recent fails -> skip" "$([ -f /tmp/t-ran ] && echo called || echo skipped)" skipped
wipe; printf '3 %s\n' "$(($(date +%s)-700))" > "$ST/$S.brief.fail"; rm -f /tmp/t-ran
      BRIEF_SUMMARIZER="$BIN/t-mark.sh" "$W" "$S" "$TP"
      is "cooldown expired -> run" "$([ -f /tmp/t-ran ] && echo called || echo skipped)" called
      is "reset on success"        "$([ -f "$ST/$S.brief.fail" ] && echo kept || echo reset)" reset

echo "WORKER — budget tiers"
mkfake t-echo.sh $'#!/usr/bin/env bash\nprintf "%s" "$BRIEF_USR" | head -1 > /tmp/t-usr\nprintf "goal: g\\nnow: n\\n===BRIEF===\\n# x\\n## State\\n- s\\n## Next / Open\\n- n\\n"\n'
wipe; printf '12 60\n' > "$ST/$S.brief.size"; BRIEF_SUMMARIZER="$BIN/t-echo.sh" "$W" "$S" "$TP"
      is "small pane tier" "$(grep -o 'SMALL pane' /tmp/t-usr)" "SMALL pane"
wipe; printf '60 120\n' > "$ST/$S.brief.size"; BRIEF_SUMMARIZER="$BIN/t-echo.sh" "$W" "$S" "$TP"
      is "roomy pane tier" "$(grep -o 'ROOMY pane' /tmp/t-usr)" "ROOMY pane"

echo "WORKER — lock coalesces concurrent runs"
wipe; rm -f /tmp/t-lc
mkfake t-hold.sh $'#!/usr/bin/env bash\necho x >>/tmp/t-lc\nperl -e "select(undef,undef,undef,2)"\nprintf "goal: g\\nnow: n\\n===BRIEF===\\n# x\\n## State\\n- s\\n## Next / Open\\n- n\\n"\n'
      BRIEF_SUMMARIZER="$BIN/t-hold.sh" "$W" "$S" "$TP" &   ap=$!
      perl -e 'select(undef,undef,undef,0.4)'
      BRIEF_SUMMARIZER="$BIN/t-hold.sh" "$W" "$S" "$TP"
      wait "$ap"
      is "only one ran" "$(wc -l < /tmp/t-lc | tr -d ' ')" 1

echo "WORKER — \$BRIEF_SUMMARIZER path validation (MIRROR of task-summary-worker.sh)"
resolve(){ # echoes "override" if the value would be honoured, else "default"
  local v=$1 out="default" perm; perm=$(stat -f %Lp "$v" 2>/dev/null || echo 777)
  case "$v" in
    *..*) ;;
    "$HOME"/.claude/*) [ -f "$v" ] && [ -x "$v" ] && [ -O "$v" ] && ! (( 8#$perm & 0002 )) && out="override" ;;
  esac
  echo "$out"
}
in1="$BIN/t-ok.sh"; out1=/tmp/t-out.sh; printf '#!/bin/sh\n' >"$out1"; chmod 755 "$out1"
ww="$BIN/t-ww.sh";  printf '#!/bin/sh\n' >"$ww"; chmod 757 "$ww"
is "under ~/.claude honoured" "$(resolve "$in1")" override
is "outside ~/.claude rejected" "$(resolve "$out1")" default
is "world-writable rejected"  "$(resolve "$ww")" default
is "relative rejected"        "$(resolve "evil.sh")" default
is "traversal rejected"       "$(resolve "$HOME/.claude/../tmp/x")" default
rm -f "$out1" "$ww"

echo "STOP HOOK — cost gate + noauto (stubbed worker launch)"
stub=/tmp/t-stop.sh
perl -0777 -pe 's/nohup "\$HOME\/\.claude\/hooks\/task-summary-worker\.sh".*?&\n/echo SPAWNED > \$SENTINEL\n/s' "$HOOKS/task-summary-hook.sh" > "$stub"
run_stop(){ rm -f /tmp/t-spawn "$ST/$S.tlines" "$ST/$S.skipped"; export SENTINEL=/tmp/t-spawn
  printf '{"session_id":"%s","transcript_path":"%s"}' "$S" "$1" | bash "$stub"
  [ -f /tmp/t-spawn ] && echo spawned || echo skipped; }
triv=/tmp/t-triv.jsonl; printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}' > "$triv"
tool=/tmp/t-tool.jsonl; printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}' > "$tool"
wipe; is "trivial turn skipped"   "$(run_stop "$triv")" skipped
wipe; is "tool-use turn summarised" "$(run_stop "$tool")" spawned
wipe; : > "$ST/$S.brief.noauto"; is "noauto -> skipped" "$(run_stop "$tool")" skipped

echo "SESSION-END — teardown + isolation + recursion guard"
O=bbbbbbbb-1111-1111-1111-111111111111
wipe; rm -f "$ST/$O".*; : > "$ST/$S.brief.md"; : > "$ST/$S.task"; : > "$ST/$O.brief.md"
printf '%s\n' "$S" > "$ST/panes/T-PANE" 2>/dev/null || { mkdir -p "$ST/panes"; printf '%s\n' "$S" > "$ST/panes/T-PANE"; }
printf '{"session_id":"%s"}' "$S" | bash "$HOOKS/session-end-hook.sh"
is "session files removed" "$(ls "$ST/$S".* 2>/dev/null | wc -l | tr -d ' ')" 0
is "pane map removed"      "$([ -f "$ST/panes/T-PANE" ] && echo kept || echo gone)" gone
is "other session kept"    "$([ -f "$ST/$O.brief.md" ] && echo kept || echo gone)" kept
: > "$ST/$S.brief.md"
printf '{"session_id":"%s"}' "$S" | CLAUDE_TASK_SUMMARY=1 bash "$HOOKS/session-end-hook.sh"
is "recursion guard holds"  "$([ -f "$ST/$S.brief.md" ] && echo kept || echo gone)" kept
rm -f "$ST/$O".* "$ST/panes/T-PANE"

echo "API PLUGIN — config precedence + parse + token guard"
is "BRIEF_API_TOKEN wins" "$( unset ANTHROPIC_AUTH_TOKEN BRIEF_API_TOKEN; ANTHROPIC_AUTH_TOKEN=main; BRIEF_API_TOKEN=sum; echo "${BRIEF_API_TOKEN:-$ANTHROPIC_AUTH_TOKEN}" )" sum
is "ANTHROPIC fallback"   "$( unset ANTHROPIC_AUTH_TOKEN BRIEF_API_TOKEN; ANTHROPIC_AUTH_TOKEN=main; echo "${BRIEF_API_TOKEN:-$ANTHROPIC_AUTH_TOKEN}" )" main
is "parse content text"   "$(printf '%s' '{"content":[{"type":"text","text":"hello"}]}' | jq -r '[.content[]?|select(.type=="text")|.text]|join("")')" hello
is "error reply -> empty" "$(printf '%s' '{"error":{"type":"x"}}' | jq -r '[.content[]?|select(.type=="text")|.text]|join("")')" ""
( unset ANTHROPIC_AUTH_TOKEN BRIEF_API_TOKEN; BRIEF_SYS=x BRIEF_USR=y "$BIN/brief-summarize-api.sh" >/dev/null 2>&1 )
is "no token -> exit 1"   "$?" 1

echo "VIEWER MATH — fmt_int / agebucket / interval ladder (MIRROR of brief-view.sh)"
fmt_int(){ local s=$1; if [ "$s" -lt 60 ];then printf '%ss' "$s";elif [ "$s" -lt 3600 ];then printf '%dm' "$((s/60))";else printf '%dh' "$((s/3600))";fi; }
is "fmt 30s"  "$(fmt_int 30)" 30s
is "fmt 5m"   "$(fmt_int 300)" 5m
is "fmt 1h"   "$(fmt_int 3600)" 1h
agebucket(){ local a=$1
  if   [ "$a" -lt 15 ];   then echo "just now"
  elif [ "$a" -lt 30 ];   then echo "15s ago"
  elif [ "$a" -lt 45 ];   then echo "30s ago"
  elif [ "$a" -lt 60 ];   then echo "45s ago"
  elif [ "$a" -lt 120 ];  then echo "1m ago"
  elif [ "$a" -lt 300 ];  then echo "2m ago"
  elif [ "$a" -lt 2700 ]; then echo "(mid)"
  elif [ "$a" -lt 3600 ]; then echo "45m ago"
  else                         echo "1h+ ago"; fi; }
is "age just now" "$(agebucket 5)" "just now"
is "age 30s"      "$(agebucket 40)" "30s ago"
is "age 2m"       "$(agebucket 200)" "2m ago"
is "age 45m"      "$(agebucket 2700)" "45m ago"
LADDER=(30 60 120 300 600 1200 1800 3600)
snap(){ local v=$1 idx=3 best=2147483647 i d; for i in "${!LADDER[@]}"; do d=$(( LADDER[i]>v ? LADDER[i]-v : v-LADDER[i] )); [ "$d" -lt "$best" ] && { best=$d; idx=$i; }; done; echo "${LADDER[idx]}"; }
is "snap 420->300"  "$(snap 420)" 300
is "snap 700->600"  "$(snap 700)" 600
is "snap 5000->3600" "$(snap 5000)" 3600

echo "PORTABLE — _mtime/_perm pick the right stat flavor (BSD vs GNU, stubbed)"
# The core uses _mtime/_perm (bin/lib/portable.sh) instead of raw `stat`, so it runs
# on Linux (GNU stat) as well as macOS (BSD stat). Stub each `stat` flavour on PATH
# to prove the shim selects the right flags on BOTH — independent of this host's OS.
PD=$(mktemp -d "${TMPDIR:-/tmp}/t-port.XXXXXX"); mkdir -p "$PD/gnu" "$PD/bsd"
printf '%s' $'#!/usr/bin/env bash\ncase "$1" in -c) case "$2" in %Y) echo 111;; %a) echo 640;; *) exit 1;; esac;; *) exit 1;; esac\n' > "$PD/gnu/stat"
printf '%s' $'#!/usr/bin/env bash\ncase "$1" in -f) case "$2" in %m) echo 222;; %Lp) echo 750;; *) exit 1;; esac;; -c) echo "illegal option -- c">&2; exit 1;; *) exit 1;; esac\n' > "$PD/bsd/stat"
chmod +x "$PD/gnu/stat" "$PD/bsd/stat"
is "GNU stat -> _mtime via -c %Y" "$(PATH="$PD/gnu:$PATH" bash -c '. "'"$BIN"'/lib/portable.sh"; _mtime x')" 111
is "GNU stat -> _perm via -c %a"  "$(PATH="$PD/gnu:$PATH" bash -c '. "'"$BIN"'/lib/portable.sh"; _perm x')" 640
is "BSD stat -> _mtime via -f %m" "$(PATH="$PD/bsd:$PATH" bash -c '. "'"$BIN"'/lib/portable.sh"; _mtime x')" 222
is "BSD stat -> _perm via -f %Lp" "$(PATH="$PD/bsd:$PATH" bash -c '. "'"$BIN"'/lib/portable.sh"; _perm x')" 750
rm -rf "$PD"

echo "TERMINAL DRIVER — auto-detection precedence + \$BRIEF_TERMINAL whitelist"
LIB="$BIN/lib/terminal-driver.sh"
# Source the live driver lib in a clean env with controlled terminal vars; echo
# the chosen driver. env -i wipes PATH but tdrv_name only printf's, so that's fine.
drv(){ env -i HOME="$HOME" PATH="$PATH" "$@" bash -c '. "'"$LIB"'" >/dev/null 2>&1; tdrv_name'; }
is "tmux wins over iterm2"   "$(drv TMUX=x ITERM_SESSION_ID=w:abc BRIEF_TERMINAL=auto)" tmux
is "kitty detected"         "$(drv KITTY_WINDOW_ID=3 BRIEF_TERMINAL=auto)" kitty
is "wezterm via TERM_PROGRAM" "$(drv TERM_PROGRAM=WezTerm BRIEF_TERMINAL=auto)" wezterm
is "wezterm via WEZTERM_PANE" "$(drv WEZTERM_PANE=0 BRIEF_TERMINAL=auto)" wezterm
is "tmux wins over wezterm"  "$(drv TMUX=x WEZTERM_PANE=0 BRIEF_TERMINAL=auto)" tmux
is "tabby via TERM_PROGRAM"  "$(drv TERM_PROGRAM=Tabby BRIEF_TERMINAL=auto)" tabby
is "tabby via config-dir env" "$(drv TABBY_CONFIG_DIRECTORY=/x BRIEF_TERMINAL=auto)" tabby
is "tmux wins over tabby"    "$(drv TMUX=x TERM_PROGRAM=Tabby BRIEF_TERMINAL=auto)" tmux
is "ghostty via TERM_PROGRAM" "$(drv TERM_PROGRAM=ghostty BRIEF_TERMINAL=auto)" ghostty
is "ghostty via GHOSTTY env"  "$(drv GHOSTTY_RESOURCES_DIR=/x BRIEF_TERMINAL=auto)" ghostty
is "tmux wins over ghostty"  "$(drv TMUX=x TERM_PROGRAM=ghostty BRIEF_TERMINAL=auto)" tmux
is "iterm2 detected"        "$(drv ITERM_SESSION_ID=w:abc BRIEF_TERMINAL=auto)" iterm2
is "apple terminal detected" "$(drv TERM_PROGRAM=Apple_Terminal BRIEF_TERMINAL=auto)" terminal
is "no terminal -> generic" "$(drv BRIEF_TERMINAL=auto)" generic
is "explicit override wins" "$(drv TMUX=x BRIEF_TERMINAL=kitty)" kitty
is "traversal -> generic"   "$(drv BRIEF_TERMINAL=../evil)" generic
is "slashes -> generic"     "$(drv BRIEF_TERMINAL=a/b)" generic
is "unknown -> generic"     "$(drv BRIEF_TERMINAL=nope)" generic

echo "TERMINAL DRIVER — unified detection: a drop-in driver is just another tdrv_detect"
# Detection lives in the drivers; the lib only probes tdrv_detect + tdrv_rank. A
# third-party driver auto-selects with NO edit to terminal-driver.sh, on equal footing
# with built-ins — the highest tdrv_rank match wins (tmux's 90 > a default 50).
DD=$(mktemp -d "${TMPDIR:-/tmp}/t-drop.XXXXXX"); mkdir -p "$DD/common"
cp "$BIN/term/common/generic.sh" "$BIN/term/common/tmux.sh" "$DD/common/"
printf '%s' $'tdrv_name(){ printf foo; }\ntdrv_detect(){ [ -n "${FOO:-}" ]; }\ntdrv_self_pane(){ :; }\ntdrv_open(){ :; }\ntdrv_close(){ :; }\n' > "$DD/common/foo.sh"
# a high-rank drop-in beats even tmux's mux rank -> proves rank, not built-in-ness, decides
printf '%s' $'tdrv_name(){ printf vip; }\ntdrv_detect(){ [ -n "${VIP:-}" ]; }\ntdrv_rank(){ printf 99; }\ntdrv_self_pane(){ :; }\ntdrv_open(){ :; }\ntdrv_close(){ :; }\n' > "$DD/common/vip.sh"
dpick(){ env -i HOME="$HOME" PATH="$PATH" BRIEF_TERM_DIR="$DD" "$@" bash -c '. "'"$LIB"'" >/dev/null 2>&1; tdrv_name'; }
is "drop-in self-detects (tdrv_detect)" "$(dpick FOO=1 BRIEF_TERMINAL=auto)" foo
is "no driver claims -> generic"        "$(dpick BRIEF_TERMINAL=auto)" generic
is "tmux rank (90) beats default drop-in" "$(dpick TMUX=x FOO=1 BRIEF_TERMINAL=auto)" tmux
is "higher-rank drop-in beats tmux"     "$(dpick TMUX=x VIP=1 BRIEF_TERMINAL=auto)" vip
is "force a driver by name"             "$(dpick BRIEF_TERMINAL=foo)" foo
rm -rf "$DD"

echo "TERMINAL DRIVER — OS-bucketed layout (term/<os>/ over term/common/, no cross-OS leak)"
# The restructure: drivers live in term/<os>/ (OS-specific) + term/common/ (shared).
# A macOS-only driver in darwin/ must NOT be on Linux's search path (and vice versa),
# and an <os>/ driver shadows a common/ one of the same name. Stub `uname` so both
# OSes are exercised from one host.
OD=$(mktemp -d "${TMPDIR:-/tmp}/t-osdir.XXXXXX"); mkdir -p "$OD/common" "$OD/darwin" "$OD/linux"
cp "$BIN/term/common/generic.sh" "$OD/common/"                       # fallback, resolvable on any OS
mk(){ printf 'tdrv_name(){ printf %s; }\ntdrv_self_pane(){ :; }\ntdrv_open(){ :; }\ntdrv_close(){ :; }\n' "$1"; }
mk mac      > "$OD/darwin/mac.sh"                                    # macOS-only
mk lin      > "$OD/linux/lin.sh"                                     # Linux-only
mk shcommon > "$OD/common/sh.sh"                                     # shared name...
mk shdarwin > "$OD/darwin/sh.sh"                                     # ...with a darwin override
printf 'tdrv_name(){ printf dd; }\ntdrv_detect(){ true; }\ntdrv_self_pane(){ :; }\ntdrv_open(){ :; }\ntdrv_close(){ :; }\n' > "$OD/darwin/dd.sh"
mkdir -p "$OD/ud" "$OD/ul"
printf '%s' $'#!/usr/bin/env bash\necho Darwin\n' > "$OD/ud/uname"; printf '%s' $'#!/usr/bin/env bash\necho Linux\n' > "$OD/ul/uname"
chmod +x "$OD/ud/uname" "$OD/ul/uname"
opick(){ _os=$1; shift; env -i HOME="$HOME" PATH="$OD/u$_os:$PATH" BRIEF_TERM_DIR="$OD" "$@" bash -c '. "'"$LIB"'" >/dev/null 2>&1; tdrv_name'; }
is "darwin/ driver resolves on macOS"      "$(opick d BRIEF_TERMINAL=mac)" mac
is "darwin/ driver absent on Linux->generic" "$(opick l BRIEF_TERMINAL=mac)" generic
is "linux/ driver resolves on Linux"       "$(opick l BRIEF_TERMINAL=lin)" lin
is "common/ driver resolves on any OS"     "$(opick l BRIEF_TERMINAL=sh)" shcommon
is "os/ shadows common/ (same name)"       "$(opick d BRIEF_TERMINAL=sh)" shdarwin
is "drop-in in darwin/ auto-detects (macOS)" "$(opick d BRIEF_TERMINAL=auto)" dd
is "darwin/ drop-in NOT probed on Linux"   "$(opick l BRIEF_TERMINAL=auto)" generic
rm -rf "$OD"

echo "TERMINAL DRIVER — self_pane is filesystem-safe (no slash)"
sp(){ env -i HOME="$HOME" PATH="$PATH" "$@" bash -c '. "'"$LIB"'" >/dev/null 2>&1; tdrv_self_pane'; }
is "tmux self id"        "$(sp TMUX=x TMUX_PANE=%7 BRIEF_TERMINAL=tmux)" "%7"
is "kitty self id"       "$(sp KITTY_WINDOW_ID=42 BRIEF_TERMINAL=kitty)" "42"
is "wezterm self id"     "$(sp WEZTERM_PANE=3 BRIEF_TERMINAL=wezterm)" "3"
is "tabby self id empty" "$(sp TERM_PROGRAM=Tabby BRIEF_TERMINAL=tabby)" ""
is "iterm2 self hex-only" "$(sp ITERM_SESSION_ID='w0t0p0:AB/../CD' BRIEF_TERMINAL=iterm2)" "ABCD"
is "terminal self hex-only" "$(sp TERM_SESSION_ID='w0t0p0:AB-CD/..' BRIEF_TERMINAL=terminal)" "AB-CD"

echo "TERMINAL DRIVER — .brief.session parse (MIRROR of brief-open/session-end)"
parse(){ local s=$1 n i; n=${s%% *}; i=${s#* }; [ "$n" = "$i" ] && n=iterm2; case "$n" in *[!a-z0-9]*) n="" ;; esac; echo "$n|$i"; }
is "two-token parse" "$(parse 'tmux %3')" 'tmux|%3'
is "legacy single -> iterm2" "$(parse 'ABCD-1234')" 'iterm2|ABCD-1234'

echo "TERMINAL DRIVER — brief-open/session-end drive the driver (fake backend)"
mkdir -p "$BIN/term"
printf '%s' $'tdrv_name(){ printf fake; }\ntdrv_self_pane(){ printf FP; }\ntdrv_open(){ echo "open $*" >>/tmp/t-term; printf FAKEID; }\ntdrv_close(){ echo "close $*" >>/tmp/t-term; }\n' > "$BIN/term/common/fake.sh"
wipe; rm -f /tmp/t-term; mkdir -p "$ST/panes"; printf '%s\n' "$S" > "$ST/panes/FP"
BRIEF_TERMINAL=fake "$BIN/brief-open.sh" >/dev/null 2>&1
is "brief-open called tdrv_open" "$(grep -c "^open dock FP " /tmp/t-term 2>/dev/null)" 1
is "session file = driver + id"  "$(cat "$ST/$S.brief.session" 2>/dev/null)" "fake FAKEID"
printf '{"session_id":"%s"}' "$S" | BRIEF_TERMINAL=fake bash "$HOOKS/session-end-hook.sh"
perl -e 'select(undef,undef,undef,0.5)'   # the close runs detached (&)
is "session-end called tdrv_close" "$(grep -c '^close FAKEID' /tmp/t-term 2>/dev/null)" 1
rm -f "$ST/panes/FP"

echo "TERMINAL DRIVER — brief-open close tears down + clears session file"
wipe; rm -f /tmp/t-term; mkdir -p "$ST/panes"; printf '%s\n' "$S" > "$ST/panes/FP"
BRIEF_TERMINAL=fake "$BIN/brief-open.sh" >/dev/null 2>&1            # open -> writes session file
rm -f /tmp/t-term
BRIEF_TERMINAL=fake "$BIN/brief-open.sh" close >/dev/null 2>&1     # close -> tdrv_close + rm session file
is "close -> tdrv_close(FAKEID)" "$(grep -c '^close FAKEID' /tmp/t-term 2>/dev/null)" 1
is "close clears session file"   "$([ -f "$ST/$S.brief.session" ] && echo kept || echo gone)" gone
rm -f "$ST/panes/FP"

echo "TERMINAL DRIVER — kitty routes kitty @ through \$KITTY_LISTEN_ON + injects PATH"
# Hermetic: stub `kitty` on PATH so we can assert the driver's remote-control wiring
# without a running kitty (kitty has no headless mode to test against). The no-tty
# /brief context means a socket ($KITTY_LISTEN_ON) is mandatory + PATH must be passed.
KDIR=$(mktemp -d "${TMPDIR:-/tmp}/t-kitty.XXXXXX")
printf '%s' $'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> /tmp/t-kitty-args\ncase "$*" in *launch*) echo 42 ;; esac\n' > "$KDIR/kitty"
chmod +x "$KDIR/kitty"
(
  export BRIEF_TERMINAL=kitty PATH="$KDIR:$PATH"
  . "$LIB" >/dev/null 2>&1
  rm -f /tmp/t-kitty-args
  KITTY_LISTEN_ON="unix:/tmp/ksock" tdrv_open dock "" /v sid >/dev/null 2>&1
  grep -q -- '@ --to unix:/tmp/ksock launch' /tmp/t-kitty-args && echo R_TO
  grep -qF -- "--env PATH=$KDIR:" /tmp/t-kitty-args && echo R_ENV
  rm -f /tmp/t-kitty-args
  tdrv_open dock "" /v sid >/dev/null 2>&1                      # no socket -> bare kitty @ (tty path)
  grep -q -- '--to' /tmp/t-kitty-args || echo R_NOTO
  rm -f /tmp/t-kitty-args
  KITTY_LISTEN_ON="unix:/tmp/ksock" tdrv_close 42 >/dev/null 2>&1
  grep -q -- '@ --to unix:/tmp/ksock close-window --match id:42' /tmp/t-kitty-args && echo C_OK
) > /tmp/t-kitty-res 2>/dev/null
is "kitty routes via --to socket"       "$(grep -c '^R_TO$'   /tmp/t-kitty-res)" 1
is "kitty injects --env PATH"           "$(grep -c '^R_ENV$'  /tmp/t-kitty-res)" 1
is "kitty omits --to when no socket"    "$(grep -c '^R_NOTO$' /tmp/t-kitty-res)" 1
is "kitty close routes via socket + id" "$(grep -c '^C_OK$'   /tmp/t-kitty-res)" 1
rm -rf "$KDIR" /tmp/t-kitty-args /tmp/t-kitty-res

echo "TERMINAL DRIVER — wezterm routes wezterm cli (split/spawn/kill) + injects PATH + refocuses"
# Hermetic: stub `wezterm` on PATH to assert the CLI wiring without a running GUI.
# wezterm cli needs NO tty/socket setup (the easy case vs kitty), but a GUI-launched
# mux can have a minimal PATH, so the driver wraps CMD in /usr/bin/env PATH=… and
# (since split/spawn grab focus) activate-panes back to the anchor.
WZDIR=$(mktemp -d "${TMPDIR:-/tmp}/t-wez.XXXXXX")
printf '%s' $'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> /tmp/t-wez-args\ncase "$*" in *split-pane*|*spawn*) echo 7 ;; esac\n' > "$WZDIR/wezterm"
chmod +x "$WZDIR/wezterm"
(
  export BRIEF_TERMINAL=wezterm PATH="$WZDIR:$PATH"
  . "$LIB" >/dev/null 2>&1
  rm -f /tmp/t-wez-args
  tdrv_open dock 0 /v sid >/dev/null 2>&1
  grep -q -- 'cli split-pane --right --pane-id 0' /tmp/t-wez-args && echo R_SPLIT
  grep -qF -- "-- /usr/bin/env PATH=$WZDIR:" /tmp/t-wez-args && echo R_ENV
  grep -q -- 'cli activate-pane --pane-id 0' /tmp/t-wez-args && echo R_FOCUS
  rm -f /tmp/t-wez-args
  tdrv_open float 0 /v sid >/dev/null 2>&1
  grep -q -- 'cli spawn --new-window' /tmp/t-wez-args && echo R_FLOAT
  rm -f /tmp/t-wez-args
  tdrv_close 7 >/dev/null 2>&1
  grep -q -- 'cli kill-pane --pane-id 7' /tmp/t-wez-args && echo C_OK
) > /tmp/t-wez-res 2>/dev/null
is "wezterm dock = split-pane --right --pane-id" "$(grep -c '^R_SPLIT$' /tmp/t-wez-res)" 1
is "wezterm injects /usr/bin/env PATH"           "$(grep -c '^R_ENV$'   /tmp/t-wez-res)" 1
is "wezterm refocuses the anchor pane"           "$(grep -c '^R_FOCUS$' /tmp/t-wez-res)" 1
is "wezterm float = spawn --new-window"          "$(grep -c '^R_FLOAT$' /tmp/t-wez-res)" 1
is "wezterm close = kill-pane --pane-id"         "$(grep -c '^C_OK$'    /tmp/t-wez-res)" 1
rm -rf "$WZDIR" /tmp/t-wez-args /tmp/t-wez-res

echo "TERMINAL DRIVER — wezterm real end-to-end (live GUI split + render + close)"
# Like the tmux e2e but for WezTerm: only runs when invoked INSIDE a reachable
# WezTerm GUI (so it skips in CI / other terminals). Proves the bash-5 viewer + glow
# ran in the new pane (via the /usr/bin/env PATH wrap) and that focus returns to the
# session. If the open yields no pane id (e.g. a sandbox blocked it) it skips, not fails.
if command -v wezterm >/dev/null 2>&1 && [ -n "${WEZTERM_PANE:-}" ] && wezterm cli list >/dev/null 2>&1; then
  napw(){ perl -e 'select(undef,undef,undef,0.5)'; }
  wipe
  printf '# wezterm e2e\n\n## State\nrendering in a real WezTerm split\n\n## Next / Open\n- close cleanly\n' > "$ST/$S.brief.md"
  ( export BRIEF_TERMINAL=wezterm; . "$LIB" >/dev/null 2>&1
    a=$(tdrv_self_pane); n=$(tdrv_open dock "$a" "$BIN/brief-view.sh" "$S")
    printf '%s %s\n' "$n" "$a" > /tmp/t-wez-ids )
  read n a < /tmp/t-wez-ids 2>/dev/null
  if [ -n "$n" ]; then
    render=""; i=0
    while [ "$i" -lt 12 ]; do napw; render=$(wezterm cli get-text --pane-id "$n" 2>/dev/null); printf '%s' "$render" | grep -q 'wezterm e2e' && break; i=$((i+1)); done
    is "wezterm viewer rendered the brief"  "$([ "$(printf '%s' "$render" | grep -c 'wezterm e2e')" -ge 1 ] && echo yes || echo no)" yes
    is "wezterm focus back on session pane" "$(wezterm cli list-clients 2>/dev/null | awk 'NR==2{print $NF}')" "$a"
    ( export BRIEF_TERMINAL=wezterm; . "$LIB" >/dev/null 2>&1; tdrv_close "$n" )
    napw
    gone=yes; wezterm cli list 2>/dev/null | awk -v p="$n" '$3==p{f=1} END{exit !f}' && gone=no
    is "wezterm close removed the pane"     "$gone" yes
  else
    printf '  \033[33mskip\033[0m wezterm cli could not spawn a pane here (sandboxed?)\n'
  fi
  wipe; rm -f /tmp/t-wez-ids
else
  printf '  \033[33mskip\033[0m not inside a reachable WezTerm GUI\n'
fi

echo "TERMINAL DRIVER — tabby recognized manual fallback (no scriptable split/RC)"
# Tabby (Electron) can't be auto-docked — no scriptable split, CLI opens tabs only
# (no id/close), no AppleScript. So the driver behaves like generic but prints a
# Tabby-specific hint, and brief-open prints the manual viewer command + exits 0.
(
  export BRIEF_TERMINAL=tabby
  . "$LIB" >/dev/null 2>&1
  id=$(tdrv_open dock "" "$BIN/brief-view.sh" sid 2>/tmp/t-tabby-err)
  printf 'OPENID=[%s]\n' "$id"
  grep -qi 'tabby' /tmp/t-tabby-err && echo HINT
  tdrv_close 123 >/dev/null 2>&1 && echo CLOSEOK
  [ -z "$(tdrv_self_pane)" ] && echo SELFEMPTY
) > /tmp/t-tabby-res 2>/dev/null
is "tabby open yields no dock id"  "$(grep -c '^OPENID=\[\]$' /tmp/t-tabby-res)" 1
is "tabby prints a split hint"     "$(grep -c '^HINT$'        /tmp/t-tabby-res)" 1
is "tabby close is a safe no-op"   "$(grep -c '^CLOSEOK$'     /tmp/t-tabby-res)" 1
is "tabby has no self-pane id"     "$(grep -c '^SELFEMPTY$'   /tmp/t-tabby-res)" 1
rm -f /tmp/t-tabby-err /tmp/t-tabby-res

echo "TERMINAL DRIVER — ghostty + Apple Terminal: osascript wiring + close-safety (stubbed)"
# The two AppleScript drivers shell out to osascript/ps, so stub those on PATH and
# drive them hermetically. HIGH-VALUE safety assertions: close NEVER blanket-kills a
# tty — it kills ONLY a brief-view.sh-scoped process (a decoy "claude" sharing the tty
# must survive) and bails entirely when the dock window is gone. `kill` is the REAL
# builtin acting on REAL throwaway processes, so the safety is verified, not mocked.
SDIR=$(mktemp -d "${TMPDIR:-/tmp}/t-osa.XXXXXX")
export OSALOG="$SDIR/osa.log" PSLOG="$SDIR/ps.log" PSCOUNT="$SDIR/ps.count" BVIEW="$BIN/brief-view.sh"
cat > "$SDIR/osascript" <<'STUB'
#!/usr/bin/env bash
d=$(cat 2>/dev/null); all="$* $d"
printf '=== call ===\nARGS: %s\nSTDIN: %s\n' "$*" "$d" >> "$OSALOG"
case "$all" in
  *'return "y"'*)                printf '%s\n' "${OSA_EXISTS:-y}" ;;       # window-exists check
  *'busy of selected tab'*)      printf '%s\n' "${OSA_BUSY:-false}" ;;     # busy check (false=idle)
  *'close w'*|*'close tm'*)      : ;;                                      # close -> recorded only
  *'do script'*)                 printf '%s\n' "${OSA_OPENID}" ;;          # Apple Terminal open
  *'new surface configuration'*) printf '%s\n' "${OSA_OPENID}" ;;          # ghostty open
  *'focused terminal of selected tab of front window'*) printf '%s\n' "${OSA_SELF}" ;; # ghostty self
  *) : ;;
esac
STUB
cat > "$SDIR/ps" <<'STUB'
#!/usr/bin/env bash
echo "PS: $*" >> "$PSLOG"
c=$(cat "$PSCOUNT" 2>/dev/null || echo 0); c=$((c+1)); echo "$c" > "$PSCOUNT"
if [ "$c" -le 1 ]; then                       # first poll: the viewer + a DECOY on the tty
  printf ' %s /bin/bash %s %s\n' "${BVPID}" "${BVIEW}" "${SID}"
  printf ' %s claude --resume %s\n' "${DECOYPID}" "${SID}"
fi                                            # later polls: empty (as if the viewer was killed)
STUB
chmod +x "$SDIR/osascript" "$SDIR/ps"
rstlogs(){ : > "$OSALOG"; : > "$PSLOG"; rm -f "$PSCOUNT"; }
alive(){ kill -0 "$1" 2>/dev/null && echo yes || echo no; }
SIDF=feed0000-dead-beef-0000-000000000000

# -- ghostty self id (osascript-backed) --
rstlogs
gself=$( export PATH="$SDIR:$PATH" OSA_SELF="1A2B-3C4D" BRIEF_TERMINAL=ghostty
         . "$LIB" >/dev/null 2>&1; tdrv_self_pane )
is "ghostty self id (osascript)" "$gself" "1A2B-3C4D"

# -- ghostty open: dock split + PATH inject + focus-back; id = <uuid>:<sid> --
rstlogs
gid=$( export PATH="$SDIR:$PATH" OSA_OPENID="AAAA-BBBB" BRIEF_TERMINAL=ghostty
       . "$LIB" >/dev/null 2>&1; tdrv_open dock "AAAA-BBBB" "$BVIEW" "$SIDF" )
is "ghostty open id = uuid:sid"    "$gid" "AAAA-BBBB:$SIDF"
is "ghostty open splits right"     "$(grep -c 'split anchorT direction right' "$OSALOG")" 1
is "ghostty open injects PATH"     "$(grep -c 'environment variables of cfg' "$OSALOG")" 1
is "ghostty open hands focus back" "$(grep -c 'focus anchorT' "$OSALOG")" 1

# -- ghostty float = new window --
rstlogs
gfid=$( export PATH="$SDIR:$PATH" OSA_OPENID="CCCC-DDDD" BRIEF_TERMINAL=ghostty
        . "$LIB" >/dev/null 2>&1; tdrv_open float "" "$BVIEW" "$SIDF" )
is "ghostty float = new window" "$(grep -c 'new window with configuration' "$OSALOG")" 1

# -- ghostty close: kills ONLY the brief-view proc, spares the decoy --
rstlogs
perl -e 'select(undef,undef,undef,10)' & BV=$!
perl -e 'select(undef,undef,undef,10)' & DC=$!
( export PATH="$SDIR:$PATH" BRIEF_TERMINAL=ghostty BVPID=$BV DECOYPID=$DC SID="$SIDF"
  . "$LIB" >/dev/null 2>&1; tdrv_close "AAAA-BBBB:$SIDF" ) </dev/null >/dev/null 2>&1
wait "$BV" 2>/dev/null
is "ghostty close killed the viewer" "$(alive $BV)" no
is "ghostty close spared the decoy"  "$(alive $DC)" yes
kill -KILL $DC 2>/dev/null; wait $DC 2>/dev/null

# -- ghostty close bails on a malformed id (no colon) -> touches nothing --
rstlogs
( export PATH="$SDIR:$PATH" BRIEF_TERMINAL=ghostty
  . "$LIB" >/dev/null 2>&1; tdrv_close "notanid" ) </dev/null >/dev/null 2>&1
is "ghostty close bails on bad id" "$([ -s "$PSLOG" ] || [ -s "$OSALOG" ] && echo touched || echo clean)" clean

# -- Apple Terminal open: do script + id = <winid>:<tty> --
rstlogs
tid=$( export PATH="$SDIR:$PATH" OSA_OPENID="7:/dev/ttysTEST" BRIEF_TERMINAL=terminal
       . "$LIB" >/dev/null 2>&1; tdrv_open dock "" "$BVIEW" "$SIDF" )
is "terminal open id = winid:tty" "$tid" "7:/dev/ttysTEST"
is "terminal open via do script"  "$(grep -c 'do script .exec' "$OSALOG")" 1

# -- Apple Terminal close: window GONE -> touch NOTHING (the recycled-tty safety) --
rstlogs
perl -e 'select(undef,undef,undef,10)' & BV=$!
( export PATH="$SDIR:$PATH" BRIEF_TERMINAL=terminal OSA_EXISTS=n BVPID=$BV DECOYPID=$BV SID="$SIDF"
  . "$LIB" >/dev/null 2>&1; tdrv_close "7:/dev/ttysTEST" ) </dev/null >/dev/null 2>&1
is "terminal gone -> no ps poll"   "$([ -s "$PSLOG" ] && echo touched || echo clean)" clean
is "terminal gone -> no window close" "$(grep -c 'close w' "$OSALOG")" 0
is "terminal gone -> viewer untouched" "$(alive $BV)" yes
kill -KILL $BV 2>/dev/null; wait $BV 2>/dev/null

# -- Apple Terminal close: window exists -> kill ONLY brief-view, spare the decoy --
rstlogs
perl -e 'select(undef,undef,undef,10)' & BV=$!
perl -e 'select(undef,undef,undef,10)' & DC=$!
( export PATH="$SDIR:$PATH" BRIEF_TERMINAL=terminal OSA_EXISTS=y OSA_BUSY=false BVPID=$BV DECOYPID=$DC SID="$SIDF"
  . "$LIB" >/dev/null 2>&1; tdrv_close "7:/dev/ttysTEST" ) </dev/null >/dev/null 2>&1
wait "$BV" 2>/dev/null
is "terminal close killed the viewer" "$(alive $BV)" no
is "terminal close spared the decoy"  "$(alive $DC)" yes
kill -KILL $DC 2>/dev/null; wait $DC 2>/dev/null

# -- Apple Terminal close bails on a malformed id (non-numeric winid) --
rstlogs
( export PATH="$SDIR:$PATH" BRIEF_TERMINAL=terminal
  . "$LIB" >/dev/null 2>&1; tdrv_close "abc:/dev/ttysX" ) </dev/null >/dev/null 2>&1
is "terminal close bails on bad winid" "$([ -s "$OSALOG" ] && echo touched || echo clean)" clean

rm -rf "$SDIR"; unset OSALOG PSLOG PSCOUNT BVIEW

echo "TERMINAL DRIVER — tmux real end-to-end (headless split + render + close)"
# tmux is the one backend drivable without a GUI, so actually exercise it: spin up
# a PRIVATE tmux server, run the live brief-open inside a pane, and assert the dock
# splits, the viewer renders (proving the bash-5 viewer + glow ran in the new pane
# via the inherited client PATH), and /brief close tears the pane down. Skips where
# tmux is absent or can't spawn a pane (headless/sandboxed CI).
if command -v tmux >/dev/null 2>&1; then
  TSOCK="brieftest-$$"
  tmx(){ tmux -L "$TSOCK" "$@"; }
  napf(){ perl -e 'select(undef,undef,undef,0.4)'; }     # 0.4s sub-second nap
  tmx new-session -d -s s -x 200 -y 50 2>/dev/null
  if tmx list-panes -t s >/dev/null 2>&1; then
    wipe
    printf '# tmux e2e\n\n## State\nrendering inside a real split\n\n## Next / Open\n- close cleanly\n' > "$ST/$S.brief.md"
    mp=$(tmx list-panes -t s -F '#{pane_id}' | head -1)
    mkdir -p "$ST/panes"; printf '%s\n' "$S" > "$ST/panes/$mp"   # $TMUX_PANE inside the pane == $mp -> resolves to $S
    tmx send-keys -t "$mp" "'$BIN/brief-open.sh' dock >/tmp/t-tmux 2>&1" Enter
    dock=""; i=0
    while [ "$i" -lt 15 ]; do napf; dock=$(tmx list-panes -t s -F '#{pane_id} #{pane_active}' 2>/dev/null | awk '$2==0{print $1}' | head -1); [ -n "$dock" ] && break; i=$((i+1)); done
    is "tmux dock pane created"     "$([ -n "$dock" ] && echo yes || echo no)" yes
    is "session file = tmux <pane>" "$(cat "$ST/$S.brief.session" 2>/dev/null)" "tmux $dock"
    render=""; i=0
    while [ "$i" -lt 15 ]; do napf; render=$(tmx capture-pane -p -t "$dock" 2>/dev/null); printf '%s' "$render" | grep -q 'tmux e2e' && break; i=$((i+1)); done
    is "viewer rendered the brief"  "$([ "$(printf '%s' "$render" | grep -c 'tmux e2e')" -ge 1 ] && echo yes || echo no)" yes
    is "viewer footer (bash5+glow)" "$([ "$(printf '%s' "$render" | grep -c generated)" -ge 1 ] && echo yes || echo no)" yes
    tmx send-keys -t "$mp" "'$BIN/brief-open.sh' close >>/tmp/t-tmux 2>&1" Enter
    gone=no; i=0
    while [ "$i" -lt 15 ]; do napf; tmx list-panes -t s -F '#{pane_id}' 2>/dev/null | grep -qx "$dock" || { gone=yes; break; }; i=$((i+1)); done
    is "tmux close removed the pane" "$gone" yes
    is "close cleared session file"  "$([ -f "$ST/$S.brief.session" ] && echo kept || echo gone)" gone
    rm -f "$ST/panes/$mp"
  else
    printf '  \033[33mskip\033[0m tmux cannot spawn a pane here (headless/sandboxed)\n'
  fi
  tmx kill-server 2>/dev/null
else
  printf '  \033[33mskip\033[0m tmux not installed\n'
fi

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
exit "$fail"
