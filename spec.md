# Porchlight — a macOS companion for Claude Code background sessions

> **Name.** "Porchlight": the light left on for whoever is waiting. Chosen 2026-10-08 after the first working name, "Lantern", turned out to collide with a Homebrew package and several Mac apps. Checked against Homebrew, GitHub repository names and the US Mac App Store; trademarks and domains were not checked.
>
> **Status:** design draft, 2026-10-08; decisions D1–D5 confirmed and M0 built the same day (see `README.md`). Written to be picked up by a fresh Claude Code session on a clean machine. Nothing in here may assume a particular company, repo layout, ticket system or terminal.

---

## 0. How to use this document (read first if you are the implementing session)

1. Read the whole document once.
2. **Re-verify Appendix A against the installed Claude Code** (`claude --version`, `claude --help`, `claude agents --json --all`). Appendix A was observed on v2.1.294; the CLI ships fast. Update the appendix where reality differs.
3. Walk the human through **§14 Open decisions** one at a time. Items marked **[PROPOSED]** are recommendations, not agreements. Items marked **[DECIDED]** were confirmed by the human.
4. Present each major section of §5–§9 to the human for approval. If a brainstorming / plan-writing skill is available, use it; otherwise do this in chat and write the plan to a file. The design sections here were drafted in one pass and **have not been approved section by section**.
5. Only then write an implementation plan (milestones in §15) and start building.

Decision markers used throughout: **[DECIDED]**, **[PROPOSED]**, **[OPEN]**, **[SPIKE]** (needs a feasibility experiment before committing).

---

## 1. Problem

Claude Code can run many sessions in the background (`claude --bg`, managed in the terminal UI `claude agents`, "agent view"). Heavy users run 5–15 at once across many repositories. Two pains dominate:

**P1 — Lost inbox.** Sessions finish a turn and wait for a human (a question, a decision, a permission prompt). The built-in notification fires once, shortly after the turn ends, and only if a terminal is in front of you. If you miss it, nothing reminds you. Evidence from one heavy user over 30 days:
- At most **4** sessions were actively working at the same time, but up to **14** were open.
- **15** sessions sat `blocked` with a median wait of **~3 weeks**, mostly on one-line answers. Two were blocked only on transient errors (laptop slept, usage limit), never retried.
- ~**14** context switches per weekday, median stint of 2 prompts per session before switching.
- 16% of prompts were sent between 22:00 and 02:00 — catching up on cold sessions late.

**P2 — Dispatch friction.** To start a background session in a repo you must `cd` there in some terminal and run `claude --bg "…"`. Agent view's `@repo` only suggests git repos **one level below** the directory it was launched from, so users who keep repos deeper (e.g. `~/code/<org>/<repo>`) fall back to a spare terminal.

**Secondary pains:** auto-generated session names are frozen first-prompt summaries (hard to scan, poor messaging addresses); finished sessions accumulate (84 open rows, 64 of which were safe to delete).

## 2. Goals

- **G1** Never lose a waiting session: always-visible count, a scannable inbox, and reminders that escalate until handled or snoozed.
- **G2** Start a background session in any repository from anywhere in macOS in a few keystrokes, with a good name.
- **G3** Zero lock-in: sit on top of Claude Code's own background-session system. Agent view in the terminal keeps working side by side; uninstalling Porchlight loses nothing.
- **G4** Project-agnostic and safe by default: works for any user, any repo layout, any terminal; read-only unless the user clicks.

## 3. Non-goals (v1)

- Not a Claude Code GUI/chat client. Conversations happen in the terminal (`claude attach`).
- Not an orchestrator: no auto-replies, no agent-to-agent routing, no autonomous decisions.
- No cloud service, account system or telemetry.
- No Windows/Linux in v1 (keep core logic portable where cheap).
- Not a usage/cost tracker (other apps do this).

## 4. Users and context

- **Primary:** developers running several Claude Code background sessions daily on macOS, living mostly in one terminal (often agent view itself) plus a scratch/drop-down terminal.
- **Secondary:** occasional users who want a notification when their one long background task needs them.
- **Assumed environment:** macOS 14+, Claude Code CLI installed and logged in, at least one git repository. Nothing else.

## 5. Concepts (as Claude Code exposes them)

- **Background session:** a Claude Code session hosted by a local supervisor/daemon, not by a terminal. Survives closing the terminal; stops when the Mac shuts down. Identified by a short **id** (8 hex chars) and a full **sessionId** (UUID).
- **State** (from `claude agents --json`): `working`, `blocked` (waiting on the human), `done` (turn finished / exited). Treat unknown values as `unknown`, never crash.
- **Status** (optional field): e.g. `busy`, `idle`, `waiting`. Present only for live processes.
- **Worktree:** sessions that edit files move into a git worktree under `<repo>/.claude/worktrees/<name>`. Deleting a session can delete its worktree; the CLI refuses when that would lose unpushed commits.
- **Agent view:** the terminal UI `claude agents`. Porchlight complements it and must never conflict with it.

## 6. Features

> **Focus (2026-10-08).** A GitHub search found several free menu-bar apps that already show which session is waiting (Appendix C). None re-notifies, snoozes or escalates, and none starts a Claude Code background session. Reminders (§6.2) and the launcher (§6.3) are therefore the product; the inbox (§6.1) stays minimal.

### 6.1 Inbox (menu bar) — v1 **[PROPOSED]**

**FR-I1** Menu-bar icon with badge: number of sessions needing the human. Icon state: idle / something waiting / something waiting longer than the escalation threshold.

**FR-I2** Dropdown lists sessions grouped: **Needs you** (blocked), **Working**, **Recently done** (last N hours, configurable), each sorted by wait time (oldest first in Needs you).

