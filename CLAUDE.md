# Porchlight: guide for coding agents

A macOS menu-bar companion for Claude Code background sessions. Read `spec.md` for what it does and why, and `CONTRIBUTING.md` for the same rules written for people. This file is the short version an agent needs before touching the code.

## Commands

```sh
swift build                 # everything
swift test                  # two test targets; both must report "passed"
./scripts/make-app.sh       # dist/Porchlight.app, ad-hoc signed
swift run porchlight help   # the command-line tool
```

Ask the owner before anything that changes their machine or accounts: restarting their running app, `brew install` or `brew services`, starting a real Claude Code session (it spends their usage), merging, tagging, releasing.

## Toolchain: Command Line Tools only, no Xcode

- **No `@State` and no `#Preview`.** On current SDKs they are macros whose compiler plugin ships only with Xcode. State lives in `@Observable` classes created once in the `App` initialiser, or in plain values passed in. `@Environment` works.
- Swift Testing needs a compiler flag without Xcode; `Package.swift` adds it. If "plugin for module 'TestingMacros' not found" still appears, look for another `error:` line first.
- CI runs on a runner with Xcode, where the test output is one combined run instead of two.
- The code uses macOS 26 API behind `#available(macOS 26.0, *)` (the palette's glass). Do not remove the availability checks; the package's minimum is macOS 14.

## Layout

| Target | Holds | Rule |
|---|---|---|
| `PorchlightCore` | Decoding the CLI's JSON, sessions, reminders, repositories, naming, dispatch, stop and remove, set-up, updates | Imports Foundation only. A test enforces it. |
| `PorchlightMac` | FSEvents, terminals, notifications, hot key, login item, restart | The macOS side of the core's interfaces. |
| `PorchlightUI` | `InboxModel`, `PaletteModel`, `UpdateModel`, the views, the windows | Views take plain values and closures (`InboxActions`), so tests render them without a model. |
| `porchlight` | The command-line tool, JSON for other frontends | |
| `PorchlightApp` | The `MenuBarExtra` app: wiring only | |
| `PorchlightIconTool` | Draws the app icon for `make-app.sh` | |

Every side effect is passed in as a closure or protocol (the `claude` runner, the terminal launcher, the login item, git, Homebrew, the clock), so tests never touch the real CLI, the network or the user's state.

## Fixed values

- Bundle id `io.github.ksawerykarwacki.porchlight`; state in `~/Library/Application Support/Porchlight/` (`settings.json`, `reminders.json`, `dispatches.json`, `activity.log`); `PORCHLIGHT_STATE_DIR` overrides the folder.
- `PORCHLIGHT_CLAUDE` overrides where `claude` is found; `PORCHLIGHT_NO_NOTIFICATIONS` turns delivery off; `PORCHLIGHT_FM` and `PORCHLIGHT_CONVERSATIONS_DIR` point at a stand-in `fm` and a made-up conversations folder.
- The CLI contract Porchlight relies on is Appendix A of `spec.md`: `claude agents --json --all`, `claude --bg … -- <prompt>`, `claude attach`, `claude stop`, `claude rm`. Minimum version 2.1.294 (provisional).
- Homebrew formula `Formula/porchlight.rb`, fully qualified `ksawerykarwacki/porchlight/porchlight`; it calls `scripts/make-app.sh`, so keep the two in step.

## Rules that are not negotiable

- **Run the unmodified `claude` through documented interfaces only.** No reverse engineering, no reading the binary, no undocumented sockets.
- **Never read, store or forward Claude credentials.** A test fails if a source file names where they live.
- **Never send input into a session.** No typing into terminals, no cross-session messages as if they were the user. Replies stay "copy and open". Wrap-up is not an exception: it reads a fork of the conversation with every tool off and nothing saved (`WrapUp.arguments`), and is not run at all if the CLI lacks one of those flags.
- **Nothing spends the user's Claude usage unasked.** A summary runs only after the user's answer to a question that says so, one at a time.
- **Claude Code's own files are read, never written,** and only two kinds: a job's `state.json` and, for an on-device summary the user asked for, a conversation's `.jsonl` (`ConversationReader`). Of a conversation only what was said is taken: no commands, no tool output. Both formats are undocumented, so every reader skips what it cannot read.
- **Nothing that destroys work happens without the user's explicit answer.** `claude rm` is run plain; `--discard-unpushed` and `--force-remove-worktree` are passed only with the value Claude Code printed in its own refusal, after a second confirmation.
- **No attribution lines**: no `Co-Authored-By` trailers, no "Generated with" in pull requests.
- The product's name never contains "Claude".

## Conventions

- Tests use Swift Testing (`@Suite`, `@Test`, `#expect`, `@testable import`). The stand-in CLI is `Tests/PorchlightCoreTests/Fixtures/fake-claude`; it records its folder and arguments and prints what the real CLI was seen to print. When the real CLI's output is observed, update the stand-in and say so in `spec.md`.
- Tests never write the real state folder: pass URLs in, or use a temporary folder.
- Offscreen renders cannot draw AppKit controls or system pickers; views take `drawsMenus` / `drawsFields` and draw text instead. Renders of the same view can differ by one level between the first renders of a process and later ones, and test order is random: compare with a tolerance, never byte for byte.
- The README's pictures are drawn from the app's own views with made-up sessions (`ReadmeImages` in the Mac tests). When a view they show changes, draw them again: `PORCHLIGHT_README_DIR=docs/images swift test --filter ReadmeImages`. The logo is `icon_128x128@2x.png` from `PorchlightIconTool`.
- The README is for someone deciding whether to install; how things work in detail goes in `docs/guide.md`, and what was built when goes in `spec.md`.
- Comments say why, in a line or two, in plain English. Match the code around them.
- Settings are optional fields read one by one (`try?` per field), so one odd value never discards the rest; an explicit `null` means off where "off" is a choice.
- What only exists on a screen (focus, the panel, the palette, notifications) cannot be verified by tests. Say so under "Not checked" in the pull request and ask the owner to try it.
- Pull requests are small and stacked (`gh stack`), with "What changes", "Checked" and "Not checked".
