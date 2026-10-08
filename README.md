# Porchlight

A macOS menu-bar companion for [Claude Code](https://code.claude.com) background sessions: it shows
which sessions are waiting on you, and will remind you until you answer them.

Porchlight sits on top of Claude Code's own background sessions (`claude --bg`, `claude agents`). It
reads their state and never replaces agent view; uninstalling it loses nothing.

**Status:** early. The design is in [`spec.md`](spec.md). The read-only inbox works:

| Milestone | State |
|---|---|
| M0 Skeleton: core library, command-line tool, app bundle, test harness | done |
| M1 Read-only inbox with "open in terminal" | done |
| M2 Reminders: escalation, snooze, quiet hours, digest | next |
| M3 Launcher: start a background session in any repo from a hotkey | planned |
| M4 Stop and remove with confirmations | planned |
| M5 Onboarding, settings, signing, release | planned |

## Layout

| Target | What it is |
|---|---|
| `PorchlightCore` | Everything that is not UI. Foundation only, so other frontends can reuse it. |
| `PorchlightMac` | macOS pieces behind the core's interfaces: FSEvents watching, terminal launching. |
| `PorchlightUI` | The inbox's SwiftUI views and model. |
| `porchlight` | Command-line tool over the core. Its JSON output is the contract for other frontends. |
| `PorchlightApp` | The macOS menu-bar app. |

## Build

Needs macOS 14 or later, Swift 6, and the Claude Code CLI. Xcode is not required; the Command Line
Tools are enough.

```sh
swift test                      # unit and contract tests (uses a fake claude, not the real one)
swift run porchlight doctor     # check that the real claude CLI can be found and read
swift run porchlight status     # list sessions; add --json for the machine-readable form
swift run porchlight watch      # one JSON line now, and one after every change
swift run porchlight open <id>  # attach to a session in your terminal
./scripts/make-app.sh           # build dist/Porchlight.app (ad-hoc signed, local use only)
open dist/Porchlight.app
```

## Terminals

Clicking a session runs `claude attach <id>` in your terminal. Pick the terminal from the
"Terminal:" menu at the bottom of the inbox, or with `porchlight terminal ghostty` (`auto` goes back
to whichever is running). The choice is kept in
`~/Library/Application Support/Porchlight/settings.json`. Porchlight puts the command on the clipboard if it cannot drive the terminal. If the session is
already attached in a terminal, that terminal is brought to the front instead of opening a second
tab (none of these terminals lets another program select one particular tab).

If you keep agent view (`claude agents`) open, turn on "Use agent view when it is open" in the same
menu: clicking a session then brings that terminal forward instead of opening a tab. You pick the
session in agent view yourself, because nothing outside it can select a row there.

| Terminal | How | Notes |
|---|---|---|
| Warp | a tab config plus `warp://tab_config/porchlight` | Opens a tab. Writes one file, `~/.warp/tab_configs/porchlight.toml`, which also appears in Warp's "+" menu. |
| WezTerm | `wezterm start --cwd … -- …` | Opens a window. |
| Terminal | a `.command` file | Opens a window. No Automation permission needed. |
| Ghostty | `open -na Ghostty.app --args -e …` | Ghostty asks for confirmation every time; that is its own safeguard and cannot be turned off. |

## Privacy

Porchlight is local only. It runs the `claude` CLI and reads `~/.claude/jobs/*/state.json`
read-only for the question a session is waiting on. It never reads the fields that can hold your
prompt or environment values. The only file it writes outside its own folder is the Warp tab config
above, and only when you open a session in Warp.

## License

Apache-2.0. Not affiliated with or endorsed by Anthropic.
