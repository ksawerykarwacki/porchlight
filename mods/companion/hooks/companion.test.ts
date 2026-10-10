import { expect, test } from 'claude-code/testing'

import { answerOf, bodyOf, descriptorOf, detailOf, isNewApp, mayClear, questionsOf, replyOf, reportOf, retryOf, SAID_LIMIT, tailOf, takesAnswer, TEXT_LIMIT } from './report'

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

type Ask = 'hold' | ((question: any) => { status: number; text: string })

/**
 * A stand-in machine for the mod: its files, its clock, and an app that answers as told.
 * `posts` are the reports; `asks` counts the requests for an answer, each answered by `ask`:
 * held open for ever, as the app does while the user has not picked, or answered from the
 * question last reported.
 */
const machine = (on: any, start: { descriptor?: string; status?: number | 'hang' | 'throw'; ask?: Ask[] } = {}) => {
  const state = {
    now: 1_000_000, posts: [] as any[], asks: 0, descriptor: start.descriptor as string | undefined, status: start.status ?? 204, reads: 0,
    ask: start.ask ?? (['hold'] as Ask[]),
  }
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
    if (String(e.url).includes('/v1/next')) {
      const ask = state.ask[Math.min(state.asks, state.ask.length - 1)]
      state.asks += 1
      if (ask === 'hold') return new Promise(() => {})
      // The request may be made before the report of the question or the failure has landed;
      // the app only has something to say once it knows of it.
      return new Promise(resolve => {
        const answer = () => {
          const question = [...state.posts].reverse().find(post => post.body.kind === 'question' || post.body.kind === 'failure' || (post.body.kind === 'turn.complete' && post.body.id))?.body
          if (question === undefined) return void setTimeout(answer, 5)
          resolve({ value: { ...ask(question), ok: true, headers: {} } })
        }
        answer()
      })
    }
    state.posts.push({ url: e.url, socketPath: e.init?.socketPath, secret: e.init?.headers?.['X-Porchlight-Secret'], body: JSON.parse(e.init?.body ?? '{}') })
    if (state.status === 'hang') return new Promise(() => {})
    if (state.status === 'throw') throw new Error('connection refused')
    return { value: { status: state.status, ok: state.status < 300, headers: {}, text: '' } }
  })
  return state
}

/** The dialog, answered by the person after a moment. */
const dialogAfter = (ms: number, answers: Record<string, string>) => () =>
  new Promise(resolve => setTimeout(() => resolve({ result: { questions: [fruit], answers } }), ms))

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
  // One question with options to pick one of: the mod says it will take an answer, and names this asking.
  const { id, ...reported } = state.posts[0].body
  expect(reported).toEqual({ v: 1, session: SESSION, kind: 'question', can: ['answer'], questions: [{ question: 'Apple or pear?', options: [{ label: 'apple', description: 'An apple' }, { label: 'pear' }] }] })
  expect(/^q\d+-\d+$/.test(id)).toBe(true)
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
  expect(state.asks).toBe(0)
  // Asked again a moment later: still nothing is reported.
  await $.tool.call({ tool: 'AskUserQuestion', questions: [fruit] })
  await settle($)
  expect(state.posts).toEqual([])
  state.descriptor = DESCRIPTOR
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
  // Once at first, once on being refused; the asking for an answer looks for the app as well.
  expect(state.reads >= 2 && state.reads <= 3).toBe(true)
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

test('a tool finishing beside an open approval does not end the wait; the approved one does', async ($: any, on: any) => {
  const state = machine(on)
  on('classic.PermissionRequest', () => ({}))
  on('tool.call', () => ({ result: { ok: true } }))
  await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'make deploy' } })
  await $.tool.call({ tool: 'Read', file_path: 'a.md' })
  await settle($)
  expect(state.posts.map(post => post.body.kind)).toEqual(['permission'])
  await $.tool.call({ tool: 'Bash', command: 'make deploy' })
  await settle($)
  expect(state.posts.map(post => post.body.kind)).toEqual(['permission', 'resumed'])
})

