// What the mod says to the app, apart from the engine: the shape of a report, and what is taken
// from a question or a tool's input to put in one. Plain functions, so they can be read and tested.

/** The version of the reports; the app drops what it does not understand. */
export const VERSION = 1

/** The longest text put in a report. The app cuts at the same length. */
export const TEXT_LIMIT = 2000

export type Question = { question: string; options: { label: string; description?: string }[]; multiSelect?: boolean }

/** What is open in the session right now, kept so it can be said again after the app restarts. */
export type Open =
  | { kind: 'question'; questions: Question[]; id?: string; takesAnswer?: boolean }
  | { kind: 'permission'; tool: string; detail: string }
  | { kind: 'failure'; error: string; id: string; takesRetry: boolean }
  | undefined

export type Report =
  | { kind: 'session.start' | 'session.end' | 'turn.start' | 'resumed' }
  | { kind: 'idle'; id: string; can: string[] }
  | { kind: 'turn.complete'; reason?: string; said?: string; id?: string; can?: string[] }
  | { kind: 'question'; questions: Question[]; id?: string; can?: string[] }
  | { kind: 'permission'; tool: string; detail: string }
  | { kind: 'failure'; error: string; id?: string; can?: string[] }

const cut = (text: unknown): string => String(text ?? '').slice(0, TEXT_LIMIT)

/** The questions of an AskUserQuestion call: their text and their options' labels, nothing else. */
export const questionsOf = (input: unknown): Question[] => {
  const asked = (input as { questions?: unknown })?.questions
  if (!Array.isArray(asked)) return []
  return asked
    .filter((entry): entry is { question: unknown; options?: unknown } => typeof entry === 'object' && entry !== null && typeof (entry as any).question === 'string')
    .slice(0, 8)
    .map(entry => ({
      question: cut(entry.question),
      ...((entry as { multiSelect?: unknown }).multiSelect === true ? { multiSelect: true } : {}),
      options: (Array.isArray(entry.options) ? entry.options : [])
        .filter((option): option is { label: unknown; description?: unknown } => typeof option === 'object' && option !== null && typeof (option as any).label === 'string')
        .slice(0, 8)
        .map(option => (typeof option.description === 'string' && option.description !== '' ? { label: cut(option.label), description: cut(option.description) } : { label: cut(option.label) })),
    }))
}

/**
 * One line saying what a tool call would do, for the approval the app shows: the command for a
 * shell, the path for a file tool, otherwise the input as it is. Cut to the limit.
 */
export const detailOf = (tool: string, input: unknown): string => {
  const fields = (typeof input === 'object' && input !== null ? input : {}) as Record<string, unknown>
  if (typeof fields.command === 'string') return cut(fields.command)
  if (typeof fields.file_path === 'string') return cut(fields.file_path)
  if (typeof fields.url === 'string') return cut(fields.url)
  try {
    return cut(JSON.stringify(input) ?? tool)
  } catch {
    return tool
  }
}

/** The body of a report as it is sent. */
export const bodyOf = (session: string, report: Report): string => JSON.stringify({ v: VERSION, session, ...report })

/** The report that says again what is open, or none when nothing is. */
export const reportOf = (open: Open): Report | undefined => {
  if (open === undefined) return undefined
  if (open.kind === 'permission') return { kind: 'permission', tool: open.tool, detail: open.detail }
  if (open.kind === 'failure') return { kind: 'failure', error: open.error, id: open.id, ...(open.takesRetry ? { can: ['retry'] } : {}) }
  return { kind: 'question', questions: open.questions, ...(open.id ? { id: open.id } : {}), ...(open.takesAnswer ? { can: ['answer'] } : {}) }
}

/**
 * Whether the app may answer this for the user: one question, with options, of which one is chosen.
 * Several questions, a choice of several, or typed text stay with the session's own dialog.
 */
export const takesAnswer = (questions: Question[]): boolean =>
  questions.length === 1 && questions[0].multiSelect !== true && questions[0].options.length > 0

/**
 * The answer in a command from the app, as the question tool's `answers`, or undefined when the
 * command is not an answer to exactly this asking of exactly this question with one of its options.
 */
