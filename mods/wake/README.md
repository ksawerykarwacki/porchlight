# porchlight-wake

A small Claude Code mod. When one session sends a message to another and the recipient is a
background session that is no longer running, the message normally fails:

> No agent named 'worker' is reachable.

With this mod installed, the recipient is restarted first and the message is delivered. The
sending session is told it was delivered, and the recipient answers as usual.

## Install

In a Claude Code session in a terminal:

```
/plugin install porchlight-wake --marketplace ksawerykarwacki/porchlight
```

Answer `y` to add the marketplace and choose the user scope. It is active in that session at once
and in every session started afterwards. It needs Claude Code 2.1.295 or later and does not need
the Porchlight app.

To remove it: `/plugin uninstall porchlight-wake`.

## What it does, exactly

Before a message leaves a session, the mod:

1. runs `claude agents --json --all` to see who the recipient is (about a tenth of a second);
2. if the recipient is a background session of this Mac with no running process, runs
   `claude respawn <id>` and waits up to about three seconds for it to be running;
3. lets the message go out unchanged, the ordinary way.

A restarted session keeps its id and its conversation. Restarting alone uses no Claude usage; the
session only starts working when the message reaches it.

## What it does not do

- It sends nothing itself and changes no message.
- It never stops or removes a session, and wakes one only as the recipient of a message.
- It leaves alone anything it is not sure about: a recipient that is running, one this Mac does
  not list, a name two sessions share, a session in a terminal of its own, and the sender itself.
  Claude Code then answers as it always did.
- The same session is not restarted more than once in twenty seconds.
- If anything in the mod fails, the message is still sent.

## Good to know

- **It is built on a new interface.** Mods are on by default since Claude Code 2.1.287, but the
  reference that ships with Claude Code still says the interface "moves between releases". An
  update may break this mod; if it does, messages simply behave as they did without it.
- **A woken session stays running** until it goes idle by itself again.
- **A session whose folder or worktree is gone** may not restart; the message then fails as before.

## Working on it

```sh
claude plugin validate mods/wake     # reads it the way Claude Code will
claude plugin test mods/wake         # runs hooks/wake.test.ts against the engine
claude --plugin-dir mods/wake        # a session with it loaded from this folder
```

The decisions are plain functions in `hooks/wake.ts`; `hooks/register.ts` is the one hook.
