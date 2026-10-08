# Lantern — a macOS companion for Claude Code background sessions

> **Working name.** "Lantern" is a placeholder (it lights up when a session is waiting on you). Check for name collisions before publishing.
>
> **Status:** design draft, 2026-10-08. Written to be picked up by a fresh Claude Code session on a clean machine. Nothing in here may assume a particular company, repo layout, ticket system or terminal.

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
- **G3** Zero lock-in: sit on top of Claude Code's own background-session system. Agent view in the terminal keeps working side by side; uninstalling Lantern loses nothing.
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
- **Agent view:** the terminal UI `claude agents`. Lantern complements it and must never conflict with it.

## 6. Features

### 6.1 Inbox (menu bar) — v1 **[PROPOSED]**

**FR-I1** Menu-bar icon with badge: number of sessions needing the human. Icon state: idle / something waiting / something waiting longer than the escalation threshold.

**FR-I2** Dropdown lists sessions grouped: **Needs you** (blocked), **Working**, **Recently done** (last N hours, configurable), each sorted by wait time (oldest first in Needs you).

**FR-I3** Each row shows: name, repo (last path component of cwd, or worktree name), age since last activity, and when available the **question it's waiting on** and **Claude's suggested reply** (from internal job state, see Appendix B; omit gracefully if absent).

**FR-I4** Row actions:
- **Open** → opens the user's terminal and runs `claude attach <id>`.
- **Copy suggested reply** (if present) — then Open.
- **Snooze** 1h / until tomorrow 09:00 / until state changes.
- **Stop** (`claude stop <id>`), **Remove** (`claude rm <id>`) — confirm first; surface the CLI's refusal text verbatim if it refuses.
- **Show logs** → `claude logs <id>` in a scrollable popover.

**FR-I5** Footer: "Open agent view" (terminal + `claude agents`), "New session…" (launcher), Settings, Quit.

**FR-I6** Refresh within ≤ 3 s of a state change (see §8.3).

Acceptance: with 3 blocked sessions, badge shows 3; answering one in the terminal drops the badge to 2 within 3 s; no CLI calls block the UI thread.

### 6.2 Nagger (reminders) — v1 **[PROPOSED]**

