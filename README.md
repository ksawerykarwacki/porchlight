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
| M2 Reminders: escalation, snooze, quiet hours, digest | in progress: reminders are delivered as notifications; snooze controls in the inbox and settings are not built yet |
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
swift run porchlight snooze <id> 1h   # pause reminders: 30m, 4h, tomorrow, change, or off
./scripts/make-app.sh           # build dist/Porchlight.app (ad-hoc signed, local use only)
open dist/Porchlight.app
```

## Reminders

A session that keeps waiting gets a notification after 15 minutes, again after 2 hours, then every
4 hours, with sound from 2 hours on. Each notification has Open and Snooze buttons, and Copy
suggested reply when the session came with one. A daily summary arrives at 09:00. macOS asks for
permission the first time a reminder is due, not at launch.

`porchlight snooze <id> 1h` (or `30m`, `tomorrow`, `change`, `off`) pauses reminders for one
session. Set `PORCHLIGHT_NO_NOTIFICATIONS=1` to run the app without notifications.

## Terminals

Clicking a session runs `claude attach <id>` in your terminal. Pick the terminal from the
"Terminal:" menu at the bottom of the inbox, or with `porchlight terminal ghostty` (`auto` goes back
to whichever is running). The choice is kept in
`~/Library/Application Support/Porchlight/settings.json`. Porchlight puts the command on the clipboard if it cannot drive the terminal. If the session is
already attached in a terminal, that terminal is brought to the front instead of opening a second
tab (none of these terminals lets another program select one particular tab).

### One tab that follows your clicks

Run `porchlight tab` in a terminal tab instead of `claude agents`. It shows agent view as usual.
When you click a session in Porchlight, that same tab switches to the session; leaving the session
(`←` or `Ctrl+Z`) returns to agent view, and quitting agent view ends `porchlight tab`. Nothing new
is opened. It works by starting and stopping the documented `claude agents` and
`claude attach <id>` commands in that tab; an agent view that is already running cannot be steered
from outside.

If you keep a plain agent view (`claude agents`) open instead, turn on "Use agent view when it is open" in the same
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

## How Porchlight relates to Claude Code

Porchlight is an independent project. It is not affiliated with, endorsed by, or sponsored by
Anthropic. "Claude" and "Claude Code" are Anthropic's trademarks, used here only to say what
Porchlight works with.

- It runs the `claude` program you installed yourself, unmodified. It does not include or
  redistribute Claude Code.
- It never reads, stores or passes on Claude sign-in details. You sign in to Claude Code yourself.
- It reads session state through `claude agents --json`, the interface Claude Code documents for
  that. It also reads `~/.claude/jobs/<id>/state.json` for the question a session is waiting on;
  Claude Code's docs call those files "not a stable interface", so Porchlight treats them as
  optional and works without them.
- It is built from Claude Code's public documentation and commands.

Your use of Claude Code itself stays subject to Anthropic's terms.

## License

Apache-2.0 for Porchlight's own code.
