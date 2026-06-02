#!/usr/bin/env bash
# Deploy repo -> ~/.claude (+ the iTerm2 dock profile). Use to restore/recover or
# set up a new machine. Does NOT touch settings.json — add the hook entries by
# hand (see README).
set -e
root="$(cd "$(dirname "$0")" && pwd)"
mkdir -p ~/.claude/hooks ~/.claude/bin ~/.claude/commands "$HOME/Library/Application Support/iTerm2/DynamicProfiles"
cp "$root"/claude/hooks/*.sh ~/.claude/hooks/
cp "$root"/claude/bin/*.sh ~/.claude/bin/
cp "$root"/claude/commands/*.md ~/.claude/commands/
cp "$root"/claude/glow-induct.json ~/.claude/
cp "$root"/iterm2/DynamicProfiles/induct.json "$HOME/Library/Application Support/iTerm2/DynamicProfiles/"
chmod +x ~/.claude/hooks/*.sh ~/.claude/bin/*.sh
echo "installed brief-dock files into ~/.claude  (add the settings.json hooks per README)"
