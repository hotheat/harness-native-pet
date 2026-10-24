import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import Ajv from 'ajv'
import { decodeMessage, encodeMessage, MAX_LINE_BYTES } from '../src/protocol.js'
import type { BridgeMessage } from '../src/protocol.js'

interface Fixture { name: string; message: unknown }
const read = (path: string): unknown => JSON.parse(readFileSync(new URL(path, import.meta.url), 'utf8'))
const validate = new Ajv.default({ strict: true }).compile(read('../../contracts/bridge.schema.json') as object)
const valid = [...read('../../contracts/fixtures/snapshots.json') as Fixture[], ...read('../../contracts/fixtures/activity.json') as Fixture[]]
const invalid = read('../../contracts/fixtures/invalid-messages.json') as Fixture[]

for (const fixture of valid) {
  test(`contract accepts shared ${fixture.name}`, () => {
    assert.equal(validate(fixture.message), true, JSON.stringify(validate.errors))
    const encoded = encodeMessage(decodeMessage(fixture.message))
    assert.deepEqual(decodeMessage(JSON.parse(encoded)), decodeMessage(fixture.message))
    assert.equal(Object.hasOwn(JSON.parse(encoded), 'v'), false)
    assert.equal(encoded.includes('"optional"'), false)
    assert.equal(encoded.at(-1), '\n')
  })
}
for (const fixture of invalid) {
  test(`contract rejects shared ${fixture.name}`, () => {
    assert.equal(validate(fixture.message), false)
    assert.throws(() => decodeMessage(fixture.message))
  })
}
test('encoded size uses UTF-8 bytes and limits only at IO', () => {
  const message: BridgeMessage = { type: 'snapshot', sourceId: 'a', sourceLabel: '中'.repeat(MAX_LINE_BYTES / 2), seq: 1, sessions: [] }
  assert.throws(() => encodeMessage(message), /exceeds/)
  message.sourceLabel = 'DSH'
  assert.doesNotThrow(() => encodeMessage(message))
})

test('snapshot rejects duplicate sessionId', () => {
  const session = { sessionId: 'same', turn: 1, phase: 'thinking', activeTools: 0, pendingApprovals: 0, result: null }
  const message = { type: 'snapshot', sourceId: 'dsh', sourceLabel: 'DSH', seq: 1, sessions: [session, { ...session, turn: 2 }] }
  assert.equal(validate(message), true)
  assert.throws(() => decodeMessage(message), /session snapshot/)
  assert.doesNotThrow(() => decodeMessage({ ...message, sessions: [session, { ...session, sessionId: 'other' }] }))
})