**FR-I3** Each row shows: name, repo (derived by stripping `/.claude/worktrees/<name>` from the CLI's `cwd`, which is the worktree path once a session has moved into one), age since last activity, and when available the **question it's waiting on** and **Claude's suggested reply** (from internal job state, see Appendix B; omit gracefully if absent).

**FR-I4** Row actions:
- **Open** → opens the user's terminal and runs `claude attach <id>`.
- **Copy suggested reply** (if present) — then Open. Often absent: a session blocked on a multiple-choice question has structured options instead (Appendix B, `block`), and a session blocked on a permission prompt has neither. Show the options or the command awaiting approval in those cases.
- **Snooze** 1h / until tomorrow 09:00 / until state changes.
- **Stop** (`claude stop <id>`), **Remove** (`claude rm <id>`) — confirm first; surface the CLI's refusal text verbatim if it refuses.
- **Show logs** → `claude logs <id>` in a scrollable popover. The output is raw terminal data full of cursor and colour escape sequences, so it needs a terminal renderer or stripping, not a plain text view.

**FR-I5** Footer: "Open agent view" (terminal + `claude agents`), "New session…" (launcher), Settings, Quit.

**FR-I6** Refresh within ≤ 3 s of a state change (see §8.3).

Acceptance: with 3 blocked sessions, badge shows 3; answering one in the terminal drops the badge to 2 within 3 s; no CLI calls block the UI thread.

### 6.2 Nagger (reminders) — v1 **[PROPOSED]**

**FR-N1** macOS notification when a session enters `blocked`, titled with the session name, body = the question if known, else "needs your input". Grouped per session (re-notify replaces, doesn't stack).

**FR-N2** Escalation ladder, configurable. Default: at 0 min (only if Porchlight detects it before Claude's own notification would be visible — **[OPEN]** whether to duplicate), 15 min, 2 h, then every 4 h; from 2 h add sound; optional "time-sensitive" interruption level from 4 h.

**FR-N3** Notification actions: **Open**, **Snooze 1h**, **Copy suggested reply**.

**FR-N4** Quiet hours and macOS Focus respected; ladder pauses during quiet hours and resumes after.

**FR-N5** Daily digest at a configurable time (default 09:00): one notification "N sessions waiting, oldest Xd" → opens the inbox.

**FR-N6** Transient-error detection: if the waiting text matches known transient failures (rate limit, usage limit, "went to sleep", API unavailable — patterns in settings, not hardcoded), label the row **Retry-able** and offer a one-click action. **[SPIKE]** which CLI action correctly retries (candidates: `claude respawn <id>`, or attach and resend) — see §11.

**Built in M2 layer 1 (2026-10-08): the logic, without delivery.** `ReminderPlanner` in the core takes the sessions, the saved state and a clock, and returns the reminders that are due:

- Ladder default: 15 min, 2 h, then every 4 h; sound from 2 h. Steps are counted from when the session started waiting on its current question, so a new question starts a new ladder.
- One reminder per step. After an absence (app not running, laptop asleep) all missed steps collapse into a single reminder.
- Snooze: for a duration or until tomorrow 09:00 (silent, then one reminder when it ends), or until the session waits on something new. Snoozes are dropped when the session stops waiting.
- Quiet hours: nothing is sent and nothing is recorded as sent, so the missed reminder goes out once when they end.
- Digest: once a day at or after its time, also when the app starts late; the day counts as used even if nothing was waiting.
- State (`reminders.json`) is saved so a restart repeats nothing. `porchlight snooze <id> …` sets a snooze and `status --json` reports it.
- Not built yet: respecting macOS Focus (FR-N4), the "time-sensitive" level, transient-error detection (FR-N6), snooze controls in the inbox, and settings for the ladder and quiet hours.

**Built in M2 layer 2 (2026-10-08): delivery.** `ReminderEngine` (core) runs the planner on every store update, delivers what is due, saves the state, and withdraws a session's reminder when it stops waiting or is snoozed. It re-reads the state file each time, so a snooze set with `porchlight snooze` takes effect in the running app. `UserNotificationDelivery` (macOS) posts notifications:

- One notification per session, replaced by the next one for that session rather than stacked (FR-N1).
- Buttons: Open, Snooze 1 hour, Snooze until tomorrow, and Copy suggested reply when there is one; clicking the notification itself opens the session (FR-N3).
- Permission is requested the first time a reminder is due. If it is denied the inbox keeps working and says, above its buttons, that notifications are off.
- First real run (macOS 27, ad-hoc signed bundle, 2026-10-08): no prompt was noticed and nothing was shown; the authorization status read "denied". After the user turned notifications on for Porchlight in System Settings, the daily summary and one reminder per waiting session appeared with the right titles and text. Why the status was "denied" is not established; macOS presents the permission request as a banner that goes away by itself, so it may simply have been missed. Onboarding (M5) should therefore check the status and point to the setting rather than rely on the prompt.
- The reason delivery is not working is kept in `notification-status.txt` in the state folder.
- Delivery is on only inside an app bundle and off when `PORCHLIGHT_NO_NOTIFICATIONS` is set, so tests and bare executables never post or prompt.

**Built in M2 layers 3 to 6 (2026-10-08).**

- Menu-bar icon: a drawn wall lantern in the menu bar's own colour with only its light coloured; unlit, amber, or red with rays (FR-I1). The count shows from two up. Snoozed sessions are left out of the icon, the count and the daily summary.
- Inbox: hover states, a lamp per row, options as chips, a Snooze menu per waiting row (an hour, until tomorrow morning, until it asks something new, stop).
- Settings page in the panel for the two ladder steps, the repeat, the daily summary, quiet hours and whether the question text appears in notifications. Stored under `reminders` in `settings.json`, read tolerantly (each odd value falls back to its default on its own; an explicit null means off), and re-read on every refresh so a change applies without a restart.
- Still not built from §6.2: phone push (FR-N7). The "time-sensitive" level (FR-N2), macOS Focus (FR-N4) and transient-error detection (FR-N6) are covered in the notes that follow.

**Built in M2, the leftovers (2026-10-09): the time-sensitive level, and what Focus does.**

*Time-sensitive level (FR-N2), built.*

- A new reminder setting, `timeSensitiveAfter` (seconds, under `reminders` in `settings.json`): once a session has waited that long, its reminders are marked time-sensitive. Off by default; the Settings page offers Off, 1, 2, 4, 8 and 24 hours. Read as tolerantly as the rest: a missing value, an explicit null, zero, a negative number or anything that is not a number all mean off, and none of them disturbs the other settings.
- The mark is judged by how long the session has waited when the reminder goes out, not by which step it is. Reaching the time sends nothing by itself: with the default ladder and 4 hours, the reminders at 15 minutes and 2 hours are ordinary and the repeat at 6 hours is the first marked one. A new question starts ordinary again. The daily summary is never marked.
- Quiet hours win: a time-sensitive reminder is held back during quiet hours like any other and goes out, marked, when they end.
- `Reminder.timeSensitive` → `NotificationPlan.level` → `UNNotificationContent.interruptionLevel = .timeSensitive`. Where macOS has reported that the app may not use the level, delivery sends the reminder as an ordinary one instead of asking for it.

*What macOS does with it: measured, not honoured for the ad-hoc build.*

- Measured on 2026-10-09, macOS 27.0 (26A428), on `dist/Porchlight.app` built by `scripts/make-app.sh` (ad-hoc signature, no entitlements, checked with `codesign -d --entitlements -`): `UNNotificationSettings.timeSensitiveSetting` is **`notSupported`**, while `authorizationStatus` is `authorized`. So notifications are allowed for the app and the time-sensitive level is not available to it. How: the app now reads its notification settings at launch (reading never prompts) and writes them to `notification-level.txt` in the state folder; the built app was started as a second copy with `PORCHLIGHT_STATE_DIR` pointing at a temporary folder and a `settings.json` with no ladder, no repeat and no summary, so nothing was posted, and stopped again after it had written the file.
- The entitlement cannot be added to an ad-hoc build. A copy of the bundle signed ad hoc with `com.apple.developer.usernotifications.time-sensitive` was killed by macOS at launch (signal 9); it wrote nothing, not even the file above. The entitlement needs a signature from a developer team with a provisioning profile that grants it: that is M5 (signing).
- Not checked: what a reminder sent with the level looks like, or whether it breaks through a Focus. No time-sensitive notification was posted. Apple's documentation says the level "can break through system controls such as Notification Summary and Focus" and that "the user can turn off the ability"; what macOS does when an app without the entitlement asks for the level anyway was not tried, which is why delivery does not ask in that case.
- The setting ships anyway and is not hidden. When it is on and macOS reports `notSupported`, the Settings page says under the row that this build cannot send time-sensitive notifications and that they need a signed release; when macOS reports the level as turned off by the user, it points to System Settings. On a signed release with the entitlement the note goes away by itself, because it follows what macOS reports and not how the app was built.
- Hand-off to M5: sign with the Time Sensitive Notifications capability, then repeat the measurement (expect `enabled`) and check by eye that a marked reminder appears during a Focus.

*Focus (FR-N4): left to macOS; the ladder does not pause. Not built, by decision.*

- What macOS does, from Apple's documentation: a Focus filters which notifications may interrupt. Ordinary ("active") notifications do not break through it; time-sensitive ones do, if the user allows that. "Even though a Focus might delay the delivery of a notification alert, the notification itself is available as soon as it arrives" (Human Interface Guidelines, Managing notifications). So while a Focus is on and Porchlight is not among its allowed apps, a reminder shows no banner and plays no sound, and is waiting in Notification Centre (this is the project's reading of that sentence; no reminder was posted during a Focus to watch it). In that sense Focus is respected without any code: Porchlight never interrupts a Focus.
- What Porchlight does not do: pause the ladder. It cannot tell that a Focus is on, so it sends the reminder and records the step as sent. When the Focus ends nothing is sent again; the next banner comes with the next step or repeat. The reminder itself is not lost: there is one notification per session and it stays in Notification Centre, and the inbox and the menu-bar lantern show the session throughout.
- Why it is not built: the only public way to learn that a Focus is on is `INFocusStatusCenter` (Intents framework). Apple's sample states its requirements: the user's authorization (a system prompt, with a `NSFocusStatusUsageDescription` text in Info.plist), notifications authorized, and the Communication Notifications capability, which is an entitlement. An ad-hoc build cannot carry an entitlement of this kind (see the measurement above), so a detector would always answer "unknown" and the pause would never happen. A protocol with only a test double behind it would be a pretence, so none was added. This was established from the documentation; `INFocusStatusCenter` was not called on this machine, because asking for its authorization shows a system prompt.
- A second reason to think again in M5 before building it: the answer is given from the app's own point of view ("the user doesn't appear focused to an app if an enabled Focus allows notifications from that app") and the API exists for messaging apps to tell other people that someone is unavailable. Whether a reminder app may hold the Communication Notifications capability at all is a question for M5.
- Hand-off to M5 (signing): decide whether to request the capability. If yes, add a `FocusStatus` protocol in `PorchlightMac` with the `INFocusStatusCenter` implementation and a test double, and have the planner treat "Focus on" as it treats quiet hours (nothing sent, nothing recorded, so the reminder goes out when it ends). If no, close FR-N4 as "left to macOS".
- What a user can do today: add Porchlight to a Focus's allowed apps in System Settings > Focus to get its reminders during that Focus, or leave it out to have them wait in Notification Centre.
- Sources: [UNNotificationInterruptionLevel.timeSensitive](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/timesensitive), [UNNotificationSettings.timeSensitiveSetting](https://developer.apple.com/documentation/usernotifications/unnotificationsettings/timesensitivesetting), [UNNotificationSetting](https://developer.apple.com/documentation/usernotifications/unnotificationsetting), [Managing notifications (HIG)](https://developer.apple.com/design/human-interface-guidelines/managing-notifications), [INFocusStatusCenter](https://developer.apple.com/documentation/intents/infocusstatuscenter), [INFocusStatus](https://developer.apple.com/documentation/intents/infocusstatus), [Handling Communication Notifications and Focus Status Updates](https://developer.apple.com/documentation/usernotifications/handling-communication-notifications-and-focus-status-updates), [WWDC21 session 10091](https://developer.apple.com/videos/play/wwdc2021/10091/). Apple's entitlement reference has no page for the time-sensitive key (the address where it would be answers "not found", and the index does not list it). The WWDC session only says to "enable the associated capability"; the key name is the one developers report in their entitlements files on Apple's forums ([thread 691183](https://developer.apple.com/forums/thread/691183)), and macOS refusing to launch the copy that claimed it shows the system knows the key as a restricted one.

**Built in M2, the leftovers (2026-10-09): transient failures and Retry (FR-N6).**

- Detection. A waiting session whose text matches a pattern is marked as one that can be retried (`InboxRow.isRetryable`). The text looked at is the job file's `needs` (when it is free text) and its one-line `detail`, both from the fields Appendix B already documents.
- The patterns are settings, not code: `transientErrors.patterns` in `settings.json`, a list of regular expressions matched without regard to case. Missing means the built-in defaults; an entry that is not text is dropped; an expression that does not compile is skipped and the others still apply; an empty list turns detection off. They are read when the app starts, so a hand edit needs a restart. `porchlight settings` does not print them yet.
- The defaults cover the four known failures with the messages Claude Code's error reference lists (read 2026-10-09): rate limits ("Server is temporarily limiting requests", "Request rejected (429)"), usage limits that reset by themselves ("You've hit your session limit", weekly, per-model; "usage limit reached"), the machine sleeping ("Your computer went to sleep mid-response"), and the API being unavailable or overloaded ("API Error: 500 …", "Repeated 529 Overloaded", "Unable to connect to API", "Connection lost before a response was produced"). Each names a whole message, never a bare word, so a question that mentions a rate limit does not match. Spend limits and budgets are left out on purpose: someone has to raise them.
- A session that asked a question or wants a tool approved is never marked, whatever its words: only a plain wait counts.
- In the inbox such a row says "Can be retried" and has a Retry button. Retry opens the session in the terminal (`claude attach <id>`, as Open does) and puts a line to send on the clipboard, `continue` by default (`transientErrors.resend`). The user pastes it and presses Return. Nothing is sent or restarted by Porchlight; why is in §11, S2. If the terminal could not be driven and the command itself went to the clipboard, the line is not copied over it and the notice says to send it by hand.
- Retry is judged again when pressed, from the session as it then is: it does nothing for a session that is not waiting on such a failure.
- Not observed: a real session stopped on one of these failures. Which of `needs` and `detail` carries the message in the job file, and whether it carries the wording of the error reference at all, is not known; the fixtures hold no such session, and none of the user's sessions was touched to find out. If the text turns out to be different, the patterns are a setting and the defaults can follow.

**FR-N7** Optional push to phone via a user-configured webhook (ntfy/Pushover/Slack-compatible URL template) at a configurable ladder step. Off by default. **[PROPOSED for v1.1]**

### 6.3 Launcher (global hotkey palette) — v1 **[PROPOSED]**

**FR-L1** Global hotkey (user-configurable, default unset → prompt in onboarding) opens a floating palette.

**FR-L2** Step 1 — pick a directory by fuzzy search over the **Repo index** (§6.5). Ranking: pinned, then frecency (recent dispatches + directories of existing sessions), then alphabetical. Also allow "Browse…" for any folder, and paste of a path.

**FR-L3** Step 2 — prompt text (multi-line; ⌘↩ to dispatch). Optional fields, collapsed by default: name, model, effort, agent, permission mode, worktree (`-w`) (only flags the installed CLI supports — detect from `claude --help`). Note that `acceptEdits` does not cover shell commands such as `git commit`; such a session still stops on a permission prompt.

**FR-L4** Dispatch = run `claude --bg [-n <name>] [--model …] [--effort …] [--agent …] "<prompt>"` with the working directory set to the chosen folder (never via shell string interpolation; pass argv directly). Capture the printed short id (strip ANSI colour codes first: the CLI colours it even when stdout is not a terminal); show a toast "Started <name> (<id>)" with **Open** action.

**FR-L5** Option "Dispatch and open" opens the terminal on `claude attach <id>` immediately.

**FR-L6** Remember the last 20 dispatches (dir, name, model) for frecency and "repeat last".

Acceptance: from any app, hotkey → type 3 letters of a repo → Enter → type prompt → ⌘↩ starts a session in that repo; it appears in agent view and in the inbox within 3 s.

**Built in M3 layer 3 (2026-10-09): dispatch, without the palette.** `Dispatcher`, `DispatchCapabilities`, `DispatchHistory` and `RepoRanking` in the core, `porchlight dispatch` in the tool.

- The command is `claude --bg [--name …] [--model …] [--effort …] [--agent …] [--permission-mode …] [--worktree[=name]] -- <prompt>`, run as an argument array in the chosen folder. The prompt comes after `--`, so a prompt that starts with a dash cannot be read as a flag.
- **Verified against the real CLI (2026-10-09, v2.1.294):** a session started from the palette in the running app (`70f65f2e`, named `new-named-session-porchlight`) ran and finished, so `claude --bg --name … -- <prompt>` is accepted and the name is applied. **Still not verified:** `--worktree=name` as one argument, and `--model`, `--effort`, `--agent` and `--permission-mode` through the palette; those are standard for the option parser the help output comes from, and the stand-in CLI in the tests accepts them.
- Flags are only passed when `claude --help` lists them. Effort levels and permission modes are read from the help text too, and a value it does not list is refused before anything starts. `bypassPermissions` is never offered.
- Failures show the CLI's own words and the command as a line that can be pasted into a terminal. An untrusted folder is recognised and reported with the folder to open.
- The last 20 dispatches are kept in `dispatches.json` (folder, name, model, time; never the prompt).
- Ranking: with nothing typed, pinned, then most used, then by name. Use is one point per dispatch, halved for every week since, plus a quarter point for having sessions at all. With text typed, match quality comes first and use or a pin only decides between matches that are about as good.
- Not built here: the toast with Open (FR-L4) and "repeat last" (FR-L6) belong to the palette.

**Built in M3 layer 4 (2026-10-09): the palette.** `PaletteModel`, `PaletteView` and `PaletteController` in the UI library.

- A floating panel that takes the keyboard without making Porchlight the active app, so closing it returns the user to where they were. It opens from "New session" in the inbox and from `porchlight new`, which signals the running app (so any launcher or shortcut tool can open it too).
- Step 1: type to search the repositories (ranking as in layer 3), arrows to move, Return to choose. Text that is a path to a folder offers that folder. "Browse…" picks any folder; "Add workspace folder…" adds a root and searches it; a row can be pinned; "Same as last time" picks the last folder and model (FR-L6).
- Step 2: the prompt (Return is a new line, ⌘Return starts, ⇧⌘Return starts and opens), the name from the template, editable (FR-NM2), and options collapsed by default. Only options the installed CLI lists are shown. With `acceptEdits` the palette says that shell commands still stop and ask.
- Result: "Started <name>" with the id and Open; the inbox reads the sessions at once, so the new one is there without waiting for a poll. Failure: the CLI's words, "Copy command", and for an untrusted folder "Open Claude Code there", which runs plain `claude` in that folder for the user to answer the trust prompt.
- Design: the card is the system's glass material on macOS 26 and later (a blurred panel before that), with corners, rows and capsule controls sized to sit concentric. The menu-bar panel takes the system's own chrome.
- The repositories are read again each time the palette opens instead of every few minutes in the background (FR-R4): the result is as fresh and costs nothing while the palette is closed.
- Not verified: the panel in the running app (keyboard focus, glass, paste) is for the user to try; the tests cover the model and offscreen drawing.

**Built in M3 layer 5 (2026-10-09): the global shortcut.** `Hotkey` in the core, `GlobalHotkey` in the macOS library, a recorder on the Settings tab.

- Unset by default (FR-L1), and never registered without being asked. While none is set the Settings tab offers "Use ⌃⌥⌘N" as a one-click choice (decided 2026-10-09: a silent default could take a key away from another app; three modifiers and a letter is rarely used elsewhere). Recorded on the Settings tab: click, press the keys; Escape leaves it, Delete or "Remove" clears it. Stored under `hotkey` in `settings.json` with the modifiers by name.
- A shortcut needs Control, Option or Command, or is a function key: a plain key would be taken away from every app.
- Registered with the system's hot-key service (`RegisterEventHotKey`). That needs no Accessibility or Input Monitoring permission, because the app is told only about its own shortcut. If the system refuses a shortcut, usually because another app holds it, it is not saved, the previous one stays, and the inbox says so.
- Pressing it shows the palette, and hides it when it is already showing.
- Not verified: registration and the key press itself, which only exist in the running app. The tests cover the model's decisions with the registration stood in for.

**Built after M3 (2026-10-09): the palette is for existing sessions too.** Asked for by the user once the palette existed: it is the keyboard way into everything, and the menu-bar panel stays the glanceable view for the mouse.

- With nothing typed the list is the sessions that need the user, then up to three that are working, then the repositories. Finished sessions appear only when typed for. Typing filters sessions (by name and place) and repositories together; a path is always a folder.
- Return on a session opens it in the terminal. On a selected session: ⌘Return copies its suggested reply and opens it, ⌥Return snoozes it for an hour (or turns reminders back on), ⌘R retries one stopped on a passing failure. Each is shown in the bottom bar only when it applies, and is a button as well.
- Opening a session hands the keyboard to the terminal. When the terminal was already the front app, asking macOS to activate it does nothing and the terminal never learns it has the keyboard back (seen with Warp), so Porchlight becomes the active app for a moment first. The activity log records who had focus at each step.

**Built as M4 (2026-10-09): stop and remove.** `SessionControl` in the core, `porchlight stop <id>` and `porchlight rm <id>` in the tool, a menu on each row and ⌘S / ⌘D in the palette.

- `claude stop <id>` and `claude rm <id>` are run with nothing but the id. `--discard-unpushed` and `--force-remove-worktree` are never added by Porchlight on its own and cannot be passed through the `porchlight` tool. An id that could be read as a flag is refused before anything runs.
- **Removing anyway (asked for by the user, 2026-10-09).** When `claude rm` refuses and its refusal names the value one of those two flags takes, the refusal offers "Discard and remove…". That asks a second time, showing the refusal in full and saying the work cannot be brought back, and only then runs `claude rm <id>` with exactly the flag and value the CLI printed. If the refusal names no value, nothing is offered and the terminal is the only way on. This follows §10: never automatic, behind a second explicit confirmation that shows what is lost.
- **Knowing what is left behind.** Before a removal, Porchlight looks into the session's Claude worktree with plain `git` (`status --porcelain`, and `log HEAD --not --remotes`) and the question says how many files are uncommitted and how many commits are on no remote. After a removal, if the worktree folder is still on disk, which is what Claude Code does when it has uncommitted changes, the panel says so with the path.
- Both are offered for background sessions only (a session in a terminal of its own is ended there); stop is not offered for a finished one.
- Both ask first, inside the row or in the palette's bottom bar, saying what will happen. Escape, moving the selection or typing drops the question.
- When Claude Code refuses, its text is shown unchanged and stays until dismissed, with Open in terminal next to it: what to discard is for the user to decide there. The sessions are read again straight after a stop or removal.
- **Verified against the real CLI (v2.1.294):** a throwaway session `92163bcc` started in a trusted probe repository was stopped and removed through `porchlight`; `claude stop` printed `stopped 92163bcc` and `claude rm` printed `removed 92163bcc`. The same run showed the real refusal for an untrusted folder, which matched what `DispatchFailure` expects.
- **Verified against the real CLI (v2.1.294, 2026-10-09, in the user's `lantern-probe`):** a throwaway session `ea30abec` was started with `--worktree=porchlight-smoke-force` (which also settles that the real CLI takes `--worktree=name` as one argument), one commit was made in its worktree and not pushed, and `porchlight rm` was refused. The real refusal goes to standard output with exit 1 and reads `kept <id> — its worktree is still at “<path>”`, then the unpushed commits, then `claude rm <id> --discard-unpushed <full commit>@<worktree id>`. Porchlight reads exactly that value out of it; the real text is now a test, and the stand-in prints the same shape. The real `claude stop` also prints a second line, `run 'claude rm <id>' to remove worktree and job state`.
- Two more things the live run showed, both now handled: a stopped session's state is `stopped` (not `done`), for which Stop is no longer offered; and it reports its repository, not its worktree, as `cwd`, so the worktree is taken from the job details (`worktreePath`) when they have it.
- **The forced removal, done by the user from the panel on that throwaway session (2026-10-09):** the first question named the 2 commits on no remote, the refusal appeared in the row with "Discard and remove…", the second question showed the refusal again, and confirming it removed the session and its worktree folder. The activity log reads `remove ea30abec (discarding, confirmed twice): done`.
- **Not verified:** a worktree with only uncommitted changes being kept by a real `claude rm`, and `--force-remove-worktree`, which needs a worktree git could not remove. The CLI reference (quoted by the user, 2026-10-09) confirms the contract: "When the removal is refused over the session's worktree and a second `claude rm` can resolve it, the refusal prints the exact flag and value to pass": `--discard-unpushed <commit>@<worktree-id>` discards a worktree that has unpushed commits along with those commits (Claude Code 2.1.260 or later), and `--force-remove-worktree <worktree-id>` deletes a worktree directory that git or the WorktreeRemove hook could not remove (2.1.268 or later). Both are below Porchlight's minimum version.

**The environment sessions get (2026-10-09).** Reported by the user: sessions started from the palette lacked their tools. Cause, as seen with `ps`: an app started at login has `PATH=/usr/bin:/bin:/usr/sbin:/sbin`; Claude Code's supervisor (`claude daemon run --origin transient --spawned-by …`) runs with the environment of whichever `claude` command started it, and its sessions (kept ready as `bg-spare` processes) inherit that. Porchlight polls `claude agents` from launch, so it is often the one that starts the supervisor.

- **Fix:** at launch, before anything is started, the app asks the login shell for its environment (`$SHELL -l -i -c` printing `env -0` between two markers, five-second limit) and takes it on, so every program it starts inherits it. The shell's own bookkeeping (`SHLVL`, `PWD`, `TERM`, …) is not taken. Skipped when the app was started from a terminal, and with `PORCHLIGHT_KEEP_ENVIRONMENT` set.
- The values are passed on and kept in memory only: never logged, never written.
- **A supervisor that is already running keeps the environment it was started with.** After updating, sessions only get the new environment once the old supervisor has gone: it exits by itself when its last client disconnects, or `claude daemon stop --any --keep-workers` ends it and leaves the sessions running.
- Checked: the real login shell (zsh) asked from a bare environment answered in 0.44 s with the full path. Confirmed by the owner on the machine that had the problem (2026-10-10): after updating and replacing the supervisor, the one Porchlight started had the full path. Not checked: shells other than zsh, and whether `claude --bg` also passes its own caller's environment to the session.

### 6.4 Naming — v1 (at dispatch) **[PROPOSED]**

**FR-NM1** Name template setting, default `{slug}`. Tokens: `{repo}`, `{branch}` (current branch of the chosen dir), `{ticket}` (first match of a user-configured regex against prompt then branch; empty by default — no ticket system assumed), `{slug}` (first 3–4 significant words of the prompt, kebab-case), `{date}`.

**FR-NM2** Name preview is editable before dispatch.

**FR-NM3** **[OPEN]** LLM-generated slug via `claude -p --model <small> "…"` — better names, but adds latency and spends usage. Default off if built.

**FR-NM4** **[v1.1]** Optional installer for a Claude Code hook (`UserPromptSubmit`/`SessionStart` returning `hookSpecificOutput.sessionTitle`) so sessions started *outside* Porchlight also get template names. Must be opt-in, show the exact settings diff, and be removable.

**Built in M3 layer 2 (2026-10-09): the template, without the palette.** `NameTemplate`, `Slug` and `GitBranch` in the core, `porchlight name` in the tool.

- Template and ticket pattern live under `naming` in `settings.json`. A ticket pattern with a capture group yields the group.
- The slug is the first four words of the prompt's first line that are not filler ("the", "please", "can you"), lowercased and joined with hyphens. Letters of any language are kept.
- A token that comes out empty takes the separator after it along, so `{ticket}-{slug}` without a ticket is just the slug. A template that comes out empty falls back to the slug; with no prompt either, the name is empty and Claude Code names the session.
- Names are cut at 60 characters, at a word boundary where there is one. Unknown tokens are left as written so a typo is visible.
- The branch is read from the repository's `HEAD` file (following the `.git` file of a linked worktree), without running git.
- Not built: LLM-generated names (FR-NM3, D8), the naming hook (FR-NM4, v1.1). The editable preview (FR-NM2) comes with the palette.

### 6.5 Repo index — v1

**FR-R1** Settings: list of **workspace roots** (default: none → onboarding asks; suggest `~/` subfolders that contain git repos). Max scan depth (default 3). Exclude globs (default: `node_modules`, `.git`, `.claude/worktrees`, `Library`).

**FR-R2** A directory is a repo if it contains `.git` (dir or file). Do not descend into a repo once found (except optional "include worktrees" toggle).

**FR-R3** Also include every distinct `cwd` seen in `claude agents --json --all`, even outside workspace roots.

**FR-R4** Re-index on launch, on settings change, and every N minutes in the background (cheap, async). Pinned repos survive re-index.

**Built in M3 layer 1 (2026-10-09): the index, without the palette.** `RepoScanner` and `RepoIndex` in the core, `porchlight repos` in the tool.

- Roots, depth (default 3, accepted range 1 to 8), excludes and pins live under `repos` in `settings.json`, read tolerantly like the other settings. Paths are stored with `~`.
- An exclude is a folder name (`node_modules`), a wildcard name (`*.bundle`) or the end of a path (`.claude/worktrees`). Hidden folders are skipped unless they are repositories themselves. Symbolic links are not followed.
- A session's folder joins the list even outside the roots; a Claude worktree counts as its repository. Folders that no longer exist are left out, pinned or not.
- Search: the letters typed must appear in the name in order, and score higher together and at the start of a word. The rest of the path only matches text as typed, because scattered letters match almost any long path.
- Not built: the "include worktrees" toggle (FR-R2), background re-indexing (FR-R4, comes with the app's palette), suggesting roots at first run (M5).

### 6.6 Onboarding & settings — v1

**FR-S1** First run checks: `claude` on PATH (also probe common install locations and a user-set path, since GUI apps don't inherit shell PATH); version ≥ minimum (Appendix A); `claude agents --json` works. Each failure shows a specific fix.

**FR-S2** Asks for: workspace roots, terminal app, global hotkey, notification permission, launch at login.

**FR-S3** Settings stored as a human-readable JSON/plist in `~/Library/Application Support/<app>/`; import/export.

**Built as the first part of M5 (2026-10-09): first run, without an Apple account.**

- The same steps are on the Settings tab under "General" (open at login as a switch, the folders searched for repositories with add and remove, and why reminders cannot be delivered), so hiding the card loses nothing; the card says so. The Settings tab scrolls at 360 points instead of making the whole panel as tall as it is.
- A set-up card at the top of the sessions lists what is outstanding (FR-S1, FR-S2). Problems cannot be hidden: `claude` not found (with the places that were tried), or a version below the minimum (provisionally 2.1.294, with `claude update`). Optional steps each have a button and can be hidden for good: add a workspace folder, open the system's notification settings when reminders cannot be delivered, use the suggested shortcut, open at login.
- Open at login uses the system's login-item service (`SMAppService`) and only from inside the app bundle. A refusal, or the system asking for approval under Login Items, is shown instead of assumed away.
- `porchlight settings export [FILE]` and `porchlight settings import FILE` (FR-S3). An import is checked first: a file that is not a JSON object is refused and nothing changes; unknown keys and odd values are handled as when the app reads its own file.
- Not verified: open at login on a real restart, and whether the system accepts an ad-hoc signed app as a login item at all.
- Still to do in M5, all needing the owner: Developer ID signing and notarisation, the time-sensitive entitlement and the Focus decision that come with it, automatic updates, publishing a release and the cask, making the repository public.

**Built as distribution for v1 (2026-10-09): a source-built Homebrew formula and an Update button.** Decision D10 changes with it: no Apple Developer account is needed for a first release.

- `Formula/porchlight.rb` builds from `main` on the user's machine by calling `scripts/make-app.sh` (with `--disable-sandbox` for SwiftPM, since Homebrew's own sandbox cannot be nested), installs the bundle and links the `porchlight` tool. An app built locally carries no quarantine mark, so macOS never asks for notarisation and the ad-hoc signature is enough. Verified here with Homebrew 7.0.9: installed from a throwaway tap pointing at the branch, the bundle was ad-hoc signed, not quarantined, at a path naming its commit, and `brew test` passed; it was removed again.
- Updates: there is no version number, the commit is the version. The app reads its commit from its own Homebrew path (`…/Cellar/porchlight/HEAD-<sha>/`, after resolving the link the service starts it through), asks `git ls-remote` for `main` once an hour with `GIT_TERMINAL_PROMPT=0`, and offers "Update and restart" on the Settings tab. That runs `brew upgrade --fetch-HEAD` on the fully qualified formula, then restarts through `brew services restart` when the service is loaded, or by opening the new bundle otherwise, from a process in its own session so it survives the app quitting. A copy not installed by Homebrew says updates are off.
- A Homebrew install is started at login by `brew services`, so the app's own "Open at login" switch is hidden there: two mechanisms would start two copies.
- The disk image and cask in `packaging/` are kept for a later signed release. Unsigned, they must not be published: a downloaded app is quarantined and macOS refuses it.
- Not verified: the Update button in a real Homebrew install (it needs the formula on `main`), `brew services start` surviving a logout, whether notification permission survives a rebuild, and the install on a machine other than this one. The repository was made public on 2026-10-09, as a fresh repository holding the rewritten `main`; the earlier private one is kept as `porchlight-archive` with its pull requests. While the repository was private, `brew install` could not fetch it: Homebrew fetches inside a sandbox without the keychain, and does not use `HOMEBREW_GITHUB_API_TOKEN` for git. A stopgap in the formula that put a token into the clone address was tried and removed again on 2026-10-09, when the repository was made public; a source-built formula is only practical for a public repository.

### 6.8 Triage **[IN PROGRESS, asked for by the user 2026-10-09]**

The problem: sessions pile up, many stalled for weeks, and it is not clear which can go. The plan, in layers: pins, then a Triage tab with a verdict per session (safe to remove, needs a decision, stale, keep), then "wrap up" for stale ones (a summary by a small model before removal, on click only).

**Built, layer 1 (2026-10-09): pins.** For sessions that are long-lived on purpose, such as a debugging thread kept across days or one used to manage something continuously.

- A pin is Porchlight's own (`pins.json`); `claude agents --json` reports no pin. Agent view's own pin (Ctrl+T), which keeps a session's process running, is separate and not visible to Porchlight.
- Pinned sessions are the first section of the panel and the first sessions in the palette, whatever their state, including finished ones that would otherwise have dropped out of "Recently done". They appear in no other section.
- A pinned session is never offered for removal: it has to be unpinned first. It can still be stopped.
- A pin can be quiet: its reminders are off and it neither lights the lantern nor counts, because waiting is its normal state. Making a pin quiet withdraws a reminder already on screen.
- From the row's ⋯ menu (Pin, Unpin, Turn its reminders off), ⌘P in the palette, or `porchlight pin <id> [--quiet]` and `porchlight unpin <id>`. `porchlight status --json` reports `pin` as `pinned` or `quiet`.
- Also in this layer: a click on the daily summary notification now opens the palette, which lists what is waiting. Before, it did nothing, because the menu-bar panel cannot be opened from code.

**Built, layer 2 (2026-10-09): verdicts and the Triage tab.** `Triage`, `PullRequestLookup` and `TriageGatherer` in the core, `porchlight triage [--json]` in the tool, a third tab in the panel.

- **Who is listed:** background sessions that are finished, stopped or failed for at least a day, or waiting for at least seven days (`triage.minimumAge`, `triage.staleAfter` in `settings.json`). Never pinned sessions, working ones, or sessions in a terminal of their own.
- **What is gathered:** the session's Claude worktree, read with plain git (uncommitted files, commits on no remote), and the pull request of its branch, looked up with `gh pr list --head <branch> --state all` in the repository. The branch comes from the session's details, else from the worktree's `HEAD`.
- **The verdict, in this order:** work that exists nowhere else (uncommitted or unpushed) *needs a decision*, whatever else is true; so does a worktree that could not be checked. An open pull request means *keep*. A session still waiting is *stale*, and so is one stopped or failed for longer than the stale threshold. Anything else, finished with nothing to lose, is *safe to remove*.
- **A pull request that could not be looked up** (no `gh`, not signed in, not GitHub) is said in the reason and does not block: with a clean worktree nothing local would be lost. It is never reported as "no pull request".
- **Removing the safe ones together** asks once, listing them, then runs plain `claude rm` on each in turn. The verdict is advice: Claude Code checks each again, and what it refuses is listed in its own words and never overridden. A session pinned in the meantime is skipped.
- Each row also has Open, Remove… (the same question and refusal handling as on the Sessions tab, including discard-and-remove) and Pin.
- Not built: other hosts than GitHub, and "its branch is already in the default branch" as a fact of its own (a merged pull request stands in for it).
- Not verified: the tab on screen and on the user's real sessions; the day this was built none of them was old enough to be listed.

**Built, layer 3 (2026-10-09): wrap-up.** `WrapUp`, `SessionSummariser`, `SessionNote` and `NotesArchive` in the core, `porchlight wrap-up <id>` and `porchlight notes [TEXT]` in the tool, "Wrap up…" on every Triage row.

- **The command, and nothing else:** `claude --print --resume <conversation id> --fork-session --no-session-persistence --tools "" --model <model> -- <prompt>`, run in the session's folder. Each flag is there for a reason: the fork means the session itself gets no new turn, nothing saved means no new session appears, and the empty tool list means the summariser can only read and answer. All six are in `claude --help` on 2.1.294.
- **If the installed CLI's help lacks any of those flags, the command is not run.** Without one of them the session could be changed, so there is no weaker fallback.
- **This is not input into a session.** Rule 8 in 12.1 is not involved: the session never receives anything. A copy of its conversation is read once and discarded.
- **Only when asked.** It reads a whole conversation and spends the user's usage, so the row asks first, naming the model, and one summary runs at a time. Nothing is summarised automatically, in bulk, or on a timer.
- **The folder matters:** Claude Code finds a conversation by the folder it ran in. A stopped session reports the repository as its folder, so the worktree named in its details comes first, then the reported folder, then the repository. If the worktree is gone and the conversation is not found, Claude Code's own words are shown.
- **The note** (`notes/<session id>.json` in Porchlight's state folder): the summary, the session's name, repository, folder, branch and pull request, the model, the time, and the conversation id, from which the row offers the command to open it again. Removing a session does not touch its note. Wrapping up again replaces it.
- **The model** is `haiku`, or `wrapUp.model` in `settings.json`; a value that could be read as a flag falls back to the default.
- **Verified against the real CLI (2.1.294, 2026-10-09)** on a throwaway failed worktree session in `lantern-probe` (conversation file 289 KB): a summary in 7.6 seconds with haiku. The conversation was found from the worktree folder named in the session's details, while the list reported the repository. Afterwards the list had the same four sessions and the same row, the conversation file had the same size and modification time, and the number of conversation files on disk was unchanged. The answer came with `**bold**` headings although plain text was asked for, so `WrapUp.tidy` removes them. Not measured: a long conversation against the four-minute limit, and a session whose worktree is gone.
- **Old conversations may be gone.** Claude Code removes transcripts after `cleanupPeriodDays` (30 by default). A session older than that may have nothing to resume; the CLI's words are shown and no note is written. The same limit applies to the command a note offers for opening the conversation again.
- **A second engine: Apple's on-device model (2026-10-09).** `WrapUpEngine`, `ConversationReader`, `OnDeviceModel`, `WrapUpRunner`. `wrapUp.engine` in `settings.json` is `onDevice` (the default) or `claude`; the Settings page has the selector.
  - **How:** `/usr/bin/fm respond --no-stream --instructions <text>` with the digest on standard input, after `fm available` exits 0. `fm` ships with macOS; `PORCHLIGHT_FM` overrides its path. The conversation is never put on a command line.
  - **What it is given:** its window is 8,192 tokens (reported by the framework on macOS 27.0), so `ConversationReader` takes the first request and as much of the end as fits about 9,000 characters. At that size it answered this project's own 650,000-character session accurately in five seconds; at 28,000 characters it invented a fact. A context overflow is retried once with half the text.
  - **This reads Claude Code's conversation files** (`~/.claude/projects/<folder>/<conversation id>.jsonl`), an undocumented format, on the same footing as Appendix B: read-only, tolerant, anything unreadable skipped. Read: what the user and the assistant wrote, a question asked through `AskUserQuestion` (a waiting session was seen to have asked only that way), and the one-line description of a tool call. Not read: commands, tool output, thinking, side conversations, injected notices. The owner agreed to this on 2026-10-09.
  - **Where the model is missing or not ready** the engine in force is Claude, and the question says why before anything is spent; `fm`'s own words are shown, with the hint that Apple's terms are accepted with `sudo fm license`. On the command line a wrap-up without `--on-device` or `--claude` says so and uses Claude; `--on-device` fails instead.
  - **Claude usage is spent only** when the setting is Claude, when this Mac cannot honour the setting (said in the question), or by the question's own button "Read all of it with haiku (uses Claude usage)".
  - **Verified with the real `fm`** on the throwaway session: 2.1 seconds, a correct summary from three turns, the session list and the conversation file unchanged.
  - **Private Cloud Compute** (32,768 tokens, macOS 27) was tried from an unsigned command-line program and refused every request with `ModelManagerError 1046`; the cause is not known. Not used.
  - **Before Apple's terms are accepted** `fm` prints "YOU HAVE NOT AGREED TO THE APPLE FOUNDATION MODELS CLI LEGAL NOTICE & TERMS." and that agreeing applies to every user of the machine, so it needs `sudo fm license` (seen by the owner on macOS 27.0, 2026-10-09). Porchlight recognises the words "not agreed" in either stream, whatever the exit code, and says in its own words which command to run. `fm license --status` is asked first: on a fresh machine it answers "Not agreed. run 'sudo fm license' to review and agree." with blank space around it, and after agreeing "Agreed to license FM1 version 1.0 on …" (both seen on 27.0).
  - Not verified: a Mac without the model, and which stream and exit code `fm` uses for that refusal (only its words were seen).
- **Notes in the palette (2026-10-09).** A mode, not a tab and not rows among the results: starting or opening a session is what the palette is for many times a day, recalling a note is rare, so it costs the ordinary list nothing but one quiet line ("3 notes match ⇥").
  - **Tab** switches between the two with what was typed. The list is one line per note (name, repository, where its session stands, age); the selected note's summary is shown in full under the list, so reading takes the arrow keys only. Nothing typed lists them newest first.
  - **Return does the most that can still be done** (`NoteReach`): open the session if it is still listed; resume the conversation in a terminal, in its folder, if the session was removed and both Claude Code's conversation file and the folder are still there (`claude --resume <id>`, the id validated as a UUID); otherwise copy the summary. The hint names which.
  - ⌘Return copies the summary with its name, repository and branch. ⌘D asks, then deletes the note only. Escape goes back to the list, or closes the palette when it was opened on its notes from the Triage tab's link.
  - Not verified: resuming a removed session's conversation for real (no such session existed), and the keys in the live panel.
- Not built: a Notes view in the menu-bar panel itself (the palette is where the keyboard is).

### 6.9 Mods **[STARTED 2026-10-10]**

Claude Code has an extension interface it calls mods: a plugin whose hooks run inside each session. Its documentation (`code.claude.com/docs/en/plugins/mods/`, read 2026-10-10) says mods are on by default from 2.1.287; the reference bundled with 2.1.295 still calls the interface early access that "moves between releases". So nothing in the app depends on it, and each mod is optional.

What Claude Code documents for programs outside it (same date): `claude agents --json` is "the supported way to read session state from outside", by polling; the files under `~/.claude/jobs/<id>/` "are not a stable interface"; agent view is a research preview; its `Notification` hook types `agent_needs_input` and `agent_completed` fire "only while agent view is open in a terminal". Nothing documented selects a session in a running agent view or switches a terminal to another session, and the mods interface has nothing for agent view; open requests for these exist (anthropics/claude-code #100519, #99964, #94620). So `porchlight tab` stays the way to make one tab follow clicks. On messages between sessions the documentation says a message "never counts as your consent, so it can't answer a pending permission prompt".

**Found by experiment (2026-10-10, haiku, throwaway sessions in `lantern-probe`, 2.1.296):**

- A mod loads in a background session (`claude --bg --plugin-dir …`) and sees its prompt, turns, tool calls and deliveries.
- A `tool.call` hook can answer the question tool in place of its dialog: a session "blocked, input needed" continued when the hook returned the answer. The dialog stays usable; whichever answers first wins.
- `$.prompt.submit` starts a turn in an idle session, recorded with origin `{kind: "plugin", name}`, where a typed prompt is `{kind: "composer"}`.
- A message between sessions arrives as `<cross-session-message from-name="…">` with origin `peer`.
- A message to a session with no process is not delivered: "no live session on this machine has id …", or by name "No agent named '…' is reachable."
- `claude respawn <id>` restarts such a session in about 0.7 s, under the same id, with its conversation, and without starting a turn. The same held for a session that had gone idle by itself 23 hours earlier, not only one stopped with `claude stop`. Attaching restarts a session too.
- Repairing a send after it failed delivers the text but leaves the sending model told it failed. Waking the recipient before the send does not have that flaw.
- Editing a mod's file reloads it in running sessions and resets what its module remembered.

**Built: `mods/wake` (`porchlight-wake`).** One `session.send` hook: look the recipient up in `claude agents --json --all` (about 130 ms); if it is exactly one background session of this machine with no process, and not the sender, run `claude respawn <short id>` and wait up to about three seconds for it to be running; then let the send go on unchanged. Nothing is sent or altered by the mod, nothing is stopped or removed, a session is not restarted twice within twenty seconds, and any failure in the mod lets the send go on. Installed with `/plugin install porchlight-wake --marketplace ksawerykarwacki/porchlight` (`.claude-plugin/marketplace.json` at the repository's root).

- Checked: nine tests under `claude plugin test`; live, a model's own SendMessage to a stopped session by name woke it, the model was told "delivered", and the recipient's reply came back.
- Not checked: installed from the marketplace rather than loaded with `--plugin-dir`; a recipient whose folder or worktree is gone; several stopped recipients at once; whether the hook is cut short when a restart takes long.

**Second round of experiments (2026-10-10, same set-up): what a companion mod could and could not do.**

*A channel between a mod and the app.*

- `$.http.fetch` takes a `socketPath`, so a mod can speak HTTP to a Unix socket. Against a stand-in server on a socket with mode 0600 and a token in a 0600 file: an event reached the server in 1 to 7 ms; a command queued on the server reached the mod within milliseconds through a request held open (20 s, then asked again).
- The mod's timers kept running while its hooks waited and after a failed turn.
- With the server gone the request fails at once (`HooksError: … failed`); the probe asked again every three seconds at no visible cost. Without the token the server answered 403.
- **The app restarting:** with the stand-in server killed for about ten seconds while a request was held, the mod's requests failed, it asked again every three seconds, and it was back as soon as the server was; a command queued afterwards arrived.
- Not tested: a dozen sessions at once.

*Answering a question.*

- A `tool.call` hook on the question tool can return the answer as the tool's result. Worked for one question, two questions in one call, multi-select (answers joined with a comma) and typed text in place of an option (`response`).
- No time limit was met: an answer given 160 seconds after the question was taken. The dialog stays on screen meanwhile and can still be answered there.
- A prompt submitted while a question is open is not delivered until the session is idle, and the call waits until then: code that awaits it stops listening.

*Approving a tool call.* This is the limit of the approach.

- In the session's default background mode a harmless command was not asked about at all (the mode's own decider let it through). With `--permission-mode default` the order is: `tool.check` (verdict `ask`), then `classic.PermissionRequest`, then the dialog.
- A function hook answers a permission request with `{ decision: { behavior: "allow" } }`, not the settings hook's `hookSpecificOutput` wrapper. Given 6 seconds after the request, it ran the command with no dialog answered.
- **Both hooks are given ten seconds.** After that their signal aborts and the engine goes on: an answer at 11, 22 or 30 seconds was ignored and the dialog stood. Holding `tool.check` only delays the dialog by its ten seconds.
- So an approval through those hooks is possible for about ten seconds after the request, and not from a notification clicked minutes later.
- **Refuse and resubmit works for a late approval (third round, 2026-10-10).** The mod's `tool.check` hook refused the command with a reason telling the model to stop and wait; the model ended its turn saying it was waiting. Sixty seconds later the approval arrived, the mod remembered that exact command and submitted "the owner approved this command, run exactly it now"; the model asked again, `tool.check` let it through, and it ran. The costs: one extra model turn, the session shows as finished rather than waiting in between, and the match is on the exact command text.
- Drawing the permission dialog from a mod is not possible: it is not among the components a mod may draw.

*A turn that fails.*

- With the session's proxy pointed at a closed local port (so nothing was sent anywhere), Claude Code retried ten times over three minutes, then the mod saw `classic.StopFailure` with `error: "server_error"` and `turn.complete` with `reason: "error"`. `claude agents` then listed the session as `blocked`.
- The API's own classes: `rate_limit`, `overloaded` and `server_error` "may clear on their own"; `authentication_failed`, `billing_error`, `invalid_request`, `model_not_found` will not.
- After the failure the mod was alive, and a prompt it submitted started a new turn.
- Not tested: a real rate or usage limit, and the laptop sleeping.

**What a full rework would be, if the owner decides on it.** In layers, each usable alone, the app working unchanged without the mod:

1. *The app listens.* A Unix socket in the state folder, a token, a small protocol: events in, commands out. Sessions known through the mod are merged with the list from `claude agents`, which stays the source for sessions that are not running.
2. *A companion mod that only reports:* session start and end, turn start and end, the question asked, the permission asked for, a failure and its class. This replaces reading `state.json` where the mod is present and makes the panel immediate.
3. *Answering questions* from the panel, the palette and notifications: the options as buttons, typed text, several questions. This changes the rule in 12.1.
4. *Retry after a passing failure:* on `rate_limit`, `overloaded` or `server_error`, after a wait the user sets, the mod submits "continue"; anything else is left to the user.
5. *Approvals,* only within what the ten seconds allow, or by the refuse-and-resubmit route if that proves sound.
6. *Inside Claude Code:* a line saying how many other sessions wait, slash commands, a session's own note when it goes idle, names at start.

**Built, layers 1 and 2 (2026-10-10): the app listens, and a mod that only reports.**

- *The app* (`CompanionListener`, `CompanionHub`): a very small HTTP server on a Unix socket, `companion.sock` in the state folder (under `/tmp/porchlight-<uid>/` when that path is too long for a socket), mode 0600 in a folder closed to others. `companion.json` beside it, also 0600, tells the mod where the socket is and holds a secret that is new at every launch; every request must carry it. A second copy of the app that finds the socket answering leaves both alone. `POST /v1/event` takes a report; `GET /v1/next` is held open for a command and has none to give in this version.
- *Reports* are versioned and read leniently; one this build does not understand is answered 422 and changes nothing. They become facts per session. `claude agents` still decides which sessions exist and whether one is waiting: a report supplies what it waits on, in place of the state file. The file is used when there is no report, when the report says nothing is open, or when the file was written more than five seconds after the report (the mod reports as a question is asked and Claude Code writes its file a moment later, so "the newer one wins" would always have picked the file). A report also makes the store read the sessions again at once.
- *The mod* (`mods/companion`, `porchlight-companion`): hooks on session start and end, turn start and end, the question tool, permission requests and failed turns. Each hands back exactly what the hooks beneath it answered, with a catch that does the same; no hook waits for the app. Reports are sent one after another on the side, given up after two seconds, and a missing app is not tried again for five. On a refused secret the file is read again once. What is open is said again every minute, so an app that restarted learns it.
- What a report holds: a question's text and options; for an approval the tool's name and one line (the command, the path or the URL); a turn's one-word reason; a failure's class. Not the prompts, the replies, the user's answers or tool output.
- `porchlight companion` listens in place of the app and prints each report, for checking the mod.
- Checked: unit tests for reports, facts and their merge; the listener over a real socket with `curl`; the mod's twelve tests under `claude plugin test`. Live on 2.1.296, with `porchlight companion` listening and a throwaway session started with the mod's folder: "started", "turn started" and "asks: Apple or pear?" arrived as they happened; after the listener was stopped and started again the open question was reported again within about a minute; stopping the session reported its end.
- Not checked: the app itself listening (only the command-line stand-in, since a second copy of the app may not be started beside the installed one), the panel showing a reported question, the mod installed from the marketplace, a dozen sessions at once, and a permission request reported live.
- Only the call that was waiting ends the wait: another tool finishing beside an open approval does not.
- A session that asked before the app started has only its state file until the mod next speaks (within a minute, for an open question). A reload of the mod forgets what was open; the state file covers that too.

**Where a waiting session stands (2026-10-10).** Seen by the owner: a session that ended its turn with a long report and "I'll start when you say which one." showed in the panel as "which one." and nothing else, because the row drew only the state file's `needs`. The same file holds `output.result`, Claude Code's sentence on what the turn came to, and `detail`, its status line. A row that waits on a question or on free text now shows one of them (the result first) above what it asks, unless it only repeats it; an approval does not, being about one command. The suggested reply's text is drawn under its button, so the choice can be judged before opening the session. `intent` and `providerEnv` are still never read.

**What a waiting session said (2026-10-10, the owner's decision).** The state file turned out to hold no summary at all for a session that had just stopped: only `needs`, which is the tail of the last reply cut mid-sentence ("which one.\", I'll switch it to the status line or drop it."), so the context line above never showed for it. Asked, the owner chose to have the mod send the end of the reply.

- *The mod* (0.3.0): the `turn.complete` event carries `answer`, the assistant's final visible text of the turn. Its last 1,500 characters, begun at a paragraph, a line or a word, go in the turn's report as `said`. A subagent's turn is no longer reported at all (before, its end was taken for the session's).
- *The app:* kept as `CompanionFacts.lastSaid` until the session's next turn starts or it ends; in memory only, never in the log or in an event's printed line. A row that waits on free text shows it in place of `needs`: its last paragraphs that fit 360 characters, with "Show more" for the rest, bold and code drawn as such. The one-line `detail` (palette, notifications) is still Claude Code's.
- This changes what the mod's README promised ("the assistant's replies are not sent"); the README, the guide and `CLAUDE.md` say what is sent now and that it is not kept.
- Checked: unit tests; the mod's tests; live on 2.1.296 with a stand-in app, a session that replied in two paragraphs reported both in its turn's end.
- Not checked: the installed app showing it; a reply that ends in a table or a list, which are drawn as plain lines.

**Built, layer 3 (2026-10-10): answering one question from the panel.** The owner changed rule 8 in 12.1 for this.

- *What can be answered:* a session that is waiting, whose mod said it takes answers (`"can": ["answer"]` and an id for this asking, `q<n>-<time>`), with exactly one question, options, one to be picked, and only when that question is the one the row shows (`Session.answerTarget`). Several questions, a choice of several and typed text stay with the session's dialog; so does everything from a mod older than 0.2.0, whose options stay plain text.
- *In the panel:* the options are buttons, drawn under the row's own button rather than inside it: nested, they showed the row's "Open in your terminal" tooltip. The panel sets its own pointer at every move (`PanelPointer`): the arrow, except over a field that takes text. It opens over another app and otherwise keeps that app's pointer, a text cursor over a terminal; setting a hand from the buttons' own hover was tried first and left the pointer changing between three shapes. A click chooses and sends nothing; a line under them offers "Send “…”" and Cancel. Send judges the session again as it is now, and if the question has gone says so and sends nothing. The log records which option by number, never its text.
- *The command:* `{"v":1,"type":"answer","id":…,"answers":{<question>: <label as the session wrote it>}}`, given to the request the mod holds at `GET /v1/next`. If no request is held it is queued and dropped after 60 seconds, and the panel says "Sent to …. If it does not move on, open it and answer there."
- *The mod* (0.2.0): for such a question it runs the dialog and, beside it, asks the app for an answer for as long as that asking is the open one. An answer is taken only if it is for this asking's id, names this question and one of its options, and nothing else; it is then returned as the question tool's result, as spike two showed a hook may. Anything else is dropped and the mod asks again. The dialog answered first ends the asking.
- *Who can answer:* a program running as the same user could put its own `companion.json` in place and answer a question; such a program can already run `claude attach` and type. The channel adds no way in for another user or over the network.
- Checked: unit tests for what is answerable and the command; the panel's model and the real listener over its socket, including the 60 seconds; the mod's 19 tests. Live on 2.1.296, a throwaway session with the mod and a stand-in for the app on the real protocol: an answer for another id was dropped and the session kept waiting; the right one continued it ("Apple or pear? → pear") and the session replied "pear".
- Not checked: the installed app sending (only the stand-in, as for layers 1 and 2), the buttons under a real pointer, and an answer racing the dialog by milliseconds.
- *In the palette* (the next change): the selected session's row opens up to show its question in full and its options, each with ⌘ and a number for the first nine (a strip under the list was tried first and read as detached from the session). The number, or a click, chooses; the footer then reads "↩ Send “…”" and "esc Cancel". Return sends through the same `InboxModel.answer` as the panel and the palette stays open, saying what came of it. Moving the selection, typing, Tab or asking to stop the session drops the choice. A choice carries the id of the asking it was made for, so it is refused if the session has asked something else since; after an answer the options of that asking are not offered again while the list still shows it. Checked by `PaletteAnswerTests`; the keys themselves under a real keyboard are not.
- Not built: notifications, typed answers, several questions, approvals.

### 6.7 Roadmap after v1

- **v1.1** Phone webhook (FR-N7), naming hook installer (FR-NM4), transient-error retry (once spike resolved).
- **v1.2 Triage view:** for done/blocked sessions, show linked PR state and worktree safety (uncommitted, unpushed, already on default branch) and recommend close / needs decision / keep; bulk `claude rm` with the CLI's own safety checks. (Proven valuable: cleared 64 of 84 rows safely in one pass.) PR providers as plugins (GitHub via `gh`, others optional).
- **v1.3 One-click reply** — only if §11 spike finds a mechanism with *user* authority.
- Later: multiple Macs via Remote Control, Linux tray port.

## 7. UX principles

- Glanceable first: the icon alone should answer "is anything waiting on me?".
- Every destructive action confirms, names what will be lost, and defers to the CLI's own refusal logic.
- Keyboard-first palette; mouse-friendly menu.
- Never steal focus except when the user clicked/pressed something.
- Notification text may contain sensitive content: setting to hide body text on lock screen / in screen sharing.

## 8. Architecture

### 8.1 Components

```
┌──────────────────────────── Porchlight.app ────────────────────────────┐
│  UI: MenuBarExtra (Inbox) · Palette window (Launcher) · Settings     │
│        ▲                         │                                   │
│        │ observes                │ intents                           │
│  ┌─────┴──────────┐   ┌──────────▼─────────┐   ┌──────────────────┐ │
│  │ SessionStore   │◄──│ Dispatcher         │   │ Notifier         │ │
│  │ (state, snooze,│   │ (claude --bg, stop,│   │ (ladder, digest, │ │
│  │  history)      │   │  rm, attach)       │   │  quiet hours)    │ │
│  └─────┬──────────┘   └──────────┬─────────┘   └────────▲─────────┘ │
│        │ merges                  │ runs                 │ events    │
│  ┌─────┴───────────────┐  ┌──────▼─────────┐            │           │
│  │ SessionSources      │  │ CLIRunner      │   SessionStore diff ───┘ │
│  │  • AgentsCLISource  │──│ (process exec, │                          │
│  │    (official)       │  │  timeouts,     │   ┌──────────────────┐  │
│  │  • JobStateSource   │  │  PATH resolve) │   │ TerminalLauncher │  │
│  │    (internal, opt.) │  └────────────────┘   │ adapters         │  │
│  └─────────────────────┘                       └──────────────────┘  │
│  ┌─────────────────────┐  ┌────────────────┐                         │
│  │ RepoIndex           │  │ Settings       │                         │
│  └─────────────────────┘  └────────────────┘                         │
└─────────────────────────────────────────────────────────────────────┘
          │ exec                         │ read-only
     claude CLI ── daemon ── sessions    ~/.claude/jobs/*/state.json
```

**Frontend/backend split [DECIDED 2026-10-08].** Three SwiftPM targets:

- `PorchlightCore` — everything that is not UI. Imports Foundation only (enforced by a test), with platform services behind interfaces, so a Linux frontend can reuse it.
- `porchlight` — a command-line tool over the core that speaks JSON (`porchlight status --json`, later `dispatch`, `snooze`, `watch`). This is the contract any other frontend builds on, in any language.
- `PorchlightApp` — the macOS app. Links the core directly, with no process boundary.

There is deliberately no daemon or socket API. Snoozes and history live in files the core owns, so the app and the tool see the same state. If macOS stops being the only serious target, the core can be rewritten (for example in Rust) behind the tool's JSON interface.

Each unit has one job and a narrow interface:

| Unit | Responsibility | Interface (sketch) | Depends on |
|---|---|---|---|
| CLIRunner | Find `claude`, run it with argv, timeout, capture stdout/stderr/exit | `run(args, cwd, timeout) async -> Result` | Foundation `Process` |
| AgentsCLISource | Poll `claude agents --json --all`, decode tolerantly | `snapshot() async -> [SessionSummary]` | CLIRunner |
| JobStateSource | Optional enrichment from internal job files; feature-flagged; disabled automatically if schema check fails | `enrich([SessionSummary]) -> [Session]` | file system |
| SessionStore | Merge sources, compute derived fields (waitingSince, ladder step), persist snoozes/history, publish diffs | observable model | sources |
| Notifier | Turn store diffs + clock into notifications per ladder/quiet hours/digest | `handle(diff)`, `tick(now)` | UserNotifications |
| Dispatcher | Build and run `--bg`, `stop`, `rm`, capture id | `dispatch(DispatchRequest)` etc. | CLIRunner |
| TerminalLauncher | Open user's terminal running a command | `open(command, cwd)` | per-terminal adapter |
| RepoIndex | Discover repos under roots, frecency ranking | `search(query) -> [Repo]` | file system, store history |
| Settings | Typed settings + persistence | — | — |

### 8.2 Data model (sketch)

```
SessionSummary   // official, from claude agents --json
  id, sessionId, name, cwd, kind, state, status?, startedAt, pid?
Session          // enriched
  summary
  question?        // internal: needs
  detail?          // internal: detail
  suggestedReply?  // internal
  updatedAt?       // internal; else last-seen-state-change time tracked by Porchlight
  worktreePath?, worktreeBranch?, links[]?   // internal
  derived: waitingSince, ladderStep, snoozedUntil, retryable
```

`waitingSince`: prefer internal `updatedAt`; otherwise the first time Porchlight observed `state == blocked` (persisted, so restarts don't reset the clock).

### 8.3 Refresh strategy

- Poll `claude agents --json --all` every 10 s (configurable), backoff to 60 s when nothing is blocked/working. (Built without the "Mac is idle" condition.)
- Additionally watch `~/.claude/jobs/` with FSEvents (if present) and refresh within 1 s of a change (debounced). FSEvents is a trigger only; the CLI remains the source of truth.
- Never run two CLI snapshots concurrently. A read requested during another is not dropped outright: the running read repeats once when it finishes, so a change that lands mid-read is not missed until the next poll.

### 8.4 Terminal launcher adapters **[SPIKE per terminal]**

Goal: open a new tab/window in the user's terminal running `claude attach <id>` (or `claude agents`) in a given cwd.
**Built in M1 (2026-10-08).** The terminal is the one the user names in settings, else one that is running, else the first installed. Every command is wrapped in the user's login shell (`$SHELL -l -i -c 'exec …'`) so it gets their PATH.

| Terminal | Mechanism | Checked |
|---|---|---|
| Warp | Its URI scheme cannot carry a command (`warp://action/new_tab?path=` takes only a folder). A tab config can: Porchlight rewrites one file, `~/.warp/tab_configs/porchlight.toml`, then opens `warp://tab_config/porchlight`. Opens a tab. | Live: ran a command in the given directory; `claude attach` seen running under Warp. |
| WezTerm | `open -na WezTerm.app --args start --cwd <dir> -- <command>` | Live |
| Terminal.app | An executable `.command` file opened with `open -a Terminal`. No AppleScript, so no Automation prompt. | Live |
| Ghostty | `open -na Ghostty.app --args --working-directory=<dir> -e <command>` | **Not checked.** Ghostty 1.2.3 shows "Allow Ghostty to execute …?" on every such launch, a deliberate safeguard with no setting to disable it. The user confirms once per open. |
| iTerm2 | The same executable `.command` file as Terminal, opened with `open -a iTerm`. No AppleScript, so no Automation prompt. Opens a tab in the window in front, or a window when there is none; the tab closes when the command ends. | Live on 3.7.4 (2026-10-09): ran the command at once and without asking, in the folder asked for (iTerm2 itself starts the file in the home folder; the script changes folder). A session open in it is found in the process table: its shell hangs off `iTermServer` in Application Support, and the `login … /Applications/iTerm.app/…/ShellLauncher` line above it names the app. A second open then brought iTerm2 forward instead of opening a tab. Not checked: a first launch with iTerm2's own first-run dialogs, and versions before 3.7. |
| Fallback | The command on the clipboard (`pbcopy`), with a message saying so. | Test |

**Opening where the user already is (M1, 2026-10-08).** In order:

1. The session is already attached in a terminal: bring that terminal forward.
2. A `porchlight tab` is running: it swaps its own tab to the session (below).
3. The "use agent view when it is open" setting is on and agent view is open: bring that terminal forward; the user picks the session there.
4. Otherwise attach in a new tab or window.

None of Warp, Ghostty or WezTerm lets another program select a particular tab, so "bring forward" means the application. For Warp this is stated in its URI scheme docs (the scheme does not "target or control an already-open tab or pane"); Warp issue #8929 asks for a `warp://action/focus/tab` link, which is worth wiring in if it ships. The command-palette workaround described there needs Accessibility permission and types into whatever is in front, so it is not used. Practical tip: keeping the `porchlight tab` tab in its own Warp window means bringing Warp forward shows it. Terminal.app and iTerm2 could select a tab through AppleScript; not built.

**`porchlight tab`.** A running agent view cannot be steered from outside: the docs list no command, link, socket or file that selects a row in it, a mod runs inside one session and has nothing that switches sessions, and the `claude-cli://open` deep link only opens a new window. `porchlight tab` is the way round that: the user runs it in a tab instead of `claude agents`; it starts agent view as a child, and on a request from the app (a small file in Porchlight's state folder) stops the child and starts `claude attach <id>` in the same tab. Leaving the session returns to agent view; quitting agent view ends the host. Findings from the spike with the real CLI on a pseudo-terminal:

- Agent view stopped with SIGTERM exits cleanly within a second and restores the terminal.
- `claude attach` stopped with any signal ends at once without tidying up (raw mode, alternate screen), so the host restores the terminal settings and resets the screen itself.
- `Ctrl+Z` in an attached session exits with code 0, which is the host's cue to return to agent view.
- Children must share the host's session and process group: started through Foundation's `Process`, agent view drew nothing and exited. The host uses `posix_spawn` with default signal handling.

Each adapter declares capabilities (new tab, new window, run command, cwd) and the UI adapts.

## 9. Tech stack **[PROPOSED]**

| Option | Pros | Cons |
|---|---|---|
| **Swift 6 + SwiftUI `MenuBarExtra` + AppKit palette (NSPanel)** — recommended | Native look, low memory, UserNotifications with actions, global hotkey, login item, Sparkle updates; the platform the target users are on | macOS-only; Swift learning curve for contributors |
| Tauri (Rust + web UI) | Cross-platform later; web devs can contribute | Menu-bar + notification-action polish is weaker; bigger surface |
| Raycast extension (TS/React) | Fastest to build, palette + menu-bar command for free | Requires Raycast; not a standalone app; distribution through Raycast store |

Recommendation: native Swift. Keep CLI decoding and ladder logic in a pure Swift package (`PorchlightCore`) with no UI imports, so it is unit-testable and portable.

**Build [DECIDED 2026-10-08]: SwiftPM only, no Xcode project.** `scripts/make-app.sh` assembles and ad-hoc signs `Porchlight.app` from `swift build`. Consequences found while building M0 with only the Command Line Tools installed:

- SwiftUI's `@State` cannot be used: on the macOS 27 SDK it is a macro whose compiler plugin ships only with Xcode. `@Observable` works. UI state therefore lives in `@Observable` model objects, which also compiles under Xcode and in CI.
- No asset catalog and no XCTest-based UI snapshot tests. Tests use Swift Testing.
- The app binary and the `porchlight` tool cannot sit in the same folder of the bundle: the default file system is case-insensitive. The tool goes in `Contents/Helpers/`.
- Notarization (M5) needs an Apple Developer account; the machine has no signing identity.

Suggested libraries (verify licenses/maintenance): `KeyboardShortcuts` (global hotkey, sindresorhus), `Sparkle` (updates), `LaunchAtLogin` (or `SMAppService` directly).

## 10. Error handling

| Condition | Behaviour |
|---|---|
| `claude` not found | Inbox shows setup card with detected candidates and a path picker. |
| CLI below minimum version | Banner with version found / required and the update command. |
| `agents --json` non-zero / invalid JSON | Keep last good snapshot, mark stale with timestamp, retry with backoff; log stderr. |
| Unknown fields / states | Ignore unknown fields; map unknown state to `unknown` and show it neutrally. |
| Internal job-state schema mismatch | Disable JobStateSource, show "limited details" note; core features still work. |
| Dispatch fails | Show CLI stderr verbatim in a toast with "Copy command". |
| Dispatch refused: workspace not trusted | `claude --bg` exits 1 with "Workspace not trusted. Run `claude` in <path> once and accept the trust prompt, then retry." Trust is per folder and not inherited from the parent, so this happens for any repo never opened in Claude Code. Offer "Open in terminal to trust" (runs `claude` there); never try to bypass the prompt. |
| Job directory without `state.json`, or with no CLI row | Ignore it. The CLI list is the source of truth; the file watcher is only a trigger. |
| `rm` refused | Show the CLI's refusal text verbatim; offer Open (to resolve in terminal). Never pass `--discard-unpushed` automatically; if offered at all, behind a second explicit confirmation showing the commits. |
| Terminal adapter fails | Fallback to clipboard + activate terminal. |
| Notifications denied | Inbox still works; banner explains how to enable. |

## 11. Spikes (do before committing the related feature)

- **S1 Reply without attaching.** Findings so far: an external process *can* post to a session's inbox socket (`CLAUDE_CODE_MESSAGING_SOCKET`, line-based JSON, optional auth line with `CLAUDE_CODE_MESSAGING_TOKEN`), but Claude treats such input as a **message from another session**, not from the user: it cannot approve permission prompts and is explicitly not user consent. Also socket paths are per session and not exposed by `claude agents --json`. Conclusion so far: not a valid "answer as me" channel. Investigate **Channels** (docs: "push external events into a session") and Remote Control before concluding. Until then, reply = Copy suggested reply + Open.
- **S2 Retry for transient errors. [ANSWERED FROM THE DOCUMENTATION 2026-10-09, v2.1.294; one live question left open]** Does `claude respawn <id>` resume the interrupted turn, or only restart the process? Only the help and the public documentation were read; no session was respawned, stopped, attached or started.
  - *What `respawn` is documented to do.* `claude respawn --help`: "Restart a background session (or all of them) so it picks up the current Claude binary." `claude --help`: "Restart a background session, or all of them with --all, so it runs the current Claude Code version". CLI reference: "Restart a background session, running or stopped, with its conversation intact." Agent view, "Manage sessions from the shell": "The restarted session resumes its saved conversation; when none is on disk, it runs its original prompt again as a new conversation". So it restarts the process and reloads the conversation. Nowhere is it said to send the failed turn again.
  - *What reloading a conversation does.* Sessions, "What a resumed session restores": a tool that was still running "doesn't finish or run again when you resume". Reloading does not redo work.
  - *The one place a response is continued.* Agent view, "Read session state": "A session that was mid-response when the machine slept can come back unresponsive. When you open a session that has stopped responding, the supervisor restarts its process and the session continues the interrupted response from where it left off." That is said of opening a session that stopped responding, not of `respawn`, and the page's v2.1.211 note adds that a restarted `←` or `/background` session "doesn't resume an interrupted response older than about an hour".
  - *What Claude Code itself says to do after these failures.* Error reference: for a response cut off mid-way, including "Your computer went to sleep mid-response", the advice is to reply `continue`; for a failure before any response, send the message again; for a usage limit, wait for the reset shown. A turn that ended on a rate or usage limit is over, not interrupted: there is nothing for a restart to resume, and `respawn` would bring the session back waiting as before.
  - *Conclusion.* `respawn` is not a retry and is not used. Retry = open the session (`claude attach <id>`) with `continue` on the clipboard for the user to send, which is the documented remedy and the fallback this spike named.
  - *Could not be established, left for someone with leave to spend usage on a test session.* (1) What `respawn` really does to a session stopped on a limit; the documentation does not say and it was not tried. (2) Whether Retry could send the line itself: Sessions, "Resume a running background session", documents `claude --resume <session> "prompt"` (v2.1.285 or later), which sends the prompt to the running background session as its next turn and then attaches. Not built, because the same section says the prompt is not sent "while the session waits on your answer to a question", it is not stated that `--resume` accepts the short id that `claude agents` lists, and how a limit-stopped session answers can only be seen live. (3) What such a session's job file says (see §6.2).
  - *Sources.* `claude --help` and `claude respawn --help` (v2.1.294); https://code.claude.com/docs/en/cli-reference ; https://code.claude.com/docs/en/agent-view ; https://code.claude.com/docs/en/sessions ; https://code.claude.com/docs/en/errors (its first 100,000 characters; the page is longer and its network section was not read in full).
- **S3 Terminal adapters** (§8.4), one per terminal.
- **S4 Stability of internal job state** (Appendix B): how often it changed across recent CLI versions; decide whether JobStateSource ships enabled by default.
- **S5 [ANSWERED 2026-10-08, v2.1.294]** `waitingFor` is official but is only a category (`permission prompt`, `input needed`), never the question text, and it is absent on sessions blocked before the field existed. The question text still comes only from internal job state, which strengthens D6.

## 12. Security & privacy

- Local only. No network calls except: update check (Sparkle, user can disable) and the optional user-configured webhook.
- No telemetry.
- Reads `~/.claude/jobs` read-only. Never writes Claude Code's files or settings, except the opt-in hook installer (v1.1), which shows a diff and backs up first.
- Writes one file outside its own folder: `~/.warp/tab_configs/porchlight.toml`, only when a session is opened in Warp (§8.4).
- All CLI calls use argv arrays, never shell strings; prompts are passed as a single argument.
- Not sandboxed (needs to exec the CLI and read `~/.claude`), so: Developer ID signing, hardened runtime, notarization. Document why in the README.
- Notification privacy setting (hide question text).

### 12.1 Staying within Claude Code's terms **[RULES, 2026-10-08]**

Read on 2026-10-08: Claude Code's licence line ("Use is subject to Anthropic's Commercial Terms of Service"), the Commercial and Consumer Terms, and the Claude Code "Legal and compliance" page. This is the project's reading, not legal advice.

1. **Run Claude Code as published.** Use the `claude` the user installed. Never bundle, redistribute, patch or wrap its binary in a way that changes it.
2. **Never touch credentials.** No reading, storing or forwarding of tokens, keys or sign-in state; each user signs in to Claude Code themselves. A test (`noSourceTouchesClaudeCredentials`) guards this.
3. **Use documented interfaces.** Session state comes from `claude agents --json`, which the docs name as the supported way to read it from outside; that is also what makes scripted access permitted. Actions use the documented commands (`attach`, `logs`, `stop`, `rm`, `--bg`, `agents`).
4. **No reverse engineering.** Do not inspect, decompile or search the Claude Code binary. (During research on 2026-10-08 the binary was searched for text strings once; nothing from that is used, and it must not be repeated.) Work from the public docs and from observed behaviour of documented commands.
5. **Internal job files are optional.** `~/.claude/jobs/<id>/state.json` is the user's own local data and the docs only call it "not a stable interface", but it is the least official thing Porchlight relies on. Keep it behind the schema check and keep every feature working without it (D6).
6. **Naming.** Do not use "Claude", "Claude Code" or "Anthropic" in the product, feature or company name or in a logo. Plain-text statements that Porchlight works with Claude Code are fine. Keep the "not affiliated" notice.
7. **No intermediating usage.** Porchlight never pays for, resells or proxies Claude usage.
8. **Porchlight never composes input for a session.** No typing into terminals, no messages into a session as if they were the user. *Amended 2026-10-10, the owner's decision:* one thing may be delivered, through the companion mod's documented hook on the question tool: an option the user chose and then sent in Porchlight, for a question that session asked and that is still open. Nothing is sent on a single click, nothing is sent that is not one of the question's own options, and approvals are not answered. (Until this date the rule read "never send input into a session".)

## 13. Testing

- **Unit (PorchlightCore):** decoding fixtures (current schema, missing fields, unknown states, extra fields), ladder/quiet-hours/digest logic with an injected clock, frecency ranking, name templating, transient-error matching.
- **Contract tests:** a fake `claude` executable (script) that returns fixture JSON and records argv — used in integration tests for Dispatcher/stop/rm/attach flows, including refusal outputs.
- **Live smoke test (opt-in, local):** against a real CLI: dispatch a trivial session in a temp git repo, see it in the snapshot, stop, rm.
- **UI:** snapshot tests for inbox rows (states, long names, missing enrichment); manual checklist for notifications and hotkey.
- **CI:** GitHub Actions on macOS runners: build, unit + contract tests, lint (SwiftLint/swift-format), notarize on tag.

## 14. Open decisions (walk through with the human)

| # | Decision | Recommendation |
|---|---|---|
| D1 | Audience | **[DECIDED]** Open source, for any Claude Code user. Built on a clean machine to avoid bias. |
| D2 | v1 scope | **[DECIDED 2026-10-08]** Inbox + Nagger + Launcher + Naming-at-dispatch + Repo index + Onboarding. Triage and reply later. |
| D3 | Tech stack | **[DECIDED 2026-10-08]** Native Swift/SwiftUI, macOS 14+, built with SwiftPM only (§9), split into core library + JSON command-line tool + app (§8.1). Tauri and a Rust core were considered for cross-platform reach and declined: macOS is the main target. |
| D4 | License | **[DECIDED 2026-10-09, replacing Apache-2.0 of 2026-10-08]** GPL-3.0-or-later. The owner does not want the code turned into someone else's closed or paid product without permission. Note what the GPL does and does not do: it does not forbid selling Porchlight, but anyone who distributes it or a changed version must do so under the GPL with the source, which rules out a closed product. Other terms are the copyright holder's to grant. Changed before the repository was made public and before any outside contribution, so no one else's agreement was needed. |
| D5 | Name | **[DECIDED 2026-10-08]** Porchlight (was "Lantern"). Bundle id `io.github.ksawerykarwacki.porchlight`. |
| D6 | Use internal job state by default | **[PROPOSED]** Yes, behind a schema check + toggle (the question text and suggested reply are the most valuable fields). |
| D7 | Duplicate Claude's own first notification | **[PROPOSED, built as the default 2026-10-08]** No: the ladder starts at 15 min. Adding `0` to the ladder setting turns the immediate reminder on. |
| D8 | LLM-generated names | **[OPEN]** Off by default if built. |
| D9 | Minimum Claude Code version | **[PROPOSED]** Provisionally 2.1.294, the only version verified. TODO: find in the changelog the version that introduced `claude agents --json --all` with `state` and lower the minimum to it. |
| D10 | Distribution | **[DECIDED 2026-10-09 for v1]** A Homebrew formula that builds from source, with an in-app Update button (§6.6). A notarised DMG, a cask and Sparkle only if a Developer ID is obtained later. |

## 15. Milestones (for the implementation plan)

1. **M0 Skeleton:** Swift package `PorchlightCore` + app target; CLIRunner with PATH resolution; fake-`claude` test harness.
2. **M1 Read-only inbox:** AgentsCLISource, SessionStore, menu bar with badge and grouped list, Open via one terminal adapter + clipboard fallback.
3. **M2 Nagger:** notifications with actions, ladder, snooze, quiet hours, digest.
4. **M3 Launcher:** RepoIndex, palette, dispatch with flags, naming template, frecency. **[BUILT 2026-10-09, see §6.3 to §6.5; a first real dispatch from the palette worked on 2026-10-09; the shortcut is still to be tried in the running app]**
5. **M4 Enrichment:** JobStateSource (question, suggested reply, updatedAt) behind schema check; stop/rm with confirmations. **[BUILT 2026-10-09: enrichment in M1; stop and remove below]**
6. **M5 Ship:** onboarding, settings, signing/notarization, cask, README/CONTRIBUTING, CI.

Each milestone ends usable; M1 alone already addresses P1 partially.

---

## Appendix A — Claude Code CLI contract (observed on v2.1.294, re-verified on the same version 2026-10-08)

Commands:

| Command | Behaviour observed / documented |
|---|---|
| `claude --bg [-n <name>] [--model m] [--effort e] [--agent a] "<prompt>"` | Starts a background session in the **current working directory** (no directory flag; set cwd on the child process). Prints `backgrounded · <id> · <name>` followed by hint lines, with ANSI colour codes even when stdout is not a terminal. `-n/--name` sets the display name. Also accepts `--permission-mode` and `-w/--worktree`. Exits 1 with a "Workspace not trusted" message in a folder whose trust prompt was never accepted. |
| `claude agents` | Terminal UI (agent view). |
| `claude agents --json` | Active sessions (interactive and background) as a JSON array; no TTY needed. |
| `claude agents --json --all` | Also includes completed background sessions. |
| `claude agents --cwd <path>` | Filters the list to sessions started under `<path>` (filter only; does not set dispatch dir). |
| `claude attach <id\|name>` | Opens a background session in the current terminal. Part of the name works. |
| `claude logs <id\|name>` | Prints recent terminal output of a background session. |
| `claude stop <id>` (alias `kill`) | Stops a session; conversation kept, re-open with `attach`. |
| `claude rm <id>` | Deletes a session row and its Claude-created worktree when safe. **Refuses** if the worktree has unpushed commits (prints the exact `--discard-unpushed <commit>@<worktree-id>` value); keeps the worktree if it has uncommitted changes. Transcript stays on disk (`claude --resume`). |
| `claude rm <id> --discard-unpushed <commit>@<worktree-id>` | Also discards those commits and uncommitted changes. Destructive. |
| `claude rm <id> --force-remove-worktree <worktree-id>` | Forces worktree directory removal in edge cases. |
| `claude respawn <id> \| --all` | Restarts a background session so it runs the current Claude binary. |

`claude agents --json --all` element (observed):

```json
{
  "id": "a1b2c3d4",
  "cwd": "/Users/<user>/code/<repo>",
  "kind": "background",
  "startedAt": 1786354598503,
  "sessionId": "a1b2c3d4-0000-4000-8000-000000000000",
  "name": "fix flaky settings test",
  "state": "blocked",
  "pid": 12345,
  "status": "idle",
  "waitingFor": "…"
}
```
- Always seen: `id, cwd, kind, startedAt (epoch ms), sessionId, name, state`.
- Sometimes present: `pid`, `status` (`busy`, `idle`, `waiting`), `waitingFor` (`permission prompt`, `input needed`).
- `state` and `status` can disagree: a `blocked` session was observed with `status: busy`. Key off `state` only.
- `cwd` is the worktree path (`<repo>/.claude/worktrees/<name>`) once a session has moved into a worktree.
- `state` values seen: `working`, `blocked`, `done`.

Agent view facts relevant to UX (from docs — re-read docs to verify): `@<repo>` in the dispatch box suggests git repos one level below the launch dir, registered worktrees, and any dir that already has a session. `Ctrl+S` groups by directory and dispatches into the selected group's dir. Idle unattached sessions have their process stopped after ~1 h (row and conversation stay); pinning (`Ctrl+T`) keeps them running.

Notifications (from docs — re-read docs to verify): Claude Code's built-in desktop notifications work in some terminals only (Ghostty, Kitty, iTerm2 at time of writing); others rely on hooks/plugins. The `idle_prompt` notification fires once, ~60 s after a turn ends. Hook events include `Notification` (matchers such as `permission_prompt`, `idle_prompt`, `agent_needs_input`), `Stop`, `UserPromptSubmit`, `SessionStart`; `UserPromptSubmit`/`SessionStart` hooks can set the session title via `hookSpecificOutput.sessionTitle` and receive the current `session_title`.

Cross-session messaging (from docs): per-session Unix socket (`CLAUDE_CODE_MESSAGING_SOCKET`, token `CLAUDE_CODE_MESSAGING_TOKEN`); messages are plain text and treated as coming from another session (no approval authority). See §11 S1.

Docs: https://code.claude.com/docs/en/agent-view · /cross-session-messaging · /hooks · /sessions · /settings-reference

## Appendix B — Internal job state (unofficial, observed v2.1.283 and v2.1.294 — may change without notice)

Path: `~/.claude/jobs/<id>/state.json`. Fields observed:

| Field | Type | Use in Porchlight |
|---|---|---|
| `state` | string | **lags the CLI**: observed as `working` while the session was blocked. Do not use for display. |
| `tempo` | string | `blocked` when the session waits; use this, not `state`, to cross-check the CLI |
| `block.questions[]` | `{question, options[]: {label, description}}` | structured form of a multiple-choice question; the recommended option is marked only by "(Recommended)" in its label |
| `needs` | string | **what the session is waiting on.** Prefix convention: `answer: <question> (<option> · <option>)` for questions, `approve <Tool>: <command>` for permission prompts; older sessions have free text. Fall back to showing the raw string. |
| `detail` | string | one-line status |
| `suggestedReply` | string | **Claude's proposed answer.** Often absent, including while blocked. |
| `output.result` | string | last turn summary |
| `updatedAt`, `createdAt`, `firstTerminalAt` | ISO-8601 string | waiting age |
| `name`, `nameSource` (`auto`/user) | string | naming |
| `intent` | string | original prompt — may contain pasted secrets; **never log** |
| `cwd`, `originCwd`, `worktreePath`, `worktreeBranch` | string | repo display, triage. `cwd` here is the repository root even when the CLI reports the worktree. |
| `children` | array of `{id, href, kind}` (`kind: "pr"`) | linked PRs (triage, v1.2) |
| `tokens` | int | unreliable (stayed at 54 through a whole run); do not display |
| `backend` | `"daemon"` | — |
| others: `tempo, inFlight, linkScanOffset, linkScanPath, template, respawnFlags, providerEnv, sessionId, resumeSessionId, daemonShort, cliVersion` | — | ignore; `providerEnv` may contain environment values — **never display or log** |

Further observations:

- A session keeps the schema of the CLI version that started it (`cliVersion`), so several shapes coexist: `bgIsolation`, `fan` and `interactiveLineage` appear on 2.1.283 files only; `originCwd` and `lastTerminalAt` on 2.1.294 files.
- `children`, `output` and `firstTerminalAt` are `null` rather than absent; `detail` can be an empty string.
- `nameSource` is `user` when the session was started with `-n`; `respawnFlags` records the dispatch flags.
- `needs` keeps its last value after the session moves on, so only read it while the CLI says `blocked`.
- `~/.claude/jobs/<id>/timeline.jsonl` exists but held only the initial `working` line through two stops; it is not a state-change log.
- A job directory can exist with no `state.json` and no CLI row.
- Not yet observed: non-empty `children` (linked PRs), and what `claude rm` prints when it refuses.

Rules: read-only; tolerate missing file/fields; validate a minimal schema (`state` + `name` strings) before enabling enrichment; never log full contents.

## Appendix C — Landscape (why build, 2026-10)

- **Agent view (`claude agents`)** — official, terminal only; solves listing/attach, not out-of-terminal awareness or dispatch from anywhere.
- **AgentBar** (open source) — menu-bar status from transcripts/hooks; no dispatch; "go to session" targets Terminal.app tabs; not notarized.
- **Agent Bar** (paid) — its own Claude Code GUI; bypasses agent view.
- **claude-agent-watcher, so-agentbar** — monitoring only.
- **cmux, Herdr, ccmanager, claude-squad, agent-deck** — terminal multiplexers/orchestrators managing sessions in their own panes; overlap with agent view rather than complement it.
- **Found 2026-10-08 by GitHub search (READMEs read, none installed):** claude-status-bar, Lunavect, CoderBar, vibebuddy (Mac, iPhone and Watch), cc-notifier, ClaudeNotifier, agentoast (tmux), Agent Signal Bar, AgentPet, MioIsland, Agentbox. All are hook-based: they install hooks into Claude Code settings rather than reading `claude agents --json`. CoderBar and vibebuddy let the user approve and answer without the terminal. None mentions re-notifying, snoozing, escalation or quiet hours, and none dispatches `claude --bg` (Agentbox spawns its own headless sessions). Whether they show background sessions at all is untested.
- Gap Porchlight fills: out-of-terminal inbox **with escalation**, plus dispatch-from-anywhere, built on the official background-session system.

## Appendix D — Design evidence (anonymised, one heavy user, 30 days)

105 sessions; 26 repos; peak 4 working / 14 open; 1,454 human-response gaps (median 2.2 min, but 167 over 1 h); 15 blocked sessions median ~3 weeks; 98% auto-named, 13% contained a ticket key; 7% of prompts were the human reporting an external event ("merged", "applied", "logged in, retry"); cleanup pass: 84 rows → 64 safe to delete, 5 needed one action, 5 stale questions, 3 real decisions, 7 active.
