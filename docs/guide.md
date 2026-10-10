# The Porchlight guide

How each part works, every setting, and the command line. For what Porchlight is and how to install
it, see the [README](../README.md).

- [First run](#first-run)
- [Reminders](#reminders)
- [The palette: starting and finding sessions](#the-palette-starting-and-finding-sessions)
- [Repositories](#repositories)
- [Names](#names)
- [Pins](#pins)
- [Triage](#triage)
- [Wrap-up and notes](#wrap-up-and-notes)
- [Stopping and removing](#stopping-and-removing)
- [Terminals](#terminals)
- [Command line](#command-line)
- [Privacy](#privacy)
- [Porchlight and Claude Code](#porchlight-and-claude-code)

## First run

The first time you open the panel, a card at the top lists what is left to set up: where your
repositories live, a shortcut, notifications, opening at login. Each has a button; "Hide these"
puts the card away, and the same choices stay on the Settings tab under General. If the `claude` command cannot be found or is too old, the card says so and
stays until that is fixed.

`porchlight settings export settings.json` and `porchlight settings import settings.json` move your
settings to another Mac.

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
  What counts as such a failure is a list of patterns under `transientErrors` in `settings.json`.
  With the companion mod, the session reports the failure itself and Retry sends `continue`
  straight to it, without opening anything.
- **Replying from the panel.** With the companion mod, a session that has finished a turn and
  waits for you has a reply field under what it said. Type and press Return: your text goes to the
  session as your message, and the session carries on. A reply Claude Code suggests can be put in
  the field with "Use as reply"; it is sent only when you send it. If the session is not listening
  (it was stopped, or has no mod), nothing is sent: your text is put on the clipboard so you can
  open the session and paste it. A reply written for one turn is not sent to a later one.
- **Trying again by itself.** Off unless you turn it on in Settings ("Try again by itself", with
  the wait before the first try). Then, for a session with the companion mod that stopped on a
  rate limit, an overloaded API or a server error, Porchlight sends your resend line after that
  wait: at most three times in a row, waiting twice as long each time, and starting over once a
  turn succeeds. The row says when the next try is and has "Don't retry" for that one failure.
  Failures that need you (sign-in, billing, a bad request) are never retried, nor are sessions
  without the mod. Each try uses your Claude usage. In `settings.json` it is
  `transientErrors.autoRetry` with `after` (seconds) and `attempts`; `null` or absent is off.
- **The menu-bar lantern** is unlit when nothing waits, amber when a session waits, and red with
  rays once one has waited as long as the second step. The number appears from two sessions up.

If notifications are turned off for Porchlight in System Settings, the panel says so.
Set `PORCHLIGHT_NO_NOTIFICATIONS=1` to run the app without them.

## The palette: starting and finding sessions

Click **New session** in the menu-bar panel, or run `porchlight new`, for the palette: type a few
letters of a repository, press Return, write what Claude should do, and press ⌘Return (⇧⌘Return also
opens the session in your terminal). The name is suggested from the prompt and can be changed.

The palette also lists your sessions, the ones waiting on you first. Return opens the selected
one; ⌘Return copies its suggested reply and opens it; ⌥Return snoozes it for an hour.

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

## Names

A session started from Porchlight is named from its prompt: "Fix the flaky settings test in CI"
becomes `fix-flaky-settings-test`. To change that, set a template under `naming` in `settings.json`,
for example `"template": "{repo}-{slug}"`. The tokens are `{repo}`, `{branch}`, `{ticket}`, `{slug}`
and `{date}`; `{ticket}` needs a `ticketPattern` (a regular expression such as `[A-Z]+-\\d+`) and is
looked for in the prompt, then in the branch. `porchlight name "your prompt"` shows the result.

## Pins

**Pin** a session you keep on purpose (⋯ → Pin, ⌘P in the palette, or `porchlight pin <id>`).
Pinned sessions are grouped at the top and are never offered for removal. "Turn its reminders off"
is for one whose normal state is waiting for you: it then stops reminding and stops lighting the
lantern.

## Triage

The **Triage** tab (or `porchlight triage`) lists sessions that are finished, stopped, or have
waited for a week, and says for each whether it can go: *safe to remove* (nothing would be lost),
*needs a decision* (uncommitted or unpushed work), *stale* (waiting a long time) or *keep* (its pull
request is open). "Remove the safe ones" clears the first group in one go; Claude Code still checks
each one and refuses if anything would be lost. Pull requests are looked up with the GitHub CLI
(`gh`), if you have it.

## Wrap-up and notes

Not sure what an old session was about? **Wrap up…** on its Triage row (or
`porchlight wrap-up <id>`) summarises it: what it was doing, where it stopped, and whether anything
would be lost. It asks first and says which model will do it. The session itself is never changed.
There are two ways, chosen under Settings, "Wrapping up":

- **This Mac** (the default where it is available): Apple's on-device model, through the `fm` tool
  that comes with macOS. Free, and nothing leaves the Mac. Its memory is small, so Porchlight gives
  it the first request and the end of the conversation, read from Claude Code's own files. Good for
  "where did this stop"; it can miss what was decided in the middle. It needs Apple Intelligence and the
  `fm` tool (checked on macOS 27), and Apple's terms accepted once: `sudo fm license`.
- **Claude**: a small Claude model (`haiku`, or `wrapUp.model` in `settings.json`) reads the whole
  conversation as a copy, with every tool off and nothing saved. More thorough, and it uses some of
  your Claude usage. Each question on this Mac also offers it for that one session.

The summary is kept as a note in Porchlight's own folder, also after the session is removed.
To read the notes, press **Tab** in the palette: it turns into a list of them, searched as you
type, with the selected note shown in full below, so the arrow keys are all it takes to read
through them. Return opens the session if it is still there, resumes its conversation in a
terminal if it was removed, and copies the summary when that is all that is left; ⌘Return copies
the summary, ⌘D deletes the note, Tab goes back. The Triage tab links there too, and
`porchlight notes [TEXT]` lists or searches them on the command line. Claude Code deletes old conversations by itself (`cleanupPeriodDays`, 30 days
unless you changed it), so a very old session may have nothing left to summarise.

## Stopping and removing

To stop or remove a session, use the ⋯ menu on its row, ⌘S or ⌘D in the palette, or
`porchlight stop <id>` and `porchlight rm <id>`. Both ask first. If Claude Code refuses to remove
one, for example because its worktree has unpushed commits, Porchlight shows the reason. If that
reason names what would have to be discarded, "Discard and remove…" asks once more and then removes
it anyway; nothing is discarded without that second answer. Before a removal Porchlight tells you
how many uncommitted files and unpushed commits the session's worktree holds, and afterwards
whether the worktree folder is still on disk.

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
| iTerm2 | a `.command` file | Opens a tab, or a window when none is open. No Automation permission needed. |
| Terminal | a `.command` file | Opens a window. No Automation permission needed. |
| Ghostty | `open -na Ghostty.app --args -e …` | Ghostty asks for confirmation every time; that is its own safeguard and cannot be turned off. |

## Command line

Everything the app shows is available from `porchlight`, with `--json` where a script would want
it. `porchlight help` lists every command.

```sh
porchlight status                 # list sessions; add --json for the machine-readable form
porchlight watch                  # one JSON line now, and one after every change
porchlight open <id>              # attach to a session in your terminal
porchlight snooze <id> 1h         # pause reminders: 30m, 4h, tomorrow, change, or off
porchlight dispatch --repo api "Fix the rounding of invoice totals"
porchlight triage                 # which idle sessions can go
porchlight wrap-up <id>           # summarise a session and keep the note
porchlight notes login            # search the notes
porchlight pin <id>               # keep a session; unpin to undo
porchlight stop <id>              # stop a session; rm <id> removes it
porchlight settings               # print the settings in force
porchlight update                 # build the latest app, start it, and update the installed mods
porchlight doctor                 # check that the claude CLI can be found and read
```

## Privacy

Porchlight is local only: no account, no server, no telemetry. What it touches on your Mac:

- **It runs the `claude` command** to list, start, open, stop and remove sessions.
- **It asks your login shell for its environment once, at launch**, so that sessions started from
  Porchlight have the same `PATH` and variables as ones you start in a terminal. The values are
  passed on to `claude` and kept in memory only: never logged, never written to disk.
- **It reads `~/.claude/jobs/*/state.json`**, read-only, for the question a session is waiting on
  and Claude Code's one-sentence summary of where it stands.
  It never reads the fields that can hold your prompt or environment values.
- **For a summary on this Mac, it reads that one session's conversation file**
  (`~/.claude/projects/…/<id>.jsonl`), read-only, and only when you ask for the summary. It takes
  what you and the assistant wrote, questions the session asked you, and the one-line description
  of each tool call. It does not take commands, tool output or thinking. That text goes to Apple's
  on-device model through the `fm` tool and stays on your Mac.
- **For a summary with Claude, it reads nothing itself:** Claude Code reads its own copy of the
  conversation, with every tool off and nothing saved.
- **It listens on a private socket** (`companion.sock` in its own folder, or under `/tmp/porchlight-<uid>/`
  when that path is too long) for reports from the optional companion mod. Only your user can open
  it, every request must carry a secret from `companion.json`, which only you can read and which is
  new each time the app starts, and nothing listens on the network. Without the mod nothing ever
  connects.
- **The companion mod, if you install it,** sends the app a session's question, the approval it
  asks for (the tool and one line), when turns start, finish or fail, and, when a turn finishes,
  the end of what the session said (up to 1,500 characters), which the panel shows for a session
  that is waiting, the palette for the selected session, and a notification in place of the
  question (unless you turned question text off in Settings). The app keeps it in memory until the
  session's next turn and never logs or saves it; a notification stays in Notification Centre as
  any other does. The mod does not send your prompts, your answers, any tool output, or the rest of the
  replies; the full list is in [its README](../mods/companion/README.md).
- **Answering from the panel or the palette.** With the mod, a question that has options to pick
  one of shows them as buttons. In the panel, click one, then **Send**. In the palette, select the
  session and press ⌘1 to ⌘9 for an option (or click it), then Return; Escape drops the choice. The
  app gives the mod that option and the mod hands it to the session as the answer. Nothing is sent
  on the first click or key, Porchlight never picks or writes
  an answer itself, and the session's own dialog still works. Questions with several parts or a
  typed answer are answered in the session.
- **It writes only in its own folder**, `~/Library/Application Support/Porchlight/` (settings,
  reminders, pins, notes, a log), plus one Warp tab config when you open a session in Warp.

## Porchlight and Claude Code

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
