# Generic fallback driver: no terminal scripting available (unknown emulator, plain
# SSH, etc.). Brief generation and the viewer still work — the user just runs the
# viewer in a split/window they create. brief-open detects the empty open result
# from the generic driver and prints the exact command to run. Sourced — 3.2-safe.

tdrv_name(){ printf 'generic'; }
tdrv_self_pane(){ :; }              # no stable per-pane id; brief-open falls back to cwd
tdrv_open(){ :; }                   # no scriptable dock -> empty id; brief-open prints the hint
tdrv_close(){ :; }                  # nothing to close
