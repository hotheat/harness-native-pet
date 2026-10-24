import { randomUUID } from 'node:crypto'
import { createConnection, type Socket } from 'node:net'
import { encodeMessage } from './protocol.js'
import type { SessionSnapshot } from './protocol.js'

export interface ClientOptions {
  socketPath: string
  sessions: () => SessionSnapshot[]
  sourceLabel?: string
  onError?: (error: Error) => void
  heartbeatMs?: number
  reconnectMinMs?: number
  reconnectMaxMs?: number
}

/** One connection, one pending latest snapshot; DSH event dispatch never awaits IO. */
export class PetSocketClient {
  readonly sourceId = randomUUID()
  private socket: Socket | undefined
  private heartbeat: NodeJS.Timeout | undefined
  private retry: NodeJS.Timeout | undefined
  private stopped = false
  private started = false
  private connected = false
  private blocked = false
  private scheduled = false
  private pending = true
  private seq = 0
  private retryDelay: number
  private lastError: string | undefined

  constructor(private readonly options: ClientOptions) {
    this.retryDelay = options.reconnectMinMs ?? 250
  }

  start(): void {
    if (this.started || this.stopped) return
    this.started = true
    this.connect()
    this.heartbeat = setInterval(() => {
      if (!this.connected || this.blocked) return
      if (this.pending) this.flush()
      else this.send(encodeMessage({ type: 'heartbeat', sourceId: this.sourceId, seq: ++this.seq }))
    }, this.options.heartbeatMs ?? 5000)
    this.heartbeat.unref()
  }

  changed(): void {
    if (this.stopped) return
    this.pending = true
    if (this.scheduled) return
    this.scheduled = true
    queueMicrotask(() => { this.scheduled = false; this.flush() })
  }

  stop(): void {
    if (this.stopped) return
    this.stopped = true
    clearInterval(this.heartbeat)
    clearTimeout(this.retry)
    this.heartbeat = undefined
    this.retry = undefined
    this.connected = false
    this.pending = false
    this.socket?.destroy()
    this.socket = undefined
  }

  private report(error: Error): void {
    if (this.lastError === error.message) return
    this.lastError = error.message
    this.options.onError?.(error)
  }

  private connect(): void {
    if (this.stopped) return
    const socket = createConnection(this.options.socketPath)
    this.socket = socket
    socket.setTimeout(3000)
    socket.once('timeout', () => { this.report(new Error('Desktop pet connection timed out')); socket.destroy() })
    socket.on('error', error => this.report(error))
    socket.once('connect', () => {
      if (this.stopped || this.socket !== socket) { socket.destroy(); return }
      socket.setTimeout(0)
      this.connected = true
      this.blocked = false
      this.pending = true
      this.lastError = undefined
      this.retryDelay = this.options.reconnectMinMs ?? 250
      this.flush()
    })
    socket.on('drain', () => {
      if (this.socket !== socket || this.stopped) return
      this.blocked = false
      this.flush()
    })
    socket.once('close', () => {
      if (this.socket !== socket) return
      this.socket = undefined
      this.connected = false
      this.blocked = false
      if (this.stopped) return
      this.retry = setTimeout(() => { this.retry = undefined; this.connect() }, this.retryDelay)
      this.retry.unref()
      this.retryDelay = Math.min(this.retryDelay * 2, this.options.reconnectMaxMs ?? 5000)
    })
  }

  private send(line: string): void {
    if (this.socket !== undefined) this.blocked = !this.socket.write(line)
  }

  private flush(): void {
    if (this.stopped || !this.connected || this.blocked || !this.pending) return
    this.pending = false
    try {
      this.send(encodeMessage({
        type: 'snapshot', sourceId: this.sourceId, sourceLabel: this.options.sourceLabel ?? 'DSH',
        seq: ++this.seq, sessions: this.options.sessions(),
      }))
    } catch (error) {
      this.report(error instanceof Error ? error : new Error(String(error)))
      // End this source rather than keeping a connected, stale task presentation.
      this.socket?.destroy()
    }
  }
}
