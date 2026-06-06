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
trap 'wipe; rm -f "$BIN"/t-*.sh "$BIN/term/fake.sh" /tmp/t-* 2>/dev/null' EXIT

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

echo "TERMINAL DRIVER — auto-detection precedence + \$BRIEF_TERMINAL whitelist"
LIB="$BIN/lib/terminal-driver.sh"
# Source the live driver lib in a clean env with controlled terminal vars; echo
# the chosen driver. env -i wipes PATH but tdrv_name only printf's, so that's fine.
drv(){ env -i HOME="$HOME" PATH="$PATH" "$@" bash -c '. "'"$LIB"'" >/dev/null 2>&1; tdrv_name'; }
is "tmux wins over iterm2"   "$(drv TMUX=x ITERM_SESSION_ID=w:abc BRIEF_TERMINAL=auto)" tmux
is "kitty detected"         "$(drv KITTY_WINDOW_ID=3 BRIEF_TERMINAL=auto)" kitty
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

echo "TERMINAL DRIVER — self_pane is filesystem-safe (no slash)"
sp(){ env -i HOME="$HOME" PATH="$PATH" "$@" bash -c '. "'"$LIB"'" >/dev/null 2>&1; tdrv_self_pane'; }
is "tmux self id"        "$(sp TMUX=x TMUX_PANE=%7 BRIEF_TERMINAL=tmux)" "%7"
is "kitty self id"       "$(sp KITTY_WINDOW_ID=42 BRIEF_TERMINAL=kitty)" "42"
is "iterm2 self hex-only" "$(sp ITERM_SESSION_ID='w0t0p0:AB/../CD' BRIEF_TERMINAL=iterm2)" "ABCD"

echo "TERMINAL DRIVER — .brief.session parse (MIRROR of brief-open/session-end)"
parse(){ local s=$1 n i; n=${s%% *}; i=${s#* }; [ "$n" = "$i" ] && n=iterm2; case "$n" in *[!a-z0-9]*) n="" ;; esac; echo "$n|$i"; }
is "two-token parse" "$(parse 'tmux %3')" 'tmux|%3'
is "legacy single -> iterm2" "$(parse 'ABCD-1234')" 'iterm2|ABCD-1234'

echo "TERMINAL DRIVER — brief-open/session-end drive the driver (fake backend)"
mkdir -p "$BIN/term"
printf '%s' $'tdrv_name(){ printf fake; }\ntdrv_self_pane(){ printf FP; }\ntdrv_open(){ echo "open $*" >>/tmp/t-term; printf FAKEID; }\ntdrv_close(){ echo "close $*" >>/tmp/t-term; }\n' > "$BIN/term/fake.sh"
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