test('a failed turn is reported with its class, its own id, and whether trying again can help', async ($: any, on: any) => {
  const state = machine(on)
  on('classic.StopFailure', () => ({}))
  await $.classic.StopFailure({ error: 'rate_limit' })
  await settle($)
  await $.classic.StopFailure({ error: 'billing_error' })
  await settle($)
  const [first, second] = state.posts.map(post => post.body)
  expect({ ...first, id: '' }).toEqual({ v: 1, session: SESSION, kind: 'failure', error: 'rate_limit', id: '', can: ['retry'] })
  expect(/^f\d+-\d+$/.test(first.id)).toBe(true)
  // A failure that needs a person takes no retry, and the app is not asked for one.
  expect({ ...second, id: '' }).toEqual({ v: 1, session: SESSION, kind: 'failure', error: 'billing_error', id: '' })
  expect(second.id).not.toBe(first.id)
})

test('what the app may answer is one question with options of which one is picked', () => {
  const one = questionsOf({ questions: [fruit] })
  expect(takesAnswer(one)).toBe(true)
  expect(takesAnswer(questionsOf({ questions: [fruit, fruit] }))).toBe(false)
  expect(takesAnswer(questionsOf({ questions: [{ ...fruit, multiSelect: true }] }))).toBe(false)
  expect(takesAnswer(questionsOf({ questions: [{ question: 'Say more?', options: [] }] }))).toBe(false)
  expect(takesAnswer([])).toBe(false)

  const command = (fields: object) => JSON.stringify({ v: 1, type: 'answer', id: 'q1-5', answers: { 'Apple or pear?': 'pear' }, ...fields })
  expect(answerOf(command({}), 'q1-5', one)).toEqual({ 'Apple or pear?': 'pear' })
  // For another asking, another question, no option of this one, or not an answer at all: nothing.
  expect(answerOf(command({}), 'q2-9', one)).toBe(undefined)
  expect(answerOf(command({ answers: { 'Tea or coffee?': 'pear' } }), 'q1-5', one)).toBe(undefined)
  expect(answerOf(command({ answers: { 'Apple or pear?': 'plum' } }), 'q1-5', one)).toBe(undefined)
  expect(answerOf(command({ answers: { 'Apple or pear?': 'apple', extra: 'x' } }), 'q1-5', one)).toBe(undefined)
  expect(answerOf(command({ answers: { 'Apple or pear?': 7 } }), 'q1-5', one)).toBe(undefined)
  expect(answerOf(command({ answers: ['pear'] }), 'q1-5', one)).toBe(undefined)
  expect(answerOf(command({ type: 'submit' }), 'q1-5', one)).toBe(undefined)
  expect(answerOf(command({ v: 2 }), 'q1-5', one)).toBe(undefined)
  expect(answerOf('not json', 'q1-5', one)).toBe(undefined)
  // Never for a question the app was not offered.
  expect(answerOf(command({}), 'q1-5', questionsOf({ questions: [{ ...fruit, multiSelect: true }] }))).toBe(undefined)
})

const pick = (label: string, change: object = {}) => (question: any) => ({
  status: 200,
  text: JSON.stringify({ v: 1, type: 'answer', id: question.id, answers: { [question.questions[0].question]: label }, ...change }),
})

test('the pick made in the app is handed to the session as the answer', async ($: any, on: any) => {
  const state = machine(on, { ask: [pick('pear')] })
  // The dialog is never answered: only the app's pick can end the wait.
  on('tool.call', () => new Promise(() => {}))
  const result = await $.tool.call({ tool: 'AskUserQuestion', questions: [fruit] })
  await settle($)
  expect(result.result).toEqual({ questions: [fruit], answers: { 'Apple or pear?': 'pear' } })
  expect(state.asks).toBe(1)
  expect(state.posts.map(post => post.body.kind)).toEqual(['question', 'resumed'])
})

