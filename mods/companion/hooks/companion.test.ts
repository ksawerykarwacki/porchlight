import { expect, test } from 'claude-code/testing'

import { bodyOf, descriptorOf, detailOf, questionsOf, reportOf, TEXT_LIMIT } from './report'

const SESSION = '22222222-0000-4000-8000-000000000000'
const DESCRIPTOR = JSON.stringify({ v: 1, socket: '/Users/u/Library/Application Support/Porchlight/companion.sock', secret: 'abc123' })

const fruit = {
  question: 'Apple or pear?',
  header: 'Fruit',
  multiSelect: false,
  options: [
    { label: 'apple', description: 'An apple' },
    { label: 'pear', description: '' },
  ],
}

test('only the text and the options of a question are taken', () => {
  expect(questionsOf({ questions: [fruit] })).toEqual([{ question: 'Apple or pear?', options: [{ label: 'apple', description: 'An apple' }, { label: 'pear' }] }])
  expect(questionsOf({ questions: ['nonsense', 7, { question: 'Still here?' }] })).toEqual([{ question: 'Still here?', options: [] }])
  expect(questionsOf({})).toEqual([])
  expect(questionsOf(undefined)).toEqual([])
  expect(questionsOf({ questions: [{ question: 'x'.repeat(5000), options: [] }] })[0].question.length).toBe(TEXT_LIMIT)
})

test('an approval is described by what it would run or touch', () => {
  expect(detailOf('Bash', { command: 'make deploy', description: 'Deploy' })).toBe('make deploy')
  expect(detailOf('Edit', { file_path: '/repo/a.swift', old_string: 'secret text' })).toBe('/repo/a.swift')
  expect(detailOf('WebFetch', { url: 'https://example.com' })).toBe('https://example.com')
  expect(detailOf('Other', { a: 1 })).toBe('{"a":1}')
  expect(detailOf('Other', undefined)).toBe('Other')
  expect(detailOf('Bash', { command: 'x'.repeat(5000) }).length).toBe(TEXT_LIMIT)
})

test('a report carries its version and session, and what is open can be said again', () => {
  expect(JSON.parse(bodyOf(SESSION, { kind: 'turn.complete', reason: 'answer' }))).toEqual({ v: 1, session: SESSION, kind: 'turn.complete', reason: 'answer' })
  expect(reportOf(undefined)).toBe(undefined)
  expect(reportOf({ kind: 'permission', tool: 'Bash', detail: 'make' })).toEqual({ kind: 'permission', tool: 'Bash', detail: 'make' })
  expect(reportOf({ kind: 'question', questions: [] })).toEqual({ kind: 'question', questions: [] })
})

test('the app is found only through a well-formed file', () => {
  expect(descriptorOf(DESCRIPTOR)).toEqual({ socket: '/Users/u/Library/Application Support/Porchlight/companion.sock', secret: 'abc123' })
  for (const bad of ['', 'not json', '{}', '{"v":2,"socket":"/a","secret":"s"}', '{"v":1,"socket":"relative.sock","secret":"s"}', '{"v":1,"socket":"/a","secret":""}', '[]']) {
    expect(descriptorOf(bad)).toBe(undefined)
  }
})

/** A stand-in machine for the mod: its files, its clock, and an app that answers as told. */
const machine = (on: any, start: { descriptor?: string; status?: number | 'hang' | 'throw' } = {}) => {
  const state = { now: 1_000_000, posts: [] as any[], descriptor: start.descriptor as string | undefined, status: start.status ?? 204, reads: 0 }
  if (!('descriptor' in start)) state.descriptor = DESCRIPTOR
  on('session.id', () => ({ value: SESSION }))
  on('env.get', (_$: any, e: any) => ({ value: e.name === 'HOME' ? '/Users/u' : undefined }))
  on('fs.exists', (_$: any, e: any) => ({ value: state.descriptor !== undefined && String(e.path).endsWith('/Library/Application Support/Porchlight/companion.json') }))
  on('fs.read', () => {
    state.reads += 1
    return { value: state.descriptor ?? '' }
  })
  on('clock.now', () => ({ value: state.now }))
  on('clock.sleep', () => new Promise(() => {}))
  on('http.fetch', (_$: any, e: any) => {
    state.posts.push({ url: e.url, socketPath: e.init?.socketPath, secret: e.init?.headers?.['X-Porchlight-Secret'], body: JSON.parse(e.init?.body ?? '{}') })
    if (state.status === 'hang') return new Promise(() => {})
    if (state.status === 'throw') throw new Error('connection refused')
    return { value: { status: state.status, ok: state.status < 300, headers: {}, text: '' } }
  })
  return state
}

