import assert from 'node:assert/strict'
import { once } from 'node:events'
import { mkdtemp, rm } from 'node:fs/promises'
import { createServer, type Socket } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { PetSocketClient } from '../src/socket-client.js'
import type { BridgeMessage, SessionSnapshot } from '../src/protocol.js'

const pause = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms))
async function until(predicate: () => boolean, description = 'condition'): Promise<void> {
  const deadline = Date.now() + 4000
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`Timed out: ${description}`)
    await pause(5)
  }
}

async function receiver(path: string) {
  const messages: BridgeMessage[] = []
  const sockets = new Set<Socket>()
  const server = createServer(socket => {
    sockets.add(socket)
    socket.once('close', () => sockets.delete(socket))
    let buffered = ''
    socket.setEncoding('utf8')
    socket.on('data', chunk => {
      buffered += chunk
      for (;;) {
        const end = buffered.indexOf('\n')
        if (end < 0) break
        messages.push(JSON.parse(buffered.slice(0, end)) as BridgeMessage)
        buffered = buffered.slice(end + 1)
      }
    })
  })
  server.listen(path)
  await once(server, 'listening')
  return {
    messages, sockets,
    close: async () => { for (const socket of sockets) socket.destroy(); server.close(); await once(server, 'close') },
  }
}

test('initial connection failure, full reconnect snapshot, heartbeat, independent sources, idempotent stop', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-pet-'))
  const path = join(directory, 'pet.sock')
  let sessions: SessionSnapshot[] = []
  const errors: Error[] = []
  const a = new PetSocketClient({ socketPath: path, sessions: () => sessions, heartbeatMs: 20, reconnectMinMs: 10, reconnectMaxMs: 20, onError: e => errors.push(e) })
  const b = new PetSocketClient({ socketPath: path, sessions: () => [], heartbeatMs: 20, reconnectMinMs: 10 })
  let host: Awaited<ReturnType<typeof receiver>> | undefined
  try {
    a.start()
    await until(() => errors.length > 0, 'first failure')
    host = await receiver(path)
    await until(() => host!.messages.some(m => m.type === 'snapshot'), 'first snapshot')
    const baseline = host.messages[0]!
    assert.equal(baseline.type, 'snapshot')
    await until(() => host!.messages.some(m => m.type === 'heartbeat'), 'heartbeat')
    sessions = [{ sessionId: 'a', turn: 1, phase: 'working', activeTools: 1, pendingApprovals: 0, result: null }]
    a.changed()
    await until(() => host!.messages.some(m => m.type === 'snapshot' && m.sessions.length === 1), 'changed state')
    for (const socket of host.sockets) socket.destroy()
    const before = host.messages.length
    await until(() => host!.messages.slice(before).some(m => m.type === 'snapshot'), 'reconnect baseline')
    b.start()
    await until(() => new Set(host!.messages.map(m => m.sourceId)).size === 2, 'second source')
    assert.notEqual(a.sourceId, b.sourceId)
    const sourceMessages = host.messages.filter(m => m.sourceId === a.sourceId)
    for (let i = 1; i < sourceMessages.length; ++i) assert.ok(sourceMessages[i]!.seq > sourceMessages[i - 1]!.seq)
    a.stop(); a.stop(); b.stop(); b.stop()
    await until(() => host!.sockets.size === 0, 'connection cleanup')
    const count = host.messages.length
    a.changed(); a.start()
    await pause(80)
    assert.equal(host.messages.length, count)
  } finally {
    a.stop(); b.stop()
    if (host) await host.close()
    await rm(directory, { recursive: true, force: true })
  }
})

test('backpressure coalesces a burst to latest snapshot and releases pending work on stop', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-pet-'))
  const host = await receiver(join(directory, 'pet.sock'))
  let turn = 0
  const client = new PetSocketClient({
    socketPath: join(directory, 'pet.sock'), sourceLabel: 's'.repeat(150000),
    sessions: () => [{ sessionId: 'burst', turn, phase: 'running', activeTools: 0, pendingApprovals: 0, result: null }],
  })
  try {
    client.start()
    await until(() => host.sockets.size === 1)
    for (const socket of host.sockets) socket.pause()
    for (turn = 1; turn <= 200; ++turn) {
      client.changed()
      await new Promise<void>(resolve => setImmediate(resolve))
    }
    turn = 999
    client.changed()
    for (const socket of host.sockets) socket.resume()
    await until(() => host.messages.some(m => m.type === 'snapshot' && m.sessions[0]?.turn === 999), 'latest state drains')
    assert.ok(host.messages.length < 200, 'pending snapshots were coalesced')
    client.stop()
    await until(() => host.sockets.size === 0)
  } finally {
    client.stop()
    await host.close()
    await rm(directory, { recursive: true, force: true })
  }
})