**FR-N1** macOS notification when a session enters `blocked`, titled with the session name, body = the question if known, else "needs your input". Grouped per session (re-notify replaces, doesn't stack).

**FR-N2** Escalation ladder, configurable. Default: at 0 min (only if Lantern detects it before Claude's own notification would be visible — **[OPEN]** whether to duplicate), 15 min, 2 h, then every 4 h; from 2 h add sound; optional "time-sensitive" interruption level from 4 h.

**FR-N3** Notification actions: **Open**, **Snooze 1h**, **Copy suggested reply**.

**FR-N4** Quiet hours and macOS Focus respected; ladder pauses during quiet hours and resumes after.

**FR-N5** Daily digest at a configurable time (default 09:00): one notification "N sessions waiting, oldest Xd" → opens the inbox.

**FR-N6** Transient-error detection: if the waiting text matches known transient failures (rate limit, usage limit, "went to sleep", API unavailable — patterns in settings, not hardcoded), label the row **Retry-able** and offer a one-click action. **[SPIKE]** which CLI action correctly retries (candidates: `claude respawn <id>`, or attach and resend) — see §11.

**FR-N7** Optional push to phone via a user-configured webhook (ntfy/Pushover/Slack-compatible URL template) at a configurable ladder step. Off by default. **[PROPOSED for v1.1]**

### 6.3 Launcher (global hotkey palette) — v1 **[PROPOSED]**

**FR-L1** Global hotkey (user-configurable, default unset → prompt in onboarding) opens a floating palette.

**FR-L2** Step 1 — pick a directory by fuzzy search over the **Repo index** (§6.5). Ranking: pinned, then frecency (recent dispatches + directories of existing sessions), then alphabetical. Also allow "Browse…" for any folder, and paste of a path.

**FR-L3** Step 2 — prompt text (multi-line; ⌘↩ to dispatch). Optional fields, collapsed by default: name, model, effort, agent, permission mode (only flags the installed CLI supports — detect from `claude --help`).

**FR-L4** Dispatch = run `claude --bg [-n <name>] [--model …] [--effort …] [--agent …] "<prompt>"` with the working directory set to the chosen folder (never via shell string interpolation; pass argv directly). Capture the printed short id; show a toast "Started <name> (<id>)" with **Open** action.

**FR-L5** Option "Dispatch and open" opens the terminal on `claude attach <id>` immediately.

**FR-L6** Remember the last 20 dispatches (dir, name, model) for frecency and "repeat last".

Acceptance: from any app, hotkey → type 3 letters of a repo → Enter → type prompt → ⌘↩ starts a session in that repo; it appears in agent view and in the inbox within 3 s.

### 6.4 Naming — v1 (at dispatch) **[PROPOSED]**

**FR-NM1** Name template setting, default `{slug}`. Tokens: `{repo}`, `{branch}` (current branch of the chosen dir), `{ticket}` (first match of a user-configured regex against prompt then branch; empty by default — no ticket system assumed), `{slug}` (first 3–4 significant words of the prompt, kebab-case), `{date}`.

**FR-NM2** Name preview is editable before dispatch.

**FR-NM3** **[OPEN]** LLM-generated slug via `claude -p --model <small> "…"` — better names, but adds latency and spends usage. Default off if built.

**FR-NM4** **[v1.1]** Optional installer for a Claude Code hook (`UserPromptSubmit`/`SessionStart` returning `hookSpecificOutput.sessionTitle`) so sessions started *outside* Lantern also get template names. Must be opt-in, show the exact settings diff, and be removable.

### 6.5 Repo index — v1

**FR-R1** Settings: list of **workspace roots** (default: none → onboarding asks; suggest `~/` subfolders that contain git repos). Max scan depth (default 3). Exclude globs (default: `node_modules`, `.git`, `.claude/worktrees`, `Library`).

**FR-R2** A directory is a repo if it contains `.git` (dir or file). Do not descend into a repo once found (except optional "include worktrees" toggle).

**FR-R3** Also include every distinct `cwd` seen in `claude agents --json --all`, even outside workspace roots.

**FR-R4** Re-index on launch, on settings change, and every N minutes in the background (cheap, async). Pinned repos survive re-index.

### 6.6 Onboarding & settings — v1

**FR-S1** First run checks: `claude` on PATH (also probe common install locations and a user-set path, since GUI apps don't inherit shell PATH); version ≥ minimum (Appendix A); `claude agents --json` works. Each failure shows a specific fix.

**FR-S2** Asks for: workspace roots, terminal app, global hotkey, notification permission, launch at login.

**FR-S3** Settings stored as a human-readable JSON/plist in `~/Library/Application Support/<app>/`; import/export.

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
┌──────────────────────────── Lantern.app ────────────────────────────┐
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
  updatedAt?       // internal; else last-seen-state-change time tracked by Lantern
  worktreePath?, worktreeBranch?, links[]?   // internal
  derived: waitingSince, ladderStep, snoozedUntil, retryable
```

`waitingSince`: prefer internal `updatedAt`; otherwise the first time Lantern observed `state == blocked` (persisted, so restarts don't reset the clock).

### 8.3 Refresh strategy

- Poll `claude agents --json --all` every 10 s (configurable), backoff to 60 s when nothing is blocked/working and the Mac is idle.
- Additionally watch `~/.claude/jobs/` with FSEvents (if present) and refresh within 1 s of a change (debounced). FSEvents is a trigger only; the CLI remains the source of truth.
- Never run two CLI snapshots concurrently; drop overlapping ticks.

### 8.4 Terminal launcher adapters **[SPIKE per terminal]**

Goal: open a new tab/window in the user's terminal running `claude attach <id>` (or `claude agents`) in a given cwd.
- Terminal.app, iTerm2: AppleScript.
- Ghostty: `open -na Ghostty --args …` or its CLI/AppleScript if available.
- Warp: URL scheme / launch configurations — verify what can run a command.
- Fallback: copy the command to clipboard and bring the terminal to front, with a toast.
Each adapter declares capabilities (new tab, new window, run command, cwd) and the UI adapts.

## 9. Tech stack **[PROPOSED]**

| Option | Pros | Cons |
|---|---|---|
| **Swift 6 + SwiftUI `MenuBarExtra` + AppKit palette (NSPanel)** — recommended | Native look, low memory, UserNotifications with actions, global hotkey, login item, Sparkle updates; the platform the target users are on | macOS-only; Swift learning curve for contributors |
| Tauri (Rust + web UI) | Cross-platform later; web devs can contribute | Menu-bar + notification-action polish is weaker; bigger surface |
| Raycast extension (TS/React) | Fastest to build, palette + menu-bar command for free | Requires Raycast; not a standalone app; distribution through Raycast store |

Recommendation: native Swift. Keep CLI decoding and ladder logic in a pure Swift package (`LanternCore`) with no UI imports, so it is unit-testable and portable.

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
| `rm` refused | Show the CLI's refusal text verbatim; offer Open (to resolve in terminal). Never pass `--discard-unpushed` automatically; if offered at all, behind a second explicit confirmation showing the commits. |
| Terminal adapter fails | Fallback to clipboard + activate terminal. |
| Notifications denied | Inbox still works; banner explains how to enable. |

## 11. Spikes (do before committing the related feature)

- **S1 Reply without attaching.** Findings so far: an external process *can* post to a session's inbox socket (`CLAUDE_CODE_MESSAGING_SOCKET`, line-based JSON, optional auth line with `CLAUDE_CODE_MESSAGING_TOKEN`), but Claude treats such input as a **message from another session**, not from the user: it cannot approve permission prompts and is explicitly not user consent. Also socket paths are per session and not exposed by `claude agents --json`. Conclusion so far: not a valid "answer as me" channel. Investigate **Channels** (docs: "push external events into a session") and Remote Control before concluding. Until then, reply = Copy suggested reply + Open.
- **S2 Retry for transient errors.** Determine whether `claude respawn <id>` resumes the interrupted turn or only restarts the process; otherwise "Retry" = Open + prefill.
- **S3 Terminal adapters** (§8.4), one per terminal.
- **S4 Stability of internal job state** (Appendix B): how often it changed across recent CLI versions; decide whether JobStateSource ships enabled by default.
- **S5** Does `claude agents --json` expose the waiting question officially in the installed version (a `waitingFor` field was observed intermittently)? If yes, prefer it over internal state.

## 12. Security & privacy

- Local only. No network calls except: update check (Sparkle, user can disable) and the optional user-configured webhook.
- No telemetry.
- Reads `~/.claude/jobs` read-only. Never writes Claude Code's files or settings, except the opt-in hook installer (v1.1), which shows a diff and backs up first.
- All CLI calls use argv arrays, never shell strings; prompts are passed as a single argument.
- Not sandboxed (needs to exec the CLI and read `~/.claude`), so: Developer ID signing, hardened runtime, notarization. Document why in the README.
- Notification privacy setting (hide question text).

## 13. Testing

- **Unit (LanternCore):** decoding fixtures (current schema, missing fields, unknown states, extra fields), ladder/quiet-hours/digest logic with an injected clock, frecency ranking, name templating, transient-error matching.
- **Contract tests:** a fake `claude` executable (script) that returns fixture JSON and records argv — used in integration tests for Dispatcher/stop/rm/attach flows, including refusal outputs.
- **Live smoke test (opt-in, local):** against a real CLI: dispatch a trivial session in a temp git repo, see it in the snapshot, stop, rm.
- **UI:** snapshot tests for inbox rows (states, long names, missing enrichment); manual checklist for notifications and hotkey.
- **CI:** GitHub Actions on macOS runners: build, unit + contract tests, lint (SwiftLint/swift-format), notarize on tag.

## 14. Open decisions (walk through with the human)

| # | Decision | Recommendation |
|---|---|---|
| D1 | Audience | **[DECIDED]** Open source, for any Claude Code user. Built on a clean machine to avoid bias. |
| D2 | v1 scope | **[PROPOSED]** Inbox + Nagger + Launcher + Naming-at-dispatch + Repo index + Onboarding. Triage and reply later. |
| D3 | Tech stack | **[PROPOSED]** Native Swift/SwiftUI, macOS 14+. |
| D4 | License | **[OPEN]** MIT vs Apache-2.0 (Apache gives a patent grant). |
| D5 | Name | **[OPEN]** "Lantern" placeholder; check collisions. |
| D6 | Use internal job state by default | **[PROPOSED]** Yes, behind a schema check + toggle (the question text and suggested reply are the most valuable fields). |
| D7 | Duplicate Claude's own first notification | **[OPEN]** Probably no (start ladder at 15 min), to avoid double alerts; make configurable. |
| D8 | LLM-generated names | **[OPEN]** Off by default if built. |
| D9 | Minimum Claude Code version | **[PROPOSED]** The version that introduced `claude agents --json --all` with `state`; confirm in changelog. |
| D10 | Distribution | **[PROPOSED]** GitHub releases (notarized DMG) + Homebrew cask + Sparkle. |

## 15. Milestones (for the implementation plan)

1. **M0 Skeleton:** Swift package `LanternCore` + app target; CLIRunner with PATH resolution; fake-`claude` test harness.
2. **M1 Read-only inbox:** AgentsCLISource, SessionStore, menu bar with badge and grouped list, Open via one terminal adapter + clipboard fallback.
3. **M2 Nagger:** notifications with actions, ladder, snooze, quiet hours, digest.
4. **M3 Launcher:** RepoIndex, palette, dispatch with flags, naming template, frecency.
5. **M4 Enrichment:** JobStateSource (question, suggested reply, updatedAt) behind schema check; stop/rm with confirmations.
6. **M5 Ship:** onboarding, settings, signing/notarization, cask, README/CONTRIBUTING, CI.

Each milestone ends usable; M1 alone already addresses P1 partially.

---

## Appendix A — Claude Code CLI contract (observed on v2.1.294, 2026-10-08 — re-verify)

Commands:

| Command | Behaviour observed / documented |
|---|---|
| `claude --bg [-n <name>] [--model m] [--effort e] [--agent a] "<prompt>"` | Starts a background session in the **current working directory** (no directory flag; set cwd on the child process). Prints the short id. `-n/--name` sets the display name. |
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
- Sometimes present: `pid`, `status` (`busy`, `idle`, `waiting`), `waitingFor`.
- `state` values seen: `working`, `blocked`, `done`.

Agent view facts relevant to UX (from docs — re-read docs to verify): `@<repo>` in the dispatch box suggests git repos one level below the launch dir, registered worktrees, and any dir that already has a session. `Ctrl+S` groups by directory and dispatches into the selected group's dir. Idle unattached sessions have their process stopped after ~1 h (row and conversation stay); pinning (`Ctrl+T`) keeps them running.

Notifications (from docs — re-read docs to verify): Claude Code's built-in desktop notifications work in some terminals only (Ghostty, Kitty, iTerm2 at time of writing); others rely on hooks/plugins. The `idle_prompt` notification fires once, ~60 s after a turn ends. Hook events include `Notification` (matchers such as `permission_prompt`, `idle_prompt`, `agent_needs_input`), `Stop`, `UserPromptSubmit`, `SessionStart`; `UserPromptSubmit`/`SessionStart` hooks can set the session title via `hookSpecificOutput.sessionTitle` and receive the current `session_title`.

Cross-session messaging (from docs): per-session Unix socket (`CLAUDE_CODE_MESSAGING_SOCKET`, token `CLAUDE_CODE_MESSAGING_TOKEN`); messages are plain text and treated as coming from another session (no approval authority). See §11 S1.

Docs: https://code.claude.com/docs/en/agent-view · /cross-session-messaging · /hooks · /sessions · /settings-reference

## Appendix B — Internal job state (unofficial, observed v2.1.294 — may change without notice)

Path: `~/.claude/jobs/<id>/state.json`. Fields observed:

| Field | Type | Use in Lantern |
|---|---|---|
| `state` | string | cross-check with CLI |
| `needs` | string | **the question the session is waiting on** |
| `detail` | string | one-line status |
| `suggestedReply` | string | **Claude's proposed answer** |
| `output.result` | string | last turn summary |
| `updatedAt`, `createdAt`, `firstTerminalAt` | ISO-8601 string | waiting age |
| `name`, `nameSource` (`auto`/user) | string | naming |
| `intent` | string | original prompt — may contain pasted secrets; **never log** |
| `cwd`, `originCwd`, `worktreePath`, `worktreeBranch` | string | repo display, triage |
| `children` | array of `{id, href, kind}` (`kind: "pr"`) | linked PRs (triage, v1.2) |
| `tokens` | int | optional display |
| `backend` | `"daemon"` | — |
| others: `tempo, inFlight, linkScanOffset, linkScanPath, template, respawnFlags, providerEnv, sessionId, resumeSessionId, daemonShort, cliVersion` | — | ignore; `providerEnv` may contain environment values — **never display or log** |

Rules: read-only; tolerate missing file/fields; validate a minimal schema (`state` + `name` strings) before enabling enrichment; never log full contents.

## Appendix C — Landscape (why build, 2026-10)

- **Agent view (`claude agents`)** — official, terminal only; solves listing/attach, not out-of-terminal awareness or dispatch from anywhere.
- **AgentBar** (open source) — menu-bar status from transcripts/hooks; no dispatch; "go to session" targets Terminal.app tabs; not notarized.
- **Agent Bar** (paid) — its own Claude Code GUI; bypasses agent view.
- **claude-agent-watcher, so-agentbar** — monitoring only.
- **cmux, Herdr, ccmanager, claude-squad, agent-deck** — terminal multiplexers/orchestrators managing sessions in their own panes; overlap with agent view rather than complement it.
- Gap Lantern fills: out-of-terminal inbox **with escalation**, plus dispatch-from-anywhere, built on the official background-session system.

## Appendix D — Design evidence (anonymised, one heavy user, 30 days)

105 sessions; 26 repos; peak 4 working / 14 open; 1,454 human-response gaps (median 2.2 min, but 167 over 1 h); 15 blocked sessions median ~3 weeks; 98% auto-named, 13% contained a ticket key; 7% of prompts were the human reporting an external event ("merged", "applied", "logged in, retry"); cleanup pass: 84 rows → 64 safe to delete, 5 needed one action, 5 stale questions, 3 real decisions, 7 active.
