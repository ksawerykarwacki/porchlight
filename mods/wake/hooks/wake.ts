// What the mod decides, apart from the engine: which session a message is for, and whether it
// has to be woken first. Kept free of `$` so it can be read and tested as plain functions.

/** One row of `claude agents --json --all`, as far as this mod reads it. */
export type Listed = {
  id?: string
  sessionId?: string
  name?: string
  kind?: string
  pid?: number | null
}

export type Decision =
  /** Send as it is: the recipient is running, is not one of this machine's sessions, or is unclear. */
  | { wake: false; why: string }
  /** The recipient is a background session with no process: restart it first. */
  | { wake: true; id: string; sessionId: string | undefined; name: string | undefined }

/** The rows of the listing, or none when it is not the JSON array it should be. */
export const parseListing = (stdout: string): Listed[] => {
  try {
    const parsed: unknown = JSON.parse(stdout)
    return Array.isArray(parsed) ? parsed.filter((row): row is Listed => typeof row === 'object' && row !== null) : []
  } catch {
    return []
  }
}

/** A short id as `claude` prints it. Nothing else is ever passed to `claude respawn`. */
export const isShortID = (text: string | undefined): text is string => typeof text === 'string' && /^[0-9a-f]{8}$/.test(text)

/**
 * Whether the recipient of a message has to be woken.
 *
 * A recipient is matched by its name, its short id or its conversation id, exactly. Only a
 * background session is ever woken, only when exactly one matches, and never the sender itself.
 * Anything else is left to Claude Code, which then says what it always said.
 */
export const decide = (to: string, rows: readonly Listed[], self: string | undefined): Decision => {
  const matches = rows.filter(row => row.name === to || row.id === to || row.sessionId === to)
  if (matches.length === 0) return { wake: false, why: 'not one of this machine\'s sessions' }
  if (matches.length > 1) return { wake: false, why: `${matches.length} sessions answer to that` }
  const [row] = matches
  if (typeof row.pid === 'number' && row.pid > 0) return { wake: false, why: 'running' }
  if (row.kind !== 'background') return { wake: false, why: 'not a background session' }
  if (self !== undefined && (row.sessionId === self || row.id === self.slice(0, 8))) return { wake: false, why: 'the sender itself' }
  if (!isShortID(row.id)) return { wake: false, why: 'no usable id' }
  return { wake: true, id: row.id, sessionId: row.sessionId, name: row.name }
}

/** Whether the session with this short id has a process now. */
export const isRunning = (id: string, rows: readonly Listed[]): boolean =>
  rows.some(row => row.id === id && typeof row.pid === 'number' && row.pid > 0)