export const answerOf = (text: string, id: string, questions: Question[]): Record<string, string> | undefined => {
  try {
    const command = JSON.parse(text) as { v?: unknown; type?: unknown; id?: unknown; answers?: unknown }
    if (command.v !== VERSION || command.type !== 'answer' || command.id !== id || !takesAnswer(questions)) return undefined
    if (typeof command.answers !== 'object' || command.answers === null || Array.isArray(command.answers)) return undefined
    const entries = Object.entries(command.answers as Record<string, unknown>)
    if (entries.length !== 1) return undefined
    const [question, label] = entries[0]
    if (question !== questions[0].question || typeof label !== 'string') return undefined
    if (!questions[0].options.some(option => option.label === label)) return undefined
    return { [question]: label }
  } catch {
    return undefined
  }
}

/** The app's address, from the small file it writes at every launch; undefined when it is not one. */
export const descriptorOf = (text: string): { socket: string; secret: string } | undefined => {
  try {
    const parsed = JSON.parse(text) as { v?: unknown; socket?: unknown; secret?: unknown }
    if (parsed.v !== VERSION || typeof parsed.socket !== 'string' || typeof parsed.secret !== 'string') return undefined
    if (!parsed.socket.startsWith('/') || parsed.secret === '') return undefined
    return { socket: parsed.socket, secret: parsed.secret }
  } catch {
    return undefined
  }
}

/** How much of a session's last reply is sent: its end, which is where it says what it needs. */
export const SAID_LIMIT = 1500

/** The end of a text, begun at a paragraph, a line or a word when one is near. */
export const tailOf = (text: unknown, limit = SAID_LIMIT): string => {
  const whole = String(text ?? '').trim()
  if (whole.length <= limit) return whole
  const tail = whole.slice(whole.length - limit)
  for (const mark of ['\n\n', '\n', ' ']) {
    const at = tail.indexOf(mark)
    if (at >= 0 && at < limit / 2) return `…${tail.slice(at).trimStart()}`
  }
  return `…${tail}`
}

/** The API's classes for a failure that may clear by itself; any other needs a person. */
export const CLEARING = ['rate_limit', 'overloaded', 'server_error']

/** Whether trying again can help after a failure of this class. */
export const mayClear = (error: unknown): boolean => typeof error === 'string' && CLEARING.includes(error)

/** The longest line the app may have submitted as a retry. */
export const RETRY_TEXT_LIMIT = 200

/**
 * The line to submit from a command of the app, or undefined when the command is not a retry of
 * exactly this failure with one short line of text.
 */
export const retryOf = (text: string, id: string): string | undefined => {
  try {
    const command = JSON.parse(text) as { v?: unknown; type?: unknown; id?: unknown; text?: unknown }
    if (command.v !== VERSION || command.type !== 'retry' || command.id !== id || typeof command.text !== 'string') return undefined
    const line = command.text.trim()
    if (line === '' || line.length > RETRY_TEXT_LIMIT || /[\r\n]/.test(line)) return undefined
    return line
  } catch {
    return undefined
  }
}

/**
 * Whether the app found now has not been told how this session's last turn ended: there is an
 * app, and its secret is not the one of the app that was told (it was restarted since, or none
 * was told). Which app the mod talks to says nothing: asking for a reply reconnects by itself.
 */
export const isNewApp = (toldSecret: string | undefined, found: { secret: string } | undefined): boolean =>
  found !== undefined && found.secret !== toldSecret

/** The longest reply the app may have submitted. */
export const REPLY_TEXT_LIMIT = 4000

/**
 * The reply to submit from a command of the app, or undefined when the command is not a reply to
 * exactly this turn's end with some text of a sane length. The text is the user's, typed and
 * sent in Porchlight; its lines are kept.
 */
export const replyOf = (text: string, id: string): string | undefined => {
  try {
    const command = JSON.parse(text) as { v?: unknown; type?: unknown; id?: unknown; text?: unknown }
    if (command.v !== VERSION || command.type !== 'reply' || command.id !== id || typeof command.text !== 'string') return undefined
    const reply = command.text.trim()
    if (reply === '' || reply.length > REPLY_TEXT_LIMIT) return undefined
    return reply
  } catch {
    return undefined
  }
}
