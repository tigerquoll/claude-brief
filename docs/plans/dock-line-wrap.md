# Fix dock line-wrapping (mid-token breaks + trailing-pad overflow)

## Symptom
In the docked viewer, long lines run to ~the pane edge, the terminal wraps, then a
hard line break lands a word or two later — and identifier tokens like `DEX-22116`
appear split as `DEX-` (on its own line) / `22116`. Reproduced with the brief in
`~/.claude/state/3bdfded4-…​.brief.md` (recorded pane size `59 103`).

## Root cause (two glow behaviours, both confirmed)
`render()` pipes the brief through `glow -w $wrapw` (where `wrapw = cols - 8`), then
`_ifmt` indents. glow's word-wrap does two unwanted things:

1. **Breaks tokens at hyphens.** glow's reflow library breaks *after* `-`, so
   `DEX-22116` becomes `DEX-` + `22116`. The `render()` comment claiming "breaks at
   spaces → identifiers stay whole" is wrong. This is the orphaned-fragment artifact.
2. **Right-pads every wrapped line to `wrapw` with trailing spaces.** Each rendered
   line becomes `indent + wrapw` cells of content+padding, so a line visually extends
   to near the pane edge with invisible spaces ("looks slightly longer than the
   width"); combined with glow overshooting `-w` by 1–2 cols and the indent, lines can
   meet/exceed the pane and the terminal soft-wraps.

Neither is configurable via a glow flag.

Incidental finding (do NOT try to "fix" — preserve current behaviour): glow emits the
heading colour escape *before* the `▸`/`▌` glyph, so `_ifmt`'s `^[▸▌]` regex never
matches a coloured heading; headings fall through to the default 2-space indent today.
That is the current on-screen behaviour (headings and body both at col 2). The new
formatter must reproduce it (coloured heading → body branch → col 2), not revive the
dead branch.

## Approach
Stop using glow for wrapping. Run `glow … -w 0` (no wrap → no padding, no hyphen-break;
confirmed: it emits each markdown block as one long, unpadded line) and do our own
space-only wrapping in the perl `_ifmt` pass.

Validated prototype lives at (scratchpad) `ifmt2.pl` — the reference for the rewrite.
It produced, across the real brief and a constructed bullet/hyphen brief at W=40/60/103:
no mid-token splits, no trailing padding, and **every emitted line ≤ target width**.

### `render()` change
- Replace `glow -s "$gs" -w "$wrapw"` / `glow -w "$wrapw"` with the same invocation but
  `-w 0`. Keep `CLICOLOR_FORCE=1`, `</dev/null`, the style-file branch, and the
  bat/plain fallbacks unchanged.
- Pass the pane width to the formatter: `… | _ifmt "$W"`. Keep computing `W=${cols:-80}`.
  Drop `wrapw` from `render()` (the formatter computes its own budgets). The
  `[ "$wrapw" -lt 20 ]` floor moves into the formatter (clamp `W` to a sane minimum).

### New `_ifmt "$W"` (perl)
Process glow's (now-unwrapped, ANSI-coloured) output line by line. Preserve the existing
classification, indents, dim-bullet glyph, and blank-run collapse — only ADD wrapping:

- blank line → collapse runs to one (unchanged).
- `^\x{2022} (.*)` bullet → first prefix `"    \e[90m\x{2022}\e[0m "` (text at col 6),
  continuation indent 8.
- `^[\x{25b8}\x{258c}] ` ▸/▌ heading → prefix `"  "`, continuation indent 4.
- `^  \S` h3 → prefix `"  "`, continuation indent 4.
- else (body, and coloured headings that fall through here) → prefix `"  "`,
  continuation indent 2.

Then wrap the line's content at **spaces only** into pieces, emit the first piece after
the prefix and each continuation after `indent` spaces. Requirements:

- **ANSI-aware width**: a display-width function that ignores `\e\[[0-9;]*m` escapes and
  counts East-Asian Wide/Fullwidth chars as 2. Escapes ride along with their adjacent
  token (zero width).
- **Never split a single token** (no break inside a word). A token longer than the
  budget is emitted whole on its own line (may exceed width — rare; acceptable, and no
  worse than today). 
- **No padding** (never pad a piece out to the budget); also `s/[ \t]+$//` defensively.
- **1-column safety margin**: target max line width = `W - 1` (reserve the last column to
  avoid last-column autowrap on some terminals). So the per-line content budget is
  `(W - 1) - hang`, where `hang = max(display-width-of-first-prefix, continuation-indent)`
  → body `W-3`, heading/h3 `W-5`, bullet `W-9`. Clamp budget to ≥ a small minimum (e.g. 8).
- Read/write UTF-8 (`binmode … ':encoding(UTF-8)'`; the script runs under `env perl`).

The per-line approach needs no cross-line `$ind` state (glow `-w 0` gives whole blocks, so
the old "wrapped-continuation" branch that carried `$ind` is no longer needed).

## Invariants
- Every emitted line's display width ≤ `W - 1`, **except** a single unbreakable token
  longer than its budget (emitted whole).
- Identifier tokens (`DEX-22116`, `harness-terraform#623`) are never split.
- No trailing whitespace on any line.
- Visual layout for the current real briefs is unchanged vs today (heading/body at col 2),
  except long lines now wrap cleanly at spaces and fill slightly more width.

## Files
- `bin/brief-view.sh` — `render()` (the two glow calls + `_ifmt` arg) and the `_ifmt`
  perl body. No other file. `glow-brief.json` unchanged.

## Verification
- Reproduce against `~/.claude/state/3bdfded4-…​.brief.md`: `CLICOLOR_FORCE=1 glow -s
  glow-brief.json -w 0 <brief> | _ifmt 103` → assert (a) no line's display width > 102,
  (b) no line is a bare `DEX-` / no `…-$` mid-token split, (c) no trailing spaces.
- Add a unit test in `test.sh` (near the other viewer tests) that runs the new `_ifmt`
  over a small fixture with a long hyphenated run and a wrapping bullet, at a couple of
  widths, asserting: max display width ≤ W-1, and `DEX-22116` survives intact. Match the
  existing `is "label" "$actual" "$expected"` idiom and harness vars.
- Existing tmux/wezterm e2e render tests must stay green (they only assert the brief text
  appears + a footer line).
- `bash -n bin/brief-view.sh` and run `./test.sh` (all green).

## Final layout (after review + user iteration)

The wrapping engine above shipped as designed; the *indent scheme* evolved through live
review against the dock. `_ifmt` ended up as a general nested hanging-indent formatter
(not the flat scheme first sketched):

- Headers and body/prose sit at a 2-col gutter.
- List items indent **under** their section header — top-level bullet glyph at col 4,
  text at col 6 — preserving glow's own nesting (leading structural spaces) and handling
  `N.` numbered items too.
- A wrapped item **hangs 2 columns past its text** (top-level → col 8) so continuations
  read as part of the item (the original's deeper look, but consistently applied).
- Invariant unchanged: every emitted line's display width ≤ W-1 (budget = (W-1) − hang),
  except a single unbreakable token longer than its budget.

The regression test exercises the **real** `_ifmt` (extracted from the staged
`brief-view.sh` via awk + eval, with a `declare -F` guard), not a mirror copy. Shipped
in v1.6.7.
