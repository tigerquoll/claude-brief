#!/usr/bin/env bash
# Copy the live brief-dock files from ~/.claude INTO this repo so local tweaks
# can be committed. Run before `git add -A && git commit`.
set -e
root="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$root"/claude/hooks "$root"/claude/bin "$root"/claude/bin/lib "$root"/claude/bin/term "$root"/claude/commands "$root"/iterm2/DynamicProfiles
cp ~/.claude/hooks/{task-prompt-hook,task-summary-hook,task-summary-worker,session-end-hook}.sh "$root"/claude/hooks/
cp ~/.claude/bin/{brief-open,brief-view,brief-prune,brief-summarize,brief-summarize-api}.sh "$root"/claude/bin/
cp ~/.claude/bin/lib/*.sh "$root"/claude/bin/lib/
cp ~/.claude/bin/term/*.sh "$root"/claude/bin/term/
cp ~/.claude/commands/brief.md "$root"/claude/commands/
cp ~/.claude/glow-brief.json "$root"/claude/
if [ -f "$HOME/Library/Application Support/iTerm2/DynamicProfiles/brief.json" ]; then
  cp "$HOME/Library/Application Support/iTerm2/DynamicProfiles/brief.json" "$root"/iterm2/DynamicProfiles/
fi
echo "synced live ~/.claude -> $root"