test('the dialog answered first is what counts, and the app is not asked again', async ($: any, on: any) => {
  const state = machine(on)
  on('tool.call', dialogAfter(20, { 'Apple or pear?': 'apple' }))
  const result = await $.tool.call({ tool: 'AskUserQuestion', questions: [fruit] })
  await settle($)
  expect(result.result.answers).toEqual({ 'Apple or pear?': 'apple' })
  expect(state.asks).toBe(1)
  expect(state.posts.map(post => post.body.kind)).toEqual(['question', 'resumed'])
})

test('an answer that is not for this question, or names no option of it, changes nothing', async ($: any, on: any) => {
  const state = machine(on, {
    ask: [pick('pear', { id: 'q0-1' }), pick('plum'), () => ({ status: 200, text: 'not json' }), pick('pear', { type: 'submit' }), 'hold'],
  })
  on('tool.call', dialogAfter(60, { 'Apple or pear?': 'apple' }))
  const result = await $.tool.call({ tool: 'AskUserQuestion', questions: [fruit] })
  await settle($)
  // Four commands refused, the mod asking again each time; then the person answered in the dialog.
  expect(state.asks).toBe(5)
  expect(result.result.answers).toEqual({ 'Apple or pear?': 'apple' })
})

test('several questions or a choice of several are reported and left to the dialog', async ($: any, on: any) => {
  for (const questions of [[fruit, { ...fruit, question: 'Tea or coffee?' }], [{ ...fruit, multiSelect: true }]]) {
    const state = machine(on, { ask: [pick('pear')] })
    on('tool.call', dialogAfter(10, { 'Apple or pear?': 'apple' }))
    await $.tool.call({ tool: 'AskUserQuestion', questions })
    await settle($)
    expect(state.asks).toBe(0)
    expect(state.posts[0].body.can).toBe(undefined)
    expect(state.posts.map(post => post.body.kind)).toEqual(['question', 'resumed'])
    break
  }
})

test('a choice of several is reported with its kind and never offered for an answer', async ($: any, on: any) => {
  const state = machine(on, { ask: [pick('pear')] })
  on('tool.call', dialogAfter(10, { 'Apple or pear?': 'apple, pear' }))
  await $.tool.call({ tool: 'AskUserQuestion', questions: [{ ...fruit, multiSelect: true }] })
  await settle($)
  expect(state.asks).toBe(0)
  expect(state.posts[0].body.can).toBe(undefined)
  expect(state.posts[0].body.questions[0].multiSelect).toBe(true)
})

test('only the end of a long reply is kept, begun at a paragraph when one is near', () => {
  expect(tailOf('short')).toBe('short')
  expect(tailOf('  padded \n')).toBe('padded')
  expect(tailOf(undefined)).toBe('')
  const long = `${'a'.repeat(3000)}\n\nThe last paragraph.\n\n${'b '.repeat(600)}Which one?`
  const tail = tailOf(long)
  expect(tail.length <= SAID_LIMIT + 1).toBe(true)
  expect(tail.endsWith('Which one?')).toBe(true)
  expect(tail.startsWith('…')).toBe(true)
  expect(tailOf(`${'x'.repeat(100)}\n\nSecond paragraph here.`, 40)).toBe('…Second paragraph here.')
})

const turnEnd = (fields: object) => ({ answer: '', durationMs: 5, isAborted: false, turnId: 't1', reason: 'answer', ...fields })

test('the end of a turn is reported with the end of what the session said', async ($: any, on: any) => {
  const state = machine(on)
  on('turn.complete', (_$: any, e: any) => ({ text: e.answer }))
  await $.turn.complete(turnEnd({ answer: 'All done.\n\nShall I merge? ' }))
  await settle($)
  const [{ id, ...ended }] = state.posts.map(post => post.body)
  expect(ended).toEqual({ v: 1, session: SESSION, kind: 'turn.complete', reason: 'answer', said: 'All done.\n\nShall I merge?', can: ['reply'] })
  expect(/^t\d+-\d+$/.test(id)).toBe(true)
})

