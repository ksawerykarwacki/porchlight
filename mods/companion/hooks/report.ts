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
  | undefined

export type Report =
  | { kind: 'session.start' | 'session.end' | 'turn.start' | 'resumed' }
  | { kind: 'turn.complete'; reason?: string; said?: string }
  | { kind: 'question'; questions: Question[]; id?: string; can?: string[] }
  | { kind: 'permission'; tool: string; detail: string }
  | { kind: 'failure'; error: string }

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
