#!/usr/bin/env bash
# Copy the live brief-dock files from ~/.claude INTO this repo so local tweaks
# can be committed. Run before `git add -A && git commit`.
set -e
root="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$root"/claude/hooks "$root"/claude/bin "$root"/claude/commands "$root"/iterm2/DynamicProfiles
cp ~/.claude/hooks/{task-prompt-hook,task-summary-hook,task-summary-worker,session-end-hook}.sh "$root"/claude/hooks/
cp ~/.claude/bin/{induct-open,induct-view,induct-prune,sessions-list}.sh "$root"/claude/bin/
cp ~/.claude/commands/{brief,sessions}.md "$root"/claude/commands/
cp ~/.claude/glow-induct.json "$root"/claude/
cp "$HOME/Library/Application Support/iTerm2/DynamicProfiles/induct.json" "$root"/iterm2/DynamicProfiles/
echo "synced live ~/.claude -> $root"