test('a turn that said nothing is reported without words, and a subagent\'s turn not at all', async ($: any, on: any) => {
  const state = machine(on)
  on('turn.complete', (_$: any, e: any) => ({ text: e.answer }))
  await $.turn.complete(turnEnd({ reason: 'aborted', isAborted: true }))
  await settle($)
  await $.turn.complete(turnEnd({ answer: 'A subagent\'s report.', agentId: 'a1' }))
  await settle($)
  expect(state.posts.map(post => ({ ...post.body, id: '' }))).toEqual([{ v: 1, session: SESSION, kind: 'turn.complete', reason: 'aborted', id: '', can: ['reply'] }])
})

test('a retry is one short line for exactly this failure', () => {
  expect(mayClear('rate_limit') && mayClear('overloaded') && mayClear('server_error')).toBe(true)
  for (const other of ['authentication_failed', 'billing_error', 'invalid_request', 'model_not_found', 'unknown', '', undefined]) expect(mayClear(other)).toBe(false)

  const command = (fields: object) => JSON.stringify({ v: 1, type: 'retry', id: 'f1-5', text: 'continue', ...fields })
  expect(retryOf(command({}), 'f1-5')).toBe('continue')
  expect(retryOf(command({ text: '  please continue ' }), 'f1-5')).toBe('please continue')
  expect(retryOf(command({}), 'f2-9')).toBe(undefined)
  expect(retryOf(command({ type: 'answer' }), 'f1-5')).toBe(undefined)
  expect(retryOf(command({ v: 2 }), 'f1-5')).toBe(undefined)
  expect(retryOf(command({ text: '' }), 'f1-5')).toBe(undefined)
  expect(retryOf(command({ text: 7 }), 'f1-5')).toBe(undefined)
  expect(retryOf(command({ text: 'two\nlines' }), 'f1-5')).toBe(undefined)
  expect(retryOf(command({ text: 'x'.repeat(201) }), 'f1-5')).toBe(undefined)
  expect(retryOf('not json', 'f1-5')).toBe(undefined)
})

/** The app's retry for the failure last reported, or a changed one. */
const again = (change: object = {}) => (failure: any) => ({
  status: 200,
  text: JSON.stringify({ v: 1, type: 'retry', id: failure.id, text: 'continue', ...change }),
})

/** A machine for a session that fails, with what the mod then submitted. */
const failing = (on: any, ask: Ask[]) => {
  const state = machine(on, { ask })
  const submitted: any[] = []
  on('classic.StopFailure', () => ({}))
  on('turn.complete', (_$: any, e: any) => ({ text: e.answer }))
  on('prompt.submit', (_$: any, e: any) => {
    submitted.push({ text: e.text, asUser: e.origin?.asUser })
    return { text: e.text }
  })
  return { state, submitted }
}

test('on the app\'s word the line is submitted once, as the mod\'s own prompt', async ($: any, on: any) => {
  const { state, submitted } = failing(on, [again(), 'hold'])
  await $.classic.StopFailure({ error: 'overloaded' })
  // The failed turn ends after its failure: that does not end the wait for a retry.
  await $.turn.complete({ answer: '', durationMs: 5, isAborted: false, turnId: 't1', reason: 'error' })
  await settle($)
  expect(submitted).toEqual([{ text: 'continue', asUser: undefined }])
  expect(state.asks).toBe(1)
})

test('a retry for another failure, a malformed one, or one with more than a line submits nothing', async ($: any, on: any) => {
  const { state, submitted } = failing(on, [again({ id: 'f0-1' }), again({ text: 'a\nb' }), () => ({ status: 200, text: 'not json' }), again({ type: 'answer' }), 'hold'])
  await $.classic.StopFailure({ error: 'server_error' })
  await settle($)
  expect(state.asks).toBe(5)
  expect(submitted).toEqual([])
})

test('a failure that needs a person is never retried, and a new turn ends the wait', async ($: any, on: any) => {
  const { state, submitted } = failing(on, [again()])
  on('turn.start', () => ({}))
  await $.classic.StopFailure({ error: 'authentication_failed' })
  await settle($)
  expect(state.asks).toBe(0)
  expect(submitted).toEqual([])
})