/** Lets the reports that were sent on the side be sent. */
const settle = (_$?: unknown) => new Promise<void>(resolve => setTimeout(resolve, 40))

test('a question is reported when asked and again when answered, and its answer is untouched', async ($: any, on: any) => {
  const state = machine(on)
  const answered = { result: { questions: [fruit], answers: { 'Apple or pear?': 'pear' } } }
  on('tool.call', () => answered)
  const result = await $.tool.call({ tool: 'AskUserQuestion', questions: [fruit] })
  await settle($)
  expect(result.result).toEqual(answered.result)
  expect(state.posts.map(post => post.body.kind)).toEqual(['question', 'resumed'])
  expect(state.posts[0].body).toEqual({ v: 1, session: SESSION, kind: 'question', questions: [{ question: 'Apple or pear?', options: [{ label: 'apple', description: 'An apple' }, { label: 'pear' }] }] })
  // Over the app's socket, with its secret, and nowhere else.
  expect(state.posts[0].url).toBe('http://porchlight/v1/event')
  expect(state.posts[0].socketPath).toBe('/Users/u/Library/Application Support/Porchlight/companion.sock')
  expect(state.posts[0].secret).toBe('abc123')
})

test('an ordinary tool call is passed through and reported not at all', async ($: any, on: any) => {
  const state = machine(on)
  on('tool.call', () => ({ result: { stdout: 'ok' } }))
  const result = await $.tool.call({ tool: 'Bash', command: 'ls' })
  await settle($)
  expect(result.result).toEqual({ stdout: 'ok' })
  expect(state.posts).toEqual([])
})

test('with no app the session is not held up and the app is not asked for again at once', async ($: any, on: any) => {
  const state = machine(on, { descriptor: undefined })
  on('tool.call', () => ({ result: { questions: [fruit], answers: {} } }))
  await $.tool.call({ tool: 'AskUserQuestion', questions: [fruit] })
  await settle($)
  expect(state.posts).toEqual([])
  // Asked again a moment later: still nothing sent, and the file is not even looked for.
  state.descriptor = DESCRIPTOR
  await $.tool.call({ tool: 'AskUserQuestion', questions: [fruit] })
  await settle($)
  expect(state.posts).toEqual([])
  // After the pause the app is found and told.
  state.now += 6_000
  await $.tool.call({ tool: 'AskUserQuestion', questions: [fruit] })
  await settle($)
  expect(state.posts.map(post => post.body.kind)).toEqual(['question', 'resumed'])
})

for (const status of ['hang', 'throw'] as const) {
  test(`an app that ${status === 'hang' ? 'never answers' : 'refuses the connection'} costs the session nothing`, async ($: any, on: any) => {
    const state = machine(on, { status })
    on('tool.call', () => ({ result: { questions: [fruit], answers: { 'Apple or pear?': 'apple' } } }))
    const result = await $.tool.call({ tool: 'AskUserQuestion', questions: [fruit] })
    // The answer is back before the report has even been given up.
    expect(result.result.answers).toEqual({ 'Apple or pear?': 'apple' })
    await settle($)
    expect(state.posts.length).toBe(1)
  })
}

test('a refused secret is read again once, for an app that was restarted', async ($: any, on: any) => {
  const state = machine(on, { status: 403 })
  on('tool.call', () => ({ result: { questions: [fruit], answers: {} } }))
  await $.tool.call({ tool: 'AskUserQuestion', questions: [fruit] })
  await settle($)
  // The first report: sent, refused, the file read again, sent once more, refused, then quiet.
  expect(state.posts.map(post => post.body.kind)).toEqual(['question', 'question'])
  expect(state.reads).toBe(2)
})

test('an approval being asked for is reported and its answer left to the dialog', async ($: any, on: any) => {
  const state = machine(on)
  const below = { decision: { behavior: 'allow' } }
  on('classic.PermissionRequest', () => below)
  const result = await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'make deploy', description: 'Deploy' } })
  await settle($)
  expect(result).toEqual(below)
  expect(state.posts.map(post => post.body)).toEqual([{ v: 1, session: SESSION, kind: 'permission', tool: 'Bash', detail: 'make deploy' }])
  // A question passes the same door and is not reported as an approval.
  await $.classic.PermissionRequest({ tool_name: 'AskUserQuestion', tool_input: { questions: [fruit] } })
  await settle($)
  expect(state.posts.length).toBe(1)
})

test('a failed turn is reported with its class', async ($: any, on: any) => {
  const state = machine(on)
  on('classic.StopFailure', () => ({}))
  await $.classic.StopFailure({ error: 'rate_limit' })
  await settle($)
  expect(state.posts.map(post => post.body)).toEqual([{ v: 1, session: SESSION, kind: 'failure', error: 'rate_limit' }])
})
