---
description: Open/focus the docked pane showing this session's live summary brief
argument-hint: "[float|refresh|close]"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/brief-open.sh:*)
---
This session's running brief (state · what's been tried · gotchas · decisions ·
next) is shown in a docked pane — a side-by-side split (or, on Apple Terminal,
a companion window beside this one), opened or re-focused just now. The terminal
backend is auto-detected (iTerm2 / tmux / kitty / ghostty / Apple Terminal). Click the dock
pane to use its keys: `r` refresh now ·
`a` toggle **auto** (refresh at the end of each turn — the default; turn off for
on-demand only) · `i` toggle **interval** (refresh periodically during a long
turn; only fires on new activity, so idle never spends) · `+`/`-` set the
interval period (30s–1h) · `?` key help · `q` close. The footer shows both
modes. The brief is sized to fit the dock pane. `/brief refresh` does a one-shot
refresh from here but re-splits the pane. `/brief close` tears the dock down (a
clean, no-prompt close on every backend — preferred over `q`/⌘W, which on ghostty
leave an empty pane / pop a confirm).

!`"${CLAUDE_PLUGIN_ROOT}/bin/brief-open.sh" $ARGUMENTS`

Acknowledge in ONE short line that the brief dock is up — or, if the command
above reported an error, relay that error. Do NOT reproduce the brief here.
