import { homedir } from 'node:os'
import { join } from 'node:path'

export const MAX_LINE_BYTES = 262144
export type SessionPhase = 'idle' | 'running' | 'thinking' | 'working' | 'waiting' | 'completed' | 'error' | 'stopped'
export type ResultOutcome = 'completed' | 'error' | 'aborted' | 'blocked' | 'max-tokens' | 'other'
export interface SessionResult { id: string; outcome: ResultOutcome }
export interface SessionSnapshot {
  sessionId: string
  turn: number | null
  phase: SessionPhase
  activeTools: number
  pendingApprovals: number
  result: SessionResult | null
}
export interface SourceSnapshot {
  type: 'snapshot'
  sourceId: string
  sourceLabel: string
  seq: number
  sessions: SessionSnapshot[]
}
export interface Heartbeat { type: 'heartbeat'; sourceId: string; seq: number }
export type BridgeMessage = SourceSnapshot | Heartbeat

const phases = new Set<string>(['idle', 'running', 'thinking', 'working', 'waiting', 'completed', 'error', 'stopped'])
const outcomes = new Set<string>(['completed', 'error', 'aborted', 'blocked', 'max-tokens', 'other'])
const nonempty = (value: unknown): value is string => typeof value === 'string' && value.length > 0
const natural = (value: unknown): value is number => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0
function object(value: unknown, keys: string[]): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key))
}
function validSession(value: unknown): boolean {
  if (!object(value, ['sessionId', 'turn', 'phase', 'activeTools', 'pendingApprovals', 'result'])) return false
  return nonempty(value.sessionId) && (value.turn === null || natural(value.turn))
    && typeof value.phase === 'string' && phases.has(value.phase)
    && natural(value.activeTools) && natural(value.pendingApprovals)
    && (value.result === null || (object(value.result, ['id', 'outcome'])
      && nonempty(value.result.id) && typeof value.result.outcome === 'string' && outcomes.has(value.result.outcome)))
}

/** Validate at the wire boundary; contract fixtures keep both language decoders aligned. */
export function decodeMessage(value: unknown): BridgeMessage {
  if (typeof value !== 'object' || value === null || !('type' in value)) throw new Error('Invalid desktop pet message')
  const snapshot = value.type === 'snapshot'
  if (!(snapshot ? object(value, ['type', 'sourceId', 'sourceLabel', 'seq', 'sessions'])
    : value.type === 'heartbeat' && object(value, ['type', 'sourceId', 'seq']))) throw new Error('Invalid desktop pet message fields')
  const fields = value as Record<string, unknown>
  if (!nonempty(fields.sourceId) || fields.sourceId.startsWith('hook:') || !natural(fields.seq) || fields.seq === 0) throw new Error('Invalid desktop pet source or sequence')
  if (snapshot && (!nonempty(fields.sourceLabel) || !Array.isArray(fields.sessions)
    || !fields.sessions.every(validSession))) throw new Error('Invalid desktop pet session snapshot')
  return value as BridgeMessage
}

export function socketPath(runtimeDirectory = process.env.DSH_NATIVE_PET_RUNTIME_DIR): string {
  return join(runtimeDirectory ?? join(homedir(), 'Library/Application Support/dsh-native-pet'), 'pet.sock')
}

export function encodeMessage(message: BridgeMessage): string {
  decodeMessage(message)
  const json = JSON.stringify(message)
  if (Buffer.byteLength(json, 'utf8') > MAX_LINE_BYTES) throw new Error('Desktop pet snapshot exceeds 262144 bytes')
  return `${json}\n`
}
