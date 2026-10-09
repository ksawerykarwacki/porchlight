# Contributing to Porchlight

Porchlight is a macOS menu-bar companion for Claude Code background sessions. The design, and the
reasons behind most decisions, are in [`spec.md`](spec.md). This page is what you need to build it,
test it, and send a change.

## Build and test

You need macOS 14 or later and a Swift 6 toolchain. The Command Line Tools are enough
(`xcode-select --install`); Xcode is not required, and there is no Xcode project. The package has
no dependencies, so nothing is downloaded.

```sh
swift build              # everything, debug
swift test               # all tests; uses a stand-in claude, never the real one
./scripts/make-app.sh    # dist/Porchlight.app, ad-hoc signed, for local use
open dist/Porchlight.app
```

`swift run porchlight doctor` checks that your own `claude` can be found. You do not need Claude
Code installed to build or to run the tests.

CI (`.github/workflows/ci.yml`) runs the same three commands on a macOS runner for every pull
request. It uses Xcode's toolchain, so a change has to build both ways: with the Command Line Tools
alone and with Xcode.

### No `@State`

Building with the Command Line Tools alone has one consequence you will meet in the first hour:
SwiftUI's `@State` cannot be used. On the current SDK it is a macro whose compiler plugin ships only
with Xcode, so code that uses it builds in Xcode and fails for everyone without it. Keep view state
in an `@Observable` model object and pass that to the view; `InboxModel` in `PorchlightUI` is the
pattern to copy. The same goes for anything else that needs an Xcode-only plugin, and for asset
catalogs: the app icon is drawn in code by `PorchlightIconTool`.

`Package.swift` names the Swift Testing macro plugin explicitly when Xcode is absent. Leave that in
place; without it the test targets fail to build intermittently on a machine with only the Command
Line Tools.

## Where code goes

| Target | What belongs there |
|---|---|
| `PorchlightCore` | Everything that is not UI or macOS-specific: decoding what `claude` prints, the session store, reminders, naming, the repository index. It imports Foundation only. |
| `PorchlightMac` | macOS implementations of the core's interfaces: file watching, notifications, terminal launching, the global shortcut. |
| `PorchlightUI` | SwiftUI views and their `@Observable` models, kept apart from the app so tests can render them. |
| `porchlight` | The command-line tool. Its JSON output is the contract for other frontends. |
| `PorchlightApp` | The menu-bar app: a thin shell over `PorchlightUI`. |
| `PorchlightIconTool` | Draws the app icon at build time for `make-app.sh`. |

`PorchlightCore` importing Foundation only is a rule, and a test enforces it:
`coreImportsNoUIOrAppleOnlyFrameworks` fails if any file in the core has an `import` line other than
`import Foundation`. If your change needs AppKit, SwiftUI or another Apple framework, define a
protocol in the core and implement it in `PorchlightMac`.

In the app bundle the command-line tool lives in `Contents/Helpers/`, not next to the app's binary:
the default file system ignores case, so `porchlight` and `Porchlight` cannot share a folder.

## Tests

- **Swift Testing, not XCTest.** `import Testing`, `@Suite`, `@Test`, `#expect`, `#require`.
- **The real `claude` is never run.** Tests that need the CLI use the stand-in at
  `Tests/PorchlightCoreTests/Fixtures/fake-claude`, a shell script that replays the fixtures beside
  it and records the working directory and arguments it was called with. `FAKE_CLAUDE_MODE` selects
  a failure to replay (`untrusted`, `broken-json`, `fail`, `hang`, and others listed at the top of
  the script). When Claude Code's output changes, update the fixtures from what the documented
  commands print; do not make a test call the real program.
- **Tests never write the real state folder.** Porchlight keeps its settings and state in
  `~/Library/Application Support/Porchlight`. A test that touches state uses a scratch folder: pass
  one to the type under test, or set `PORCHLIGHT_STATE_DIR`, which overrides the location. A test
  that changes your own settings or snoozes is a bug.
- **Inject the clock.** Reminder, quiet-hours and digest logic take the time as a parameter. Do not
  sleep in a test, and do not read the wall clock in code that a test has to pin down.
- **Views are rendered offscreen** (`ImageRenderer`) and checked from the test, so nothing appears
  on your screen. Set `PORCHLIGHT_SNAPSHOT_DIR=/tmp/shots` to keep the images and look at them.
- **Tests that drive real terminals are opt-in** (`PORCHLIGHT_LIVE_TERMINALS=warp,ghostty`) and do
  not run by default or in CI.

A change in behaviour comes with a test that fails without it.

## Staying within Claude Code's terms

Porchlight is an independent project that works with a program it does not own. These rules are
from [`spec.md` §12.1](spec.md); they are the project's reading of Anthropic's terms, not legal
advice, and a pull request that breaks one will not be merged.

1. **Run the unmodified `claude`.** Porchlight runs the `claude` the user installed. It never
   bundles, redistributes, patches or wraps the binary in a way that changes it.
2. **Never touch credentials.** No reading, storing or forwarding of Claude tokens, keys or sign-in
   state, for any reason. Users sign in to Claude Code themselves. The test
   `noSourceTouchesClaudeCredentials` fails if a source file starts naming the places credentials
   live.
3. **Use documented interfaces.** Session state comes from `claude agents --json`; actions go
   through the documented commands (`--bg`, `attach`, `logs`, `stop`, `rm`, `agents`). Arguments are
   passed as an array, never through a shell string.
4. **No reverse engineering.** Do not inspect, decompile or search the Claude Code binary. Work from
   the public documentation and from what documented commands do.
5. **The job files are optional.** `~/.claude/jobs/<id>/state.json` is read-only input that Claude
   Code's documentation calls "not a stable interface". Every feature has to keep working without
   it.
6. **Naming.** No "Claude", "Claude Code" or "Anthropic" in a product or feature name or in a logo.
   Saying in plain text that Porchlight works with Claude Code is fine.
7. **No intermediating usage.** Porchlight never pays for, resells or proxies Claude usage.

Porchlight is also local only. It has no telemetry and makes no network calls today; `spec.md` §12
lists the only two it may ever make (an update check and a webhook the user sets up).

## Pull requests

- **Keep them small.** One change per pull request, on a branch from `main`. A reviewer should be
  able to read it in one sitting. Split a large piece of work into steps that each leave `main`
  working.
- **Describe it in three parts:** "What changes", "Checked" (what you ran or tried, and what you
  saw), and "Not checked". The last one matters most: say plainly what you did not verify, for
  example a terminal you do not have, a macOS version you could not try, or behaviour that only
  shows in a signed build. An honest "Not checked" list is welcome; a missing one is not.
- **`swift test` passes** on your machine before you open it, and CI passes after.
- **Update `spec.md`** when a change settles or alters a decision recorded there, and the README
  when it changes what a user sees or types.
- **Comments say why**, not what. Match the style of the code around your change.

Releases are made by the repository owner; the steps are in
[`packaging/README.md`](packaging/README.md).

## Licence

Porchlight is licensed under the [Apache License 2.0](LICENSE). By contributing you agree that your
contribution is licensed under the same terms (section 5 of the licence).
