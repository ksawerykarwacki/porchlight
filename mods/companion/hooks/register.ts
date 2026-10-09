import type { Register } from 'claude-code'

import { bodyOf, descriptorOf, detailOf, questionsOf, reportOf, type Open, type Report } from './report'

// Tells the Porchlight app what this session is doing, the moment it happens: it asked something,
// it wants an approval, a turn started or ended, a turn failed.
//
// It only reports. Every hook hands back exactly what the hooks beneath it answered, and no hook
// waits for the app: a report is sent on the side, and a slow, absent or refusing app costs the
// session nothing.

/** How long a report may take before it is given up. */
const SEND_TIMEOUT_MS = 2000
/** After a failed report, how long before the app is tried again. */
const RETRY_AFTER_MS = 5000
/** How often what is open is said again, so an app that restarted learns it. */
const REPEAT_EVERY_MS = 60_000

type App = { socket: string; secret: string }

let session: string | undefined
let app: App | undefined
let open: Open
let quietUntil = 0

const stateDirectory = async ($: any): Promise<string | undefined> => {
  const override = await $.env.get('PORCHLIGHT_STATE_DIR')
  if (override) return override
  const home = await $.env.get('HOME')
  return home ? `${home}/Library/Application Support/Porchlight` : undefined
}

/** Reads where the app is and its secret. Undefined when the app is not there. */
const findApp = async ($: any): Promise<App | undefined> => {
  try {
    const directory = await stateDirectory($)
    if (!directory) return undefined
    const path = `${directory}/companion.json`
    if (!(await $.fs.exists(path))) return undefined
    return descriptorOf(String(await $.fs.read(path)))
  } catch {
    return undefined
  }
}

const post = async ($: any, to: App, body: string): Promise<number> => {
  const sending = $.http.fetch('http://porchlight/v1/event', {
    method: 'POST',
    socketPath: to.socket,
    headers: { 'X-Porchlight-Secret': to.secret, 'Content-Type': 'application/json' },
    body,
  })
  const late = $.clock.sleep(SEND_TIMEOUT_MS).then(() => ({ status: 0 }))
  return Number((await Promise.race([sending, late])).status)
}

/** Reports go out one after another, in the order they happened: "asked" must not overtake "answered". */
let outbox: Promise<void> = Promise.resolve()
const send = ($: any, report: Report): Promise<void> => {
  outbox = outbox.then(() => sendNow($, report))
  return outbox
}

/** Sends one report. Never throws, and never tries a missing app more than once in a while. */
const sendNow = async ($: any, report: Report): Promise<void> => {
  try {
    // Asked for when first needed: a reload of the mod forgets it, and the session goes on.
    session ??= String(await $.session.id())
    const now = Number(await $.clock.now())
    if (now < quietUntil) return
    app ??= await findApp($)
    if (app === undefined) {
      quietUntil = now + RETRY_AFTER_MS
      return
    }
    let status = await post($, app, bodyOf(session, report))
    if (status === 403) {
      // The app was restarted and has a new secret: read it again, once.
      app = await findApp($)
      if (app !== undefined) status = await post($, app, bodyOf(session, report))
    }
    if (status === 0 || status === 403) {
      app = undefined
      quietUntil = now + RETRY_AFTER_MS
    }
  } catch {
    app = undefined
    try {
      quietUntil = Number(await $.clock.now()) + RETRY_AFTER_MS
    } catch {
      // the clock, of all things: nothing more to do
    }
  }
}

/** A hook that fails must not change what the session does: hand on what was, or would be, answered. */
const passOn = ($: any, e: any, next: any) => next(e)

export const register: Register = on => {
  on('session.start', async ($: any, e: any, next: any) => {
    const result = await next(e)
    try {
      open = undefined
      void send($, { kind: 'session.start' })
      $.clock.every(REPEAT_EVERY_MS, () => {
        const again = reportOf(open)
        if (again !== undefined) void send($, again)
      })
    } catch {
      // without an id there is nothing to report under
    }
    return result
  }).catch(passOn)

  on('session.end', ($: any, e: any, next: any) => {
    void send($, { kind: 'session.end' })
    return next(e)
  }).catch(passOn)

  on('turn.start', ($: any, e: any, next: any) => {
    open = undefined
    void send($, { kind: 'turn.start' })
    return next(e)
  }).catch(passOn)

  on('turn.complete', ($: any, e: any, next: any) => {
    open = undefined
    void send($, { kind: 'turn.complete', ...(typeof e?.reason === 'string' ? { reason: e.reason } : {}) })
    return next(e)
  }).catch(passOn)

  on('classic.StopFailure', ($: any, e: any, next: any) => {
    void send($, { kind: 'failure', error: String(e?.error ?? 'unknown') })
    return next(e)
  }).catch(passOn)

  // An approval is being asked for. The answer is the dialog's, as it always was.
  on('classic.PermissionRequest', ($: any, e: any, next: any) => {
    const tool = String(e?.tool_name ?? '')
    // A question is put to the user through the same door; it is reported as a question, below.
    if (tool !== '' && tool !== 'AskUserQuestion') {
      open = { kind: 'permission', tool, detail: detailOf(tool, e?.tool_input) }
      void send($, { kind: 'permission', tool: open.tool, detail: open.detail })
    }
    return next(e)
  }).catch(passOn)

  // Every tool call passes here, so the app can be told when a question was answered or an
  // approval given: the call that was waiting has come back.
  on('tool.call', async ($: any, e: any, next: any) => {
    if (String(e?.tool) === 'AskUserQuestion') {
      const questions = questionsOf(e)
      if (questions.length > 0) {
        open = { kind: 'question', questions }
        void send($, { kind: 'question', questions })
      }
    }
    const result = await next(e)
    if (open !== undefined) {
      open = undefined
      void send($, { kind: 'resumed' })
    }
    return result
  }).catch(passOn)
}
