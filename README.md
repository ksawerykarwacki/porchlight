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
| M2 Reminders: escalation, snooze, quiet hours, digest | done |
| M3 Launcher: start a background session in any repo from a hotkey | next |
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

## Install

With [Homebrew](https://brew.sh), which builds Porchlight from source on your Mac:

```sh
brew trust --formula ksawerykarwacki/porchlight/porchlight
brew tap ksawerykarwacki/porchlight https://github.com/ksawerykarwacki/porchlight.git
brew install --HEAD porchlight
brew services start porchlight     # start now, and at every login
```

It needs the Xcode Command Line Tools and takes a few minutes to build. Because it is built on your
Mac and not downloaded as an app, macOS does not ask for it to be notarised. To update, use
**Update and restart** on the Settings tab, or `brew upgrade --fetch-HEAD porchlight`. To remove it:
`brew services stop porchlight && brew uninstall porchlight`.

Install it one way only: a copy built by hand with `./scripts/make-app.sh` would run alongside the
Homebrew one. To work on Porchlight, start with [`CONTRIBUTING.md`](CONTRIBUTING.md); what a signed,
downloadable release would still need is in [`packaging/`](packaging/README.md).

## Reminders

A session that keeps waiting gets a notification after 15 minutes, again with sound after 2 hours,
then every 4 hours. Each notification has Open and Snooze buttons, and Copy suggested reply when
the session came with one. A daily summary arrives at 09:00.

- **Snooze** from a notification, from the Snooze menu on an inbox row, or with
  `porchlight snooze <id> 1h` (also `30m`, `tomorrow`, `change`, `off`). A snoozed session stays in
  the inbox but does not light the menu-bar lantern or count towards its number.
- **Change the times** in the panel's Settings tab: the two steps, the repeat, the daily
  summary, quiet hours, and whether the question text appears in notifications. They are kept in
  `settings.json`; `porchlight settings` prints the ones in force.
- **Time-sensitive reminders** are off by default. "Mark as time-sensitive after" in the Settings
  tab marks the reminders of a session that has waited that long, so macOS may show them during a
  Focus. macOS only allows this level from a signed release: a build made with
  `./scripts/make-app.sh` keeps the setting but is not given the level, and the Settings tab
  says so.
- **During a Focus** macOS holds ordinary reminders back: no banner, no sound, and they wait in
  Notification Centre. Porchlight cannot see that a Focus is on, so its ladder does not pause.
  Add Porchlight to the Focus's allowed apps if you want its reminders to come through.
- **Retry.** A session that stopped on a passing failure (a rate or usage limit, the laptop going
  to sleep, the API being down) is marked "Can be retried" in the inbox. Its Retry button opens the
  session in your terminal and puts `continue` on the clipboard: paste it and press Return.
  Porchlight sends nothing by itself. What counts as such a failure is a list of patterns under
  `transientErrors` in `settings.json`.
- **The menu-bar lantern** is unlit when nothing waits, amber when a session waits, and red with
  rays once one has waited as long as the second step. The number appears from two sessions up.

If notifications are turned off for Porchlight in System Settings, the panel says so.
Set `PORCHLIGHT_NO_NOTIFICATIONS=1` to run the app without them.

## First run

The first time you open the panel, a card at the top lists what is left to set up: where your
repositories live, a shortcut, notifications, opening at login. Each has a button; "Hide these"
puts the card away, and the same choices stay on the Settings tab under General. If the `claude` command cannot be found or is too old, the card says so and
stays until that is fixed.

`porchlight settings export settings.json` and `porchlight settings import settings.json` move your
settings to another Mac.

## Repositories

Porchlight keeps a list of the folders you can start a session in. Tell it where your code lives and
it finds the repositories there:

```sh
porchlight repos root add ~/code   # search this folder, three levels deep
porchlight repos                   # list what was found
porchlight repos api               # the ones matching "api"
porchlight repos pin ~/code/api    # keep one at the top
```

A folder is a repository if it holds `.git`. Folders of sessions that already exist are listed too,
wherever they are. `node_modules`, `Library` and Claude Code's own worktrees are skipped; the depth
and the skipped names are under `repos` in `settings.json`.

## Starting a session

Click **New session** in the menu-bar panel, or run `porchlight new`, for the palette: type a few
letters of a repository, press Return, write what Claude should do, and press ⌘Return (⇧⌘Return also
opens the session in your terminal). The name is suggested from the prompt and can be changed.

The palette also lists your sessions, the ones waiting on you first. Return opens the selected
one; ⌘Return copies its suggested reply and opens it; ⌥Return snoozes it for an hour.

**Pin** a session you keep on purpose (⋯ → Pin, ⌘P in the palette, or `porchlight pin <id>`).
Pinned sessions are grouped at the top and are never offered for removal. "Turn its reminders off"
is for one whose normal state is waiting for you: it then stops reminding and stops lighting the
lantern.

The **Triage** tab (or `porchlight triage`) lists sessions that are finished, stopped, or have
waited for a week, and says for each whether it can go: *safe to remove* (nothing would be lost),
*needs a decision* (uncommitted or unpushed work), *stale* (waiting a long time) or *keep* (its pull
request is open). "Remove the safe ones" clears the first group in one go; Claude Code still checks
each one and refuses if anything would be lost. Pull requests are looked up with the GitHub CLI
(`gh`), if you have it.

Not sure what an old session was about? **Wrap up…** on its Triage row (or
`porchlight wrap-up <id>`) summarises it: what it was doing, where it stopped, and whether anything
would be lost. It asks first and says which model will do it. The session itself is never changed.
There are two ways, chosen under Settings, "Wrapping up":

- **This Mac** (the default where it is available): Apple's on-device model, through the `fm` tool
  that comes with macOS. Free, and nothing leaves the Mac. Its memory is small, so Porchlight gives
  it the first request and the end of the conversation, read from Claude Code's own files. Good for
  "where did this stop"; it can miss what was decided in the middle. It needs macOS 26 or later with
  Apple Intelligence, and Apple's terms accepted once: `sudo fm license`.
- **Claude**: a small Claude model (`haiku`, or `wrapUp.model` in `settings.json`) reads the whole
  conversation as a copy, with every tool off and nothing saved. More thorough, and it uses some of
  your Claude usage. Each question on this Mac also offers it for that one session.

The summary is kept as a note in Porchlight's own folder, also after the session is removed,
together with the command that opens the conversation again; `porchlight notes [TEXT]` lists or
searches the notes. Claude Code deletes old conversations by itself (`cleanupPeriodDays`, 30 days
unless you changed it), so a very old session may have nothing left to summarise.

To stop or remove a session, use the ⋯ menu on its row, ⌘S or ⌘D in the palette, or
`porchlight stop <id>` and `porchlight rm <id>`. Both ask first. If Claude Code refuses to remove
one, for example because its worktree has unpushed commits, Porchlight shows the reason. If that
reason names what would have to be discarded, "Discard and remove…" asks once more and then removes
it anyway; nothing is discarded without that second answer. Before a removal Porchlight tells you
how many uncommitted files and unpushed commits the session's worktree holds, and afterwards
whether the worktree folder is still on disk.

To open the palette from any app, set a shortcut on the Settings tab ("Shortcut for a new
session"): click "Use ⌃⌥⌘N", or record your own. None is set until you choose one, and Porchlight
needs no extra permission for it.

The same from a terminal or a script:

```sh
porchlight dispatch --repo api "Fix the rounding of invoice totals"
```

starts a Claude Code background session in the repository that best matches `api`, named from the
prompt, and prints its id. Use `--dir` for a folder instead of a search, `--open` to attach to it
straight away, and `--model`, `--effort`, `--agent`, `--permission-mode` or `--worktree` for the
matching `claude` options. Porchlight runs `claude --bg` for you and passes only options your
version of Claude Code lists in `claude --help`.

Claude Code refuses to start in a folder it has never been used in. Run `claude` there once and
accept its trust prompt; Porchlight does not try to get around it.

## Names

A session started from Porchlight is named from its prompt: "Fix the flaky settings test in CI"
becomes `fix-flaky-settings-test`. To change that, set a template under `naming` in `settings.json`,
for example `"template": "{repo}-{slug}"`. The tokens are `{repo}`, `{branch}`, `{ticket}`, `{slug}`
and `{date}`; `{ticket}` needs a `ticketPattern` (a regular expression such as `[A-Z]+-\\d+`) and is
looked for in the prompt, then in the branch. `porchlight name "your prompt"` shows the result.

## Terminals

Clicking a session runs `claude attach <id>` in your terminal. Pick the terminal in the panel's
Settings tab, or with `porchlight terminal ghostty` (`auto` goes back
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

If you keep a plain agent view (`claude agents`) open instead, set "When agent view is already
open" to "Switch to it" in the Settings tab: clicking a session then brings that terminal forward instead of opening a tab. You pick the
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

Porchlight is free software: copyright © 2026 Ksawery Karwacki, licensed under the
[GNU General Public License](LICENSE), version 3 or (at your option) any later version. You may use,
study, change and share it; if you distribute it or a version you changed, you must do so under the
same licence and make the source available. It comes with no warranty.

For use under other terms, ask the copyright holder.
