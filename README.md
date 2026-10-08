# Porchlight

A macOS menu-bar companion for [Claude Code](https://code.claude.com) background sessions: it shows
which sessions are waiting on you, and will remind you until you answer them.

Porchlight sits on top of Claude Code's own background sessions (`claude --bg`, `claude agents`). It
reads their state and never replaces agent view; uninstalling it loses nothing.

**Status:** early. The design is in [`spec.md`](spec.md). Milestone M0 (skeleton) is done:

| Milestone | State |
|---|---|
| M0 Skeleton: core library, command-line tool, app bundle, test harness | done |
| M1 Read-only inbox with "open in terminal" | next |
| M2 Reminders: escalation, snooze, quiet hours, digest | planned |
| M3 Launcher: start a background session in any repo from a hotkey | planned |
| M4 Stop and remove with confirmations | planned |
| M5 Onboarding, settings, signing, release | planned |

## Layout

| Target | What it is |
|---|---|
| `PorchlightCore` | Everything that is not UI. Foundation only, so other frontends can reuse it. |
| `porchlight` | Command-line tool over the core. Its JSON output is the contract for other frontends. |
| `PorchlightApp` | The macOS menu-bar app. |

## Build

Needs macOS 14 or later, Swift 6, and the Claude Code CLI. Xcode is not required; the Command Line
Tools are enough.

```sh
swift test                      # unit and contract tests (uses a fake claude, not the real one)
swift run porchlight doctor     # check that the real claude CLI can be found and read
swift run porchlight status     # list sessions; add --json for the machine-readable form
./scripts/make-app.sh           # build dist/Porchlight.app (ad-hoc signed, local use only)
open dist/Porchlight.app
```

## Privacy

Porchlight is local only. It runs the `claude` CLI and reads `~/.claude/jobs/*/state.json`
read-only for the question a session is waiting on. It never reads the fields that can hold your
prompt or environment values.

## License

Apache-2.0. Not affiliated with or endorsed by Anthropic.
