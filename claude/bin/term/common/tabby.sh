# tabby driver — RECOGNIZED MANUAL FALLBACK (Tabby cannot be auto-docked).
#
# Tabby (org.tabby, an Electron app) exposes NO way for an external, tty-less process
# like brief-open to open a docked split. Researched Jun 2026 against Tabby on macOS:
#   • Splits are UI/keyboard only — there is NO CLI or automation to create a split.
#   • Its CLI verbs (`run`/`open`/`profile`/`paste`, via the app binary) open a new
#     TAB, not a split; `run` even prompts for confirmation. They return no tab id and
#     there is no verb to close/target a specific tab — so the open→id→close-by-id
#     driver contract can't be met (a tab-spawning driver would orphan docks forever).
#   • No AppleScript dictionary (no .sdef, NSAppleScriptEnabled unset) → no osascript.
#   • The only file socket is Electron's SingletonSocket (instance lock), not an RPC.
# The only programmatic in-app control is a Tabby PLUGIN (TypeScript) loaded inside
# the app — a different, much larger deliverable. So we behave like `generic`: leave
# the open to the user, but PRINT Tabby-specific guidance. brief-open treats `tabby`
# like `generic` (prints the `brief-view.sh <sid>` line + exits 0). Sourced — 3.2-safe.

tdrv_name(){ printf 'tabby'; }
tdrv_detect(){ [ "${TERM_PROGRAM:-}" = Tabby ] || [ -n "${TABBY_CONFIG_DIRECTORY:-}" ]; }

# No per-pane/-tab env id (Tabby sets only the app-global $TABBY_CONFIG_DIRECTORY),
# so there's no stable self id — brief-open falls back to the cwd->sid map (which the
# prompt hook still writes), then to the newest brief.
tdrv_self_pane(){ :; }

# Can't script a split -> return empty (brief-open then prints the manual command).
# Add the Tabby-specific "how to make a split" hint on stderr so the user isn't left
# guessing. The tab ≡ (hamburger) menu ▸ Split is the reliable path; the keyboard
# shortcut is user-configurable (Settings ▸ Hotkeys ▸ "Split to the right"), so we
# point at the menu rather than assert a possibly-rebound key.
tdrv_open(){
  {
    printf 'brief: Tabby has no scriptable split or remote control, so the dock\n'
    printf '       can'\''t open automatically. Make a split yourself — the tab'\''s ≡ menu\n'
    printf '       ▸ Split ▸ Right (or your configured "Split to the right" hotkey) —\n'
    printf '       then run the viewer printed below in that pane.\n'
  } >&2
  :
}

tdrv_close(){ :; }   # nothing to close (no tab/pane handle to act on)
