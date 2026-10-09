import { expect, test } from 'claude-code/testing'

import { decide, isRunning, isShortID, parseListing } from './wake'

const SELF = 'aaaaaaaa-0000-4000-8000-000000000000'
const B = 'bbbbbbbb-0000-4000-8000-000000000000'

const rows = (pidOfB: number | null) => [
  { id: 'aaaaaaaa', sessionId: SELF, name: 'sender', kind: 'background', pid: 100 },
  { id: 'bbbbbbbb', sessionId: B, name: 'worker', kind: 'background', pid: pidOfB },
  { id: 'cccccccc', sessionId: 'cccccccc-0000-4000-8000-000000000000', name: 'in a terminal', kind: 'interactive', pid: null },
  { id: 'dddddddd', sessionId: 'dddddddd-0000-4000-8000-000000000000', name: 'twin', kind: 'background', pid: null },
  { id: 'eeeeeeee', sessionId: 'eeeeeeee-0000-4000-8000-000000000000', name: 'twin', kind: 'background', pid: null },
]

test('a stopped background session is woken, by name, short id or conversation id', () => {
  for (const to of ['worker', 'bbbbbbbb', B]) {
    expect(decide(to, rows(null), SELF)).toEqual({ wake: true, id: 'bbbbbbbb', sessionId: B, name: 'worker' })
  }
})

test('nothing is woken that is running, unknown, ambiguous, in a terminal, or the sender', () => {
  expect(decide('worker', rows(4242), SELF)).toEqual({ wake: false, why: 'running' })
  expect(decide('nobody', rows(null), SELF).wake).toBe(false)
  expect(decide('uds:/tmp/cc-socks/1.sock', rows(null), SELF).wake).toBe(false)
  expect(decide('twin', rows(null), SELF)).toEqual({ wake: false, why: '2 sessions answer to that' })
  expect(decide('in a terminal', rows(null), SELF)).toEqual({ wake: false, why: 'not a background session' })
  const stoppedSelf = [{ id: 'aaaaaaaa', sessionId: SELF, name: 'sender', kind: 'background', pid: null }]
  expect(decide('sender', stoppedSelf, SELF)).toEqual({ wake: false, why: 'the sender itself' })
  // A partial name is not a name.
  expect(decide('work', rows(null), SELF).wake).toBe(false)
})

test('only a plain short id can reach the command line', () => {
  expect(isShortID('bbbbbbbb')).toBe(true)
  for (const bad of ['--all', 'bbbbbbbb; rm -rf ~', 'BBBBBBBB', 'bbbbbbb', '', undefined]) expect(isShortID(bad)).toBe(false)
  const odd = [{ id: '--all', sessionId: B, name: 'worker', kind: 'background', pid: null }]
  expect(decide('worker', odd, SELF)).toEqual({ wake: false, why: 'no usable id' })
})

test('a listing that is not what it should be wakes nobody', () => {
  expect(parseListing('daemon unavailable')).toEqual([])
  expect(parseListing('{"sessions":[]}')).toEqual([])
  expect(parseListing('[1, null, {"id":"bbbbbbbb","pid":7}]')).toEqual([{ id: 'bbbbbbbb', pid: 7 }])
  expect(isRunning('bbbbbbbb', rows(4242))).toBe(true)
  expect(isRunning('bbbbbbbb', rows(null))).toBe(false)
  expect(isRunning('zzzzzzzz', rows(4242))).toBe(false)
})

/** What a `process.run` hook answers with: the child's result, as the hook's value. */
const ran = (exitCode: number, stdout: string) => ({ value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })

/** A stand-in machine: the listing, what `claude respawn` does to it, and where messages land. */
const machine = (on: any, start: { pidOfB: number | null; respawnExit?: number }) => {
  const state = { pidOfB: start.pidOfB, calls: [] as string[], delivered: [] as string[], now: 1_000_000 }
  // The clock is the test's: time passes only when the test says so, or while the mod sleeps.
  on('clock.now', () => ({ value: state.now }))
  on('clock.sleep', (_$: any, e: any) => {
    state.now += Number(e.ms ?? 0)
    return { value: undefined }
  })
  on('process.run', async (_$: any, e: any) => {
    state.calls.push(e.argv.join(' '))
    if (e.argv[1] === 'agents') return ran(0, JSON.stringify(rows(state.pidOfB)))
    if (e.argv[1] === 'respawn') {
      const exitCode = start.respawnExit ?? 0
      if (exitCode === 0) state.pidOfB = 4242
      return ran(exitCode, exitCode === 0 ? `respawned ${e.argv[2]}` : '')
    }
    return ran(64, '')
  })
  // What Claude Code does with a send: delivered only to a session that is running then.
  on('session.send', async (_$: any, e: any) => {
    state.calls.push(`send ${e.to}`)
    if (e.to === 'worker' && state.pidOfB) {
      state.delivered.push(e.text)
      return { isDelivered: true }
    }
    return { isDelivered: false, reason: `No agent named '${e.to}' is reachable.` }
  })
  return state
}

test('a message to a stopped session wakes it first and is then delivered the ordinary way', async ($: any, on: any) => {
  const state = machine(on, { pidOfB: null })
  const sent = await $.session.send({ to: 'worker', text: 'are you there?' })
  expect(sent).toEqual({ isDelivered: true })
  expect(state.delivered).toEqual(['are you there?'])
  // Looked, woke, looked again, and only then sent: once, unchanged.
  expect(state.calls).toEqual(['claude agents --json --all', 'claude respawn bbbbbbbb', 'claude agents --json --all', 'send worker'])
})

test('a message to a running session is sent with one look and no restart', async ($: any, on: any) => {
  const state = machine(on, { pidOfB: 4242 })
  expect(await $.session.send({ to: 'worker', text: 'hello' })).toEqual({ isDelivered: true })
  expect(state.calls).toEqual(['claude agents --json --all', 'send worker'])
})

test('a recipient this machine does not list is left to Claude Code', async ($: any, on: any) => {
  const state = machine(on, { pidOfB: null })
  const sent = await $.session.send({ to: 'someone-else', text: 'hello' })
  expect(sent.isDelivered).toBe(false)
  expect(state.calls).toEqual(['claude agents --json --all', 'send someone-else'])
})

test('a restart that fails does not hold the message back or get repeated', async ($: any, on: any) => {
  const state = machine(on, { pidOfB: null, respawnExit: 1 })
  const first = await $.session.send({ to: 'worker', text: 'one' })
  expect(first.isDelivered).toBe(false)
  expect(state.calls).toEqual(['claude agents --json --all', 'claude respawn bbbbbbbb', 'send worker'])
  // Straight afterwards the same session is not restarted again; the message still goes out.
  await $.session.send({ to: 'worker', text: 'two' })
  expect(state.calls.filter(call => call.startsWith('claude respawn')).length).toBe(1)
  expect(state.calls.filter(call => call.startsWith('send')).length).toBe(2)
})

test('a session is woken again once enough time has passed since the last attempt', async ($: any, on: any) => {
  const state = machine(on, { pidOfB: null, respawnExit: 1 })
  await $.session.send({ to: 'worker', text: 'one' })
  state.now += 5_000
  await $.session.send({ to: 'worker', text: 'two' })
  expect(state.calls.filter(call => call.startsWith('claude respawn')).length).toBe(1)
  state.now += 30_000
  await $.session.send({ to: 'worker', text: 'three' })
  expect(state.calls.filter(call => call.startsWith('claude respawn')).length).toBe(2)
})
