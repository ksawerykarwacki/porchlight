# porchlight-companion

A small Claude Code mod that tells the [Porchlight](../../README.md) app what a session is doing,
the moment it happens: it asked you something, it wants an approval, a turn started, finished or
failed.

Without it Porchlight finds these things out by asking Claude Code every few seconds and reading a
file Claude Code calls "not a stable interface". With it, the panel shows a session's question as
soon as it is asked.

It also lets you answer from Porchlight. When a session asks one question with options to pick one
of, the panel shows the options as buttons: click one, then **Send**, and the mod hands that option
to the session as the question's answer. In the palette it is ⌘1 to ⌘9, then Return. The session's own dialog stays up the whole time; whichever
is answered first counts.

**The mod never chooses.** It passes on only an option you clicked and sent in Porchlight, only for
the question that is open, and only if it is one of that question's own options. It approves
nothing and types nothing. Questions with several parts, a choice of several, or a typed answer are
shown in the panel and answered in the session as before. Every other hook hands back exactly what
Claude Code would have done without it.

## Install

You need the Porchlight app running. Then, in a Claude Code session in a terminal:

```
/plugin install porchlight-companion --marketplace ksawerykarwacki/porchlight
```

Answer `y` to add the marketplace and choose the user scope. It is active in that session at once
and in every session started afterwards. Porchlight's Settings tab says how many sessions report.

To remove it: `/plugin uninstall porchlight-companion`. Porchlight goes back to asking.

## What it sends, and where

Only to the Porchlight app on the same Mac, over a private socket in Porchlight's own folder that
only your user can open. Nothing goes over the network.

| When | What is sent |
|---|---|
| A session starts or ends | That it did |
| A turn starts or finishes | That it did, and Claude Code's one-word reason (answer, error, …) |
| The session asks you a question | The question's text and its options' labels and descriptions |
| The session wants an approval | The tool's name, and one line: the command for a shell, the path for a file tool |
| A question is answered or an approval given | That the session is working again; not what you answered |
| A turn fails | Claude Code's class for the failure (`rate_limit`, `overloaded`, …) |

Not sent: your prompts, the assistant's replies, your answers, file contents, tool output.

The app sends the mod one thing only: the option you chose and sent for an open question, with that
question's text and the id the mod gave that asking. While such a question is open the mod keeps
one request to the app waiting for it.

Every report carries a secret the app writes into a file only you can read, new each time the app
starts. Without the app running there is nothing to send to, and the mod does nothing.

## What it does when things go wrong

- **No app, or the app is slow:** the report is dropped after two seconds and the app is not tried
  again for five. The session never waits for a report.
- **The app was restarted:** the mod reads the new secret and carries on. If a question is open, it
  says so again within a minute.
- **An answer arrives for a question that is no longer the open one,** or names something that is
  not one of its options: it is dropped. One the mod never came for is thrown away by the app
  after a minute.
- **You answered in the session first:** that answer counts, and the mod stops waiting for the app.
- **An older Porchlight:** nothing is ever sent back, and the mod only reports.
- **Anything in the mod fails:** the session continues exactly as it would without it.

## Working on it

```sh
claude plugin validate mods/companion     # every hook it marks "gating" must have a .catch
claude plugin test mods/companion         # hooks/companion.test.ts, against the engine
porchlight companion                      # listen in place of the app and print what arrives
claude --plugin-dir mods/companion        # a session with it loaded from this folder
```

What goes in a report is decided by plain functions in `hooks/report.ts`; `hooks/register.ts` is
the hooks and the sending.
