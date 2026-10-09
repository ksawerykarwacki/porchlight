// What the mod says to the app, apart from the engine: the shape of a report, and what is taken
// from a question or a tool's input to put in one. Plain functions, so they can be read and tested.

/** The version of the reports; the app drops what it does not understand. */
export const VERSION = 1

/** The longest text put in a report. The app cuts at the same length. */
export const TEXT_LIMIT = 2000

export type Question = { question: string; options: { label: string; description?: string }[] }

/** What is open in the session right now, kept so it can be said again after the app restarts. */
export type Open = { kind: 'question'; questions: Question[] } | { kind: 'permission'; tool: string; detail: string } | undefined

export type Report =
  | { kind: 'session.start' | 'session.end' | 'turn.start' | 'resumed' }
  | { kind: 'turn.complete'; reason?: string }
  | { kind: 'question'; questions: Question[] }
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
  return open.kind === 'question' ? { kind: 'question', questions: open.questions } : { kind: 'permission', tool: open.tool, detail: open.detail }
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
