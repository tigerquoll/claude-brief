#!/usr/bin/env bash
# Copy the live brief-dock files from ~/.claude INTO this repo so local tweaks
# can be committed. Run before `git add -A && git commit`.
set -e
root="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$root"/claude/hooks "$root"/claude/bin "$root"/claude/bin/lib "$root"/claude/bin/term "$root"/claude/commands "$root"/iterm2/DynamicProfiles
cp ~/.claude/hooks/{task-prompt-hook,task-summary-hook,task-summary-worker,session-end-hook}.sh "$root"/claude/hooks/
cp ~/.claude/bin/{brief-open,brief-view,brief-prune,brief-summarize,brief-summarize-api,brief-term-profile}.sh "$root"/claude/bin/
cp ~/.claude/bin/lib/*.sh "$root"/claude/bin/lib/
for _d in common darwin linux; do            # mirror the term/<os>/ + term/common/ layout
  ls "$HOME"/.claude/bin/term/"$_d"/*.sh >/dev/null 2>&1 || continue
  mkdir -p "$root"/claude/bin/term/"$_d"
  cp "$HOME"/.claude/bin/term/"$_d"/*.sh "$root"/claude/bin/term/"$_d"/
done
cp ~/.claude/commands/brief.md "$root"/claude/commands/
cp ~/.claude/glow-brief.json "$root"/claude/
if [ -f "$HOME/Library/Application Support/iTerm2/DynamicProfiles/brief.json" ]; then
  cp "$HOME/Library/Application Support/iTerm2/DynamicProfiles/brief.json" "$root"/iterm2/DynamicProfiles/
fi
echo "synced live ~/.claude -> $root"
