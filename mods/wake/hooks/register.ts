import type { Register } from 'claude-code'

import { decide, isRunning, parseListing } from './wake'

// A message to a background session that is not running fails: "no live session on this machine
// has id …". This wakes the recipient first, with the documented `claude respawn`, so the message
// that follows is delivered the ordinary way and the sender is told so.
//
// It does nothing else: it sends nothing itself, changes no message, and never stops or removes
// a session. A restarted session does not start working until a message reaches it.

/** How long to wait for a restarted session to be running before sending anyway. */
const SETTLE_TRIES = 8
const SETTLE_PAUSE_MS = 400
/** A session just woken is not woken again within this time, whatever the listing says. */
const AGAIN_AFTER_MS = 20_000

const woken = new Map<string, number>()

const listing = async ($: any) => parseListing(String((await $.process.run(['claude', 'agents', '--json', '--all'])).stdout ?? ''))

export const register: Register = on => {
  on('session.send', async ($: any, e: any, next: any) => {
    // Checked before the send, not after: a failed send has already been reported to the sender.
    try {
      const self = await $.session.id().catch(() => undefined)
      const decision = decide(String(e.to), await listing($), self)
      if (decision.wake) {
        const now = Number(await $.clock.now())
        const last = woken.get(decision.id)
        if (last === undefined || now - last > AGAIN_AFTER_MS) {
          woken.set(decision.id, now)
          const ran = await $.process.run(['claude', 'respawn', decision.id])
          if (ran.exitCode === 0) {
            for (let attempt = 0; attempt < SETTLE_TRIES; attempt++) {
              if (isRunning(decision.id, await listing($))) break
              await $.clock.sleep(SETTLE_PAUSE_MS, { signal: next.signal })
            }
            $.ui.status(`woke ${decision.name ?? decision.id} to deliver a message`)
          }
        }
      }
    } catch {
      // Whatever went wrong here, the message is still sent; Claude Code says how that went.
    }
    return next(e)
  })
}