test('a restarted app is one that has not been told', () => {
  const told = { secret: 'abc' }
  expect(isNewApp(told, { secret: 'abc' })).toBe(false)
  expect(isNewApp(told, { secret: 'xyz' })).toBe(true)
  expect(isNewApp(undefined, { secret: 'abc' })).toBe(true)
  // No app at all: nobody to tell.
  expect(isNewApp(told, undefined)).toBe(false)
  expect(isNewApp(undefined, undefined)).toBe(false)
})

test('a reply is the user\'s text for exactly this turn\'s end', () => {
  const command = (fields: object) => JSON.stringify({ v: 1, type: 'reply', id: 't1-5', text: 'Yes, merge it.', ...fields })
  expect(replyOf(command({}), 't1-5')).toBe('Yes, merge it.')
  // Its lines are kept; only the ends are trimmed.
  expect(replyOf(command({ text: '  Yes.\n\nAnd update the docs. ' }), 't1-5')).toBe('Yes.\n\nAnd update the docs.')
  expect(replyOf(command({}), 't2-9')).toBe(undefined)
  expect(replyOf(command({ type: 'retry' }), 't1-5')).toBe(undefined)
  expect(replyOf(command({ v: 2 }), 't1-5')).toBe(undefined)
  expect(replyOf(command({ text: '   ' }), 't1-5')).toBe(undefined)
  expect(replyOf(command({ text: 7 }), 't1-5')).toBe(undefined)
  expect(replyOf(command({ text: 'x'.repeat(4001) }), 't1-5')).toBe(undefined)
  expect(replyOf('not json', 't1-5')).toBe(undefined)
})

/** The app's reply to the turn's end last reported, or a changed one. */
const reply = (change: object = {}) => (ended: any) => ({
  status: 200,
  text: JSON.stringify({ v: 1, type: 'reply', id: ended.id, text: 'Yes, merge it.', ...change }),
})

/** A machine for a session that finishes turns, with what the mod then submitted. */
const idling = (on: any, ask: Ask[]) => {
  const state = machine(on, { ask })
  const submitted: any[] = []
  on('turn.complete', (_$: any, e: any) => ({ text: e.answer }))
  on('turn.start', () => ({}))
  on('classic.StopFailure', () => ({}))
  on('prompt.submit', (_$: any, e: any) => {
    submitted.push({ text: e.text, asUser: e.origin?.asUser })
    return { text: e.text }
  })
  return { state, submitted }
}

test('a reply sent from the app is submitted once, as the user\'s own words', async ($: any, on: any) => {
  const { state, submitted } = idling(on, [reply(), 'hold'])
  await $.turn.complete(turnEnd({ answer: 'Shall I merge?' }))
  await settle($)
  expect(submitted).toEqual([{ text: 'Yes, merge it.', asUser: true }])
  expect(state.asks).toBe(1)
})

test('a reply for another turn, a malformed one, or an empty one submits nothing', async ($: any, on: any) => {
  const { state, submitted } = idling(on, [reply({ id: 't0-1' }), reply({ text: ' ' }), () => ({ status: 200, text: 'not json' }), reply({ type: 'retry' }), 'hold'])
  await $.turn.complete(turnEnd({ answer: 'Shall I merge?' }))
  await settle($)
  expect(state.asks).toBe(5)
  expect(submitted).toEqual([])
})

test('a turn that failed takes no reply, and neither does a subagent\'s', async ($: any, on: any) => {
  const { state, submitted } = idling(on, [reply()])
  await $.turn.complete(turnEnd({ reason: 'error' }))
  await settle($)
  await $.turn.complete(turnEnd({ answer: 'A report.', agentId: 'a1' }))
  await settle($)
  expect(state.posts.map(post => post.body)).toEqual([{ v: 1, session: SESSION, kind: 'turn.complete', reason: 'error' }])
  expect(state.asks).toBe(0)
  expect(submitted).toEqual([])
})
