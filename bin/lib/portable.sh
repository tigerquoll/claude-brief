# Portable file-stat helpers — the ONE place the brief scripts/hooks touch a file's
# mtime or permission bits, so the rest of the code is OS-agnostic. BSD stat (macOS)
# and GNU stat (Linux) take different flags, so we detect once at source time:
#   _mtime FILE  -> epoch seconds of last modification (0 if it can't be read)
#   _perm  FILE  -> octal permission bits, e.g. 644 (777 if it can't be read)
# Detection: GNU `stat -c` errors on BSD ("illegal option -- c"), so a successful
# `stat -c %Y /` means GNU; otherwise assume BSD. Kept bash-3.2-safe (sourced by the
# hooks, which run under macOS's bash 3.2). Linux porters: this is the file that
# makes `stat` portable — no other core script calls stat directly.
if stat -c %Y / >/dev/null 2>&1; then          # GNU coreutils (Linux)
  _mtime(){ stat -c %Y "$1" 2>/dev/null || echo 0; }
  _perm(){  stat -c %a "$1" 2>/dev/null || echo 777; }
else                                            # BSD stat (macOS/*BSD)
  _mtime(){ stat -f %m  "$1" 2>/dev/null || echo 0; }
  _perm(){  stat -f %Lp "$1" 2>/dev/null || echo 777; }
fi
